// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

/// @notice The one read this contract needs from `IndexMarketRegistry`.
interface IMarketsLike {
    function marketFor(address index) external view returns (PoolKey memory);
}

/**
 * @title  LiquidityLocker
 * @notice Holds the official liquidity in each index's share market and keeps it at the index's
 *         backing. It can also lock that liquidity until a date, though it is deployed unlocked for
 *         now: the project may migrate again, so the owner can withdraw at any time.
 *
 * @dev    ## TWO POSITIONS PER POOL
 *
 *         The share of an index is worth its basket, so the market should sit there. Most of what
 *         the locker holds for an index is a **band** around backing (salt 0), where it gives the
 *         most depth. A small slice is a **backstop** across the full range (salt 1), so a trade that
 *         runs through the band still meets liquidity and cannot push the price anywhere it likes.
 *         Both belong to this contract in the PoolManager.
 *
 *         ## WHAT A RECENTER CAN AND CANNOT DO
 *
 *         Inside one `unlock`: remove both positions (fees included), swap toward the target with the
 *         target as the price limit, add the backstop from `backstopBps` of what the index holds and
 *         the band from the rest. When the locker is the only provider the pool is empty during the
 *         swap, so the price moves for free. When others provide, the swap trades against them,
 *         always toward the target, so at the target's valuation it can only gain, less the pool and
 *         hook fees.
 *
 *         Four checks bound a caller who is wrong or hostile:
 *         1. **Move cap.** The target may be at most `ownerMaxMoveBps` (owner) or
 *            `operatorMaxMoveBps` (operator) from the pool's price, and an operator must wait
 *            `operatorCooldown` between recenters. These are immutable: a stolen key cannot walk
 *            the price faster than they allow, and the owner can revoke the operator at once.
 *         2. **Value floor.** What the locker holds for the index, valued at the target, may fall by
 *            at most `maxLossBps` across the recenter. Tokens only ever move between the locker and
 *            the pool, so this is the whole of what a recenter can cost.
 *         3. **Price tolerance.** The pool must end within `toleranceBps` of the target.
 *         4. **Liquidity floors.** The band and the backstop must each be at least the caller's
 *            floor, and the band must hold the target.
 *
 *         What a recenter does not protect against is a wrong target: a price inside the move cap
 *         that is not the backing lets arbitrage take from the positions. That is why the cap and
 *         the cooldown exist and why the operator can only ever recenter.
 *
 *         ## THE LOCK
 *
 *         `unlockAt` is set at deploy and may only move later (`extendLock`, `extendIndexLock`).
 *         Before it, nothing leaves except into the pool. After it, `withdraw` sends an index's
 *         positions and float to the owner. Deploying with `unlockAt` at or before the deploy time
 *         leaves the owner free to withdraw at once; extending it later is what locks it.
 *
 *         ## FLOAT
 *
 *         Whatever does not fit stays here as the index's float, counted per index so one market can
 *         never spend another's USDG. `topUp` adds to it. Tokens sent here by plain transfer are not
 *         counted and cannot be recovered.
 *
 *         Not independently audited.
 */
contract LiquidityLocker is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;
    /// @notice The loosest price tolerance any recenter may ask for.
    uint16 public constant MAX_TOLERANCE_BPS = 100;
    /// @notice The salt of the band around backing, one per pool.
    bytes32 public constant BAND_SALT = bytes32(0);
    /// @notice The salt of the full-range backstop, one per pool.
    bytes32 public constant BACKSTOP_SALT = bytes32(uint256(1));

    IPoolManager public immutable manager;
    IMarketsLike public immutable registry;
    address public immutable owner;
    /// @notice Largest price move one owner recenter may make, in bps of price.
    uint16 public immutable ownerMaxMoveBps;
    /// @notice Largest price move one operator recenter may make, in bps of price.
    uint16 public immutable operatorMaxMoveBps;
    /// @notice Seconds an operator must wait after any recenter of the same index.
    uint32 public immutable operatorCooldown;
    /// @notice Largest fall in the index's holdings, valued at the target, one recenter may cause.
    uint16 public immutable maxLossBps;

    /// @notice Nothing leaves before this, for any index. May only move later. At or before the
    ///         deploy time, nothing is locked.
    uint64 public unlockAt;
    /// @notice May call `recenter` and nothing else. Zero when there is none.
    address public operator;

    struct Book {
        int24 lower;
        int24 upper;
        uint64 unlockAt; // a later date for this index alone; zero when only the global one applies
        uint64 lastRecenter;
        uint256 float0;
        uint256 float1;
    }

    mapping(address => Book) public books;

    struct Recenter {
        address index;
        uint160 targetSqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint16 toleranceBps;
        uint256 maxSwapIn; // cap on the swap's input; the pool's empty case needs only dust
        uint128 minLiquidity; // floor for the band
        uint16 backstopBps; // share of each token the index holds that goes to the full-range backstop
        uint128 minBackstopLiquidity;
        uint256 deadline;
    }

    enum Action { Deposit, Recenter, Withdraw }

    bool private unlocking;

    error NotOwner();
    error NotAllowed();
    error UnknownMarket();
    error Expired();
    error Locked();
    error BadRange();
    error RangeMismatch();
    error LockNotExtended();
    error MoveTooLarge(uint256 moveBps);
    error Cooldown();
    error BadTolerance();
    error MissedTarget(uint160 sqrtPriceX96);
    error LiquidityBelowFloor(uint128 liquidity);
    error ValueBelowFloor(uint256 before, uint256 afterValue);
    error InsufficientFloat();
    error UnauthorizedCallback();
    error InvalidConfig();
    error BadBackstop();

    event Deposited(address indexed index, int24 lower, int24 upper, uint256 paid0, uint256 paid1,
        uint128 bandAdded, uint128 backstopAdded);
    event ToppedUp(address indexed index, uint256 amount0, uint256 amount1);
    event Recentered(address indexed index, address indexed caller, uint160 fromSqrtPriceX96, uint160 toSqrtPriceX96,
        int24 lower, int24 upper, uint128 liquidityBefore, uint128 liquidityAfter, uint256 valueBefore, uint256 valueAfter);
    /// @notice The backstop's liquidity after a recenter; `Recentered` reports the band's.
    event BackstopSet(address indexed index, uint128 liquidity);
    event Withdrawn(address indexed index, address indexed to, uint256 amount0, uint256 amount1, uint128 band, uint128 backstop);
    event LockExtended(uint64 unlockAt);
    event IndexLockExtended(address indexed index, uint64 unlockAt);
    event OperatorSet(address indexed operator);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        IPoolManager manager_,
        IMarketsLike registry_,
        address owner_,
        uint64 unlockAt_,
        uint16 ownerMaxMoveBps_,
        uint16 operatorMaxMoveBps_,
        uint32 operatorCooldown_,
        uint16 maxLossBps_
    ) {
        if (address(manager_).code.length == 0 || address(registry_).code.length == 0 || owner_ == address(0)
            || ownerMaxMoveBps_ == 0 || operatorMaxMoveBps_ > ownerMaxMoveBps_
            || maxLossBps_ > 1_000) revert InvalidConfig();
        manager = manager_;
        registry = registry_;
        owner = owner_;
        unlockAt = unlockAt_;
        ownerMaxMoveBps = ownerMaxMoveBps_;
        operatorMaxMoveBps = operatorMaxMoveBps_;
        operatorCooldown = operatorCooldown_;
        maxLossBps = maxLossBps_;
        emit LockExtended(unlockAt_);
    }

    // ------------------------------------------------------------------ views

    function market(address index) public view returns (PoolKey memory key) {
        key = registry.marketFor(index);
        if (Currency.unwrap(key.currency0) == address(0)
            || (Currency.unwrap(key.currency0) != index && Currency.unwrap(key.currency1) != index)) revert UnknownMarket();
    }

    function lockedUntil(address index) public view returns (uint64) {
        uint64 own = books[index].unlockAt;
        return own > unlockAt ? own : unlockAt;
    }

    /// @notice The band's liquidity.
    function positionLiquidity(address index) public view returns (uint128 liquidity) {
        Book storage b = books[index];
        if (b.lower == b.upper) return 0;
        (liquidity,,) = manager.getPositionInfo(market(index).toId(), address(this), b.lower, b.upper, BAND_SALT);
    }

    /// @notice The full-range backstop's liquidity.
    function backstopLiquidity(address index) public view returns (uint128 liquidity) {
        PoolKey memory key = market(index);
        (int24 lower, int24 upper) = _fullRange(key);
        (liquidity,,) = manager.getPositionInfo(key.toId(), address(this), lower, upper, BACKSTOP_SALT);
    }

    /// @notice Both positions' tokens at the pool's price, rounded down, plus the float. Fees excluded.
    function holdings(address index) external view returns (uint256 amount0, uint256 amount1) {
        Book storage b = books[index];
        PoolKey memory key = market(index);
        (amount0, amount1) = (b.float0, b.float1);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        uint128 band = positionLiquidity(index);
        if (band != 0) {
            (uint256 p0, uint256 p1) = _amountsFor(price, b.lower, b.upper, band);
            (amount0, amount1) = (amount0 + p0, amount1 + p1);
        }
        uint128 backstop = backstopLiquidity(index);
        if (backstop != 0) {
            (int24 lower, int24 upper) = _fullRange(key);
            (uint256 p0, uint256 p1) = _amountsFor(price, lower, upper, backstop);
            (amount0, amount1) = (amount0 + p0, amount1 + p1);
        }
    }

    // ------------------------------------------------------------------ owner

    function setOperator(address operator_) external onlyOwner {
        operator = operator_;
        emit OperatorSet(operator_);
    }

    function extendLock(uint64 newUnlockAt) external onlyOwner {
        if (newUnlockAt <= unlockAt) revert LockNotExtended();
        unlockAt = newUnlockAt;
        emit LockExtended(newUnlockAt);
    }

    function extendIndexLock(address index, uint64 newUnlockAt) external onlyOwner {
        if (newUnlockAt <= lockedUntil(index)) revert LockNotExtended();
        books[index].unlockAt = newUnlockAt;
        emit IndexLockExtended(index, newUnlockAt);
    }

    /// @notice Add to the index's float without touching the position. The next recenter uses it.
    function topUp(address index, uint256 amount0, uint256 amount1) external onlyOwner nonReentrant {
        _pull(market(index), index, amount0, amount1);
        emit ToppedUp(index, amount0, amount1);
    }

    /**
     * @notice Fund the index's float and add it at the pool's price: `backstopBps` of each token to
     *         the full-range backstop, and all of the rest that fits to the band.
     * @dev    The first deposit sets the band's range; later ones must use the same range, and a new
     *         range comes only from `recenter`. What does not fit stays as float.
     */
    function deposit(address index, uint256 amount0, uint256 amount1, int24 lower, int24 upper, uint16 backstopBps,
        uint128 minLiquidity, uint256 deadline) external onlyOwner nonReentrant returns (uint128 added)
    {
        if (backstopBps > BPS) revert BadBackstop();
        if (block.timestamp > deadline) revert Expired();
        PoolKey memory key = market(index);
        Book storage b = books[index];
        if (positionLiquidity(index) != 0) {
            if (lower != b.lower || upper != b.upper) revert RangeMismatch();
        } else {
            _checkRange(key, lower, upper);
            (b.lower, b.upper) = (lower, upper);
        }
        _pull(key, index, amount0, amount1);
        added = abi.decode(_unlock(abi.encode(Action.Deposit, index, key, minLiquidity, backstopBps)), (uint128));
    }

    /// @notice Once unlocked, send the index's positions and float to the owner.
    function withdraw(address index) external onlyOwner nonReentrant {
        if (block.timestamp < lockedUntil(index)) revert Locked();
        PoolKey memory key = market(index);
        _unlock(abi.encode(Action.Withdraw, index, key, uint128(0), uint16(0)));
    }

    // ------------------------------------------------------------------ recenter

    function recenter(Recenter calldata r) external nonReentrant returns (uint128 liquidity) {
        if (block.timestamp > r.deadline) revert Expired();
        Book storage b = books[r.index];
        uint256 maxMove;
        if (msg.sender == owner) {
            maxMove = ownerMaxMoveBps;
        } else if (msg.sender == operator && operator != address(0)) {
            if (block.timestamp < uint256(b.lastRecenter) + operatorCooldown) revert Cooldown();
            maxMove = operatorMaxMoveBps;
        } else {
            revert NotAllowed();
        }
        if (r.toleranceBps > MAX_TOLERANCE_BPS) revert BadTolerance();
        if (r.backstopBps > BPS) revert BadBackstop();
        PoolKey memory key = market(r.index);
        _checkRange(key, r.tickLower, r.tickUpper);
        if (r.targetSqrtPriceX96 < TickMath.MIN_SQRT_PRICE || r.targetSqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) revert BadRange();
        int24 targetTick = TickMath.getTickAtSqrtPrice(r.targetSqrtPriceX96);
        // The new range must hold the target, so the position is making a market there.
        if (targetTick < r.tickLower || targetTick >= r.tickUpper) revert BadRange();

        (uint160 current,,,) = manager.getSlot0(key.toId());
        uint256 move = _moveBps(current, r.targetSqrtPriceX96);
        if (move > maxMove) revert MoveTooLarge(move);

        b.lastRecenter = uint64(block.timestamp);
        liquidity = abi.decode(_unlock(abi.encode(Action.Recenter, r.index, key, r, msg.sender)), (uint128));
    }

    // ------------------------------------------------------------------ the unlock

    function _unlock(bytes memory data) private returns (bytes memory result) {
        unlocking = true;
        result = manager.unlock(data);
        unlocking = false;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || !unlocking) revert UnauthorizedCallback();
        Action action = abi.decode(data[:32], (Action));
        if (action == Action.Recenter) {
            (,, PoolKey memory k, Recenter memory r, address caller) =
                abi.decode(data, (Action, address, PoolKey, Recenter, address));
            return abi.encode(_recenter(r, k, caller));
        }
        (, address index, PoolKey memory key, uint128 minLiquidity, uint16 backstopBps) =
            abi.decode(data, (Action, address, PoolKey, uint128, uint16));
        if (action == Action.Deposit) return abi.encode(_deposit(index, key, minLiquidity, backstopBps));
        _withdraw(index, key);
        return "";
    }

    function _deposit(address index, PoolKey memory key, uint128 minLiquidity, uint16 backstopBps)
        private returns (uint128 added)
    {
        Book storage b = books[index];
        int256[2] memory net;
        (uint160 price,,,) = manager.getSlot0(key.toId());
        uint128 backstop = _addBackstop(key, b, price, backstopBps, net);
        added = _liquidityFor(price, b.lower, b.upper, b.float0, b.float1);
        if (added == 0 || added < minLiquidity) revert LiquidityBelowFloor(added);
        _change(key, b, b.lower, b.upper, BAND_SALT, int256(uint256(added)), net);
        _settle(key.currency0, net[0]);
        _settle(key.currency1, net[1]);
        emit Deposited(index, b.lower, b.upper, _owed128(net[0]), _owed128(net[1]), added, backstop);
    }

    function _withdraw(address index, PoolKey memory key) private {
        Book storage b = books[index];
        int256[2] memory net;
        uint128 band = positionLiquidity(index);
        uint128 backstop = backstopLiquidity(index);
        if (band != 0) _change(key, b, b.lower, b.upper, BAND_SALT, -int256(uint256(band)), net);
        if (backstop != 0) {
            (int24 lower, int24 upper) = _fullRange(key);
            _change(key, b, lower, upper, BACKSTOP_SALT, -int256(uint256(backstop)), net);
        }
        _settle(key.currency0, net[0]);
        _settle(key.currency1, net[1]);
        (uint256 out0, uint256 out1) = (b.float0, b.float1);
        (b.float0, b.float1) = (0, 0);
        if (out0 != 0) IERC20(Currency.unwrap(key.currency0)).safeTransfer(owner, out0);
        if (out1 != 0) IERC20(Currency.unwrap(key.currency1)).safeTransfer(owner, out1);
        emit Withdrawn(index, owner, out0, out1, band, backstop);
    }

    /// @dev The figures a recenter reports, kept together so the function stays within the stack.
    struct Outcome {
        uint160 from;
        uint160 to;
        uint128 liquidityBefore;
        uint128 liquidityAfter;
        uint256 valueBefore;
        uint256 valueAfter;
    }

    function _recenter(Recenter memory r, PoolKey memory key, address caller) private returns (uint128) {
        Book storage b = books[r.index];
        int256[2] memory net;
        Outcome memory o;
        (o.from,,,) = manager.getSlot0(key.toId());

        // 1. Both positions out of the pool, fees and all. From here the index's holdings are its float.
        o.liquidityBefore = positionLiquidity(r.index);
        if (o.liquidityBefore != 0) _change(key, b, b.lower, b.upper, BAND_SALT, -int256(uint256(o.liquidityBefore)), net);
        {
            uint128 backstop = backstopLiquidity(r.index);
            (int24 lower, int24 upper) = _fullRange(key);
            if (backstop != 0) _change(key, b, lower, upper, BACKSTOP_SALT, -int256(uint256(backstop)), net);
        }
        o.valueBefore = _value(b.float0, b.float1, r.targetSqrtPriceX96);

        // 2. To the target, with the target as the limit, so it can never overshoot.
        if (o.from != r.targetSqrtPriceX96) _swapTo(key, b, r.targetSqrtPriceX96 < o.from, r, net);
        (o.to,,,) = manager.getSlot0(key.toId());
        if (_moveBps(o.to, r.targetSqrtPriceX96) > r.toleranceBps) revert MissedTarget(o.to);
        // Adding liquidity only moves tokens from the float into positions the index still owns, so
        // what it holds now is what it holds at the end. The swap is the only step that can cost.
        o.valueAfter = _value(b.float0, b.float1, r.targetSqrtPriceX96);
        if (o.valueAfter * BPS < o.valueBefore * (BPS - maxLossBps)) revert ValueBelowFloor(o.valueBefore, o.valueAfter);

        // 3. Back in: the backstop from its share of each token, the band from everything else that fits.
        uint128 backstopAfter = _addBackstop(key, b, o.to, r.backstopBps, net);
        if (backstopAfter < r.minBackstopLiquidity) revert LiquidityBelowFloor(backstopAfter);
        (b.lower, b.upper) = (r.tickLower, r.tickUpper);
        o.liquidityAfter = _liquidityFor(o.to, r.tickLower, r.tickUpper, b.float0, b.float1);
        if (o.liquidityAfter < r.minLiquidity || o.liquidityAfter == 0) revert LiquidityBelowFloor(o.liquidityAfter);
        _change(key, b, r.tickLower, r.tickUpper, BAND_SALT, int256(uint256(o.liquidityAfter)), net);
        emit Recentered(r.index, caller, o.from, o.to, r.tickLower, r.tickUpper, o.liquidityBefore, o.liquidityAfter,
            o.valueBefore, o.valueAfter);
        emit BackstopSet(r.index, backstopAfter);
        _settle(key.currency0, net[0]);
        _settle(key.currency1, net[1]);
        return o.liquidityAfter;
    }

    function _swapTo(PoolKey memory key, Book storage b, bool zeroForOne, Recenter memory r, int256[2] memory net) private {
        uint256 available = zeroForOne ? b.float0 : b.float1;
        uint256 amountIn = r.maxSwapIn < available ? r.maxSwapIn : available;
        if (amountIn == 0) amountIn = 1; // an empty pool moves for nothing, but v4 refuses a zero swap
        BalanceDelta d = manager.swap(key, SwapParams(zeroForOne, -int256(amountIn), r.targetSqrtPriceX96), "");
        _book(b, d);
        net[0] += d.amount0();
        net[1] += d.amount1();
    }

    function _change(PoolKey memory key, Book storage b, int24 lower, int24 upper, bytes32 salt, int256 liquidityDelta,
        int256[2] memory net) private returns (BalanceDelta d)
    {
        (d,) = manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, liquidityDelta, salt), "");
        _book(b, d);
        net[0] += d.amount0();
        net[1] += d.amount1();
    }

    // ------------------------------------------------------------------ helpers

    function _pull(PoolKey memory key, address index, uint256 amount0, uint256 amount1) private {
        Book storage b = books[index];
        if (amount0 != 0) IERC20(Currency.unwrap(key.currency0)).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 != 0) IERC20(Currency.unwrap(key.currency1)).safeTransferFrom(msg.sender, address(this), amount1);
        b.float0 += amount0;
        b.float1 += amount1;
    }

    /// @dev Adds `bps` of each token the index holds as full-range liquidity. Zero bps adds nothing.
    function _addBackstop(PoolKey memory key, Book storage b, uint160 price, uint16 bps, int256[2] memory net)
        private returns (uint128 liquidity)
    {
        if (bps == 0) return 0;
        (int24 lower, int24 upper) = _fullRange(key);
        liquidity = _liquidityFor(price, lower, upper, b.float0 * bps / BPS, b.float1 * bps / BPS);
        if (liquidity != 0) _change(key, b, lower, upper, BACKSTOP_SALT, int256(uint256(liquidity)), net);
    }

    function _fullRange(PoolKey memory key) private pure returns (int24, int24) {
        return (TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing));
    }

    /// @dev Moves a pool delta into the index's float. Underflow reverts: the float is all it may spend.
    function _book(Book storage b, BalanceDelta d) private {
        b.float0 = _apply(b.float0, d.amount0());
        b.float1 = _apply(b.float1, d.amount1());
    }

    function _apply(uint256 balance, int128 delta) private pure returns (uint256) {
        if (delta >= 0) return balance + uint256(int256(delta));
        uint256 owed = uint256(-int256(delta));
        if (owed > balance) revert InsufficientFloat();
        return balance - owed;
    }

    function _settle(Currency currency, int256 amount) private {
        if (amount < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), uint256(-amount));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(amount));
        }
    }

    function _owed128(int256 amount) private pure returns (uint256) {
        return amount < 0 ? uint256(-amount) : 0;
    }

    function _checkRange(PoolKey memory key, int24 lower, int24 upper) private pure {
        if (lower >= upper || lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK
            || lower % key.tickSpacing != 0 || upper % key.tickSpacing != 0) revert BadRange();
    }

    /// @dev Both currencies in currency1 units at `sqrtPriceX96`.
    function _value(uint256 amount0, uint256 amount1, uint160 sqrtPriceX96) private pure returns (uint256) {
        return amount1 + FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96);
    }

    /// @dev How far apart two sqrt prices are as prices, in bps of the lower one.
    function _moveBps(uint160 a, uint160 b) private pure returns (uint256) {
        (uint256 hi, uint256 lo) = a > b ? (uint256(a), uint256(b)) : (uint256(b), uint256(a));
        uint256 ratio = FullMath.mulDiv(FullMath.mulDiv(hi, 1e18, lo), hi, lo);
        return (ratio - 1e18) * BPS / 1e18;
    }

    /// @dev One unit under the most the amounts buy, so rounding in the pool can never ask for more.
    function _liquidityFor(uint160 price, int24 lower, int24 upper, uint256 amount0, uint256 amount1)
        private pure returns (uint128)
    {
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(upper);
        uint256 liquidity;
        if (price <= a) {
            liquidity = _forAmount0(a, b, amount0);
        } else if (price < b) {
            uint256 l0 = _forAmount0(price, b, amount0);
            uint256 l1 = _forAmount1(a, price, amount1);
            liquidity = l0 < l1 ? l0 : l1;
        } else {
            liquidity = _forAmount1(a, b, amount1);
        }
        if (liquidity > type(uint128).max) liquidity = type(uint128).max;
        return liquidity == 0 ? 0 : uint128(liquidity - 1);
    }

    function _forAmount0(uint160 a, uint160 b, uint256 amount0) private pure returns (uint256) {
        return FullMath.mulDiv(amount0, FullMath.mulDiv(a, b, FixedPoint96.Q96), b - a);
    }

    function _forAmount1(uint160 a, uint160 b, uint256 amount1) private pure returns (uint256) {
        return FullMath.mulDiv(amount1, FixedPoint96.Q96, b - a);
    }

    function _amountsFor(uint160 price, int24 lower, int24 upper, uint128 liquidity)
        private pure returns (uint256 amount0, uint256 amount1)
    {
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(upper);
        if (price < a) price = a;
        if (price > b) price = b;
        if (price < b) amount0 = FullMath.mulDiv(uint256(liquidity) << 96, b - price, b) / price;
        if (price > a) amount1 = FullMath.mulDiv(liquidity, price - a, FixedPoint96.Q96);
    }
}
