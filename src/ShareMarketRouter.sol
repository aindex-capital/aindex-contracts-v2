// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice ERC20-only router for ordinary v4 share markets, hookless or carrying the one known fee hook.
/// @dev No approvals to PoolManager, persistent custody, NAV dependency or constituent execution.
/// LP positions belong to msg.sender through a namespaced salt. Not independently audited.
contract ShareMarketRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    bool private unlocking;

    error InvalidMarket();
    error Expired();
    error InvalidAmount();
    error Slippage();
    error UnauthorizedCallback();
    error QuoteResult(int256 delta);
    error UnexpectedQuoteResult();

    /// Net deltas are from the owner's perspective: negative pays in, positive receives.
    /// Settled fees are included in netDelta, never additional proceeds.
    event LiquidityChanged(address indexed owner, bytes32 indexed poolId, bytes32 indexed position,
        address currency0, address currency1, int24 lower, int24 upper, int256 liquidityDelta,
        int256 netDelta, int256 feeDelta);

    struct Request {
        address payer;
        address owner;
        PoolKey key;
        bool swap;
        bool quote;
        bool zeroForOne;
        uint256 amount;
        uint160 priceLimit;
        ModifyLiquidityParams position;
        uint256 limit0;
        uint256 limit1;
    }

    /// @notice The one hook this router will trade through, besides no hook at all.
    /// @dev    Immutable and singular on purpose. The original rule here was "no hooks", which
    ///         was the right guarantee and the wrong shape: the fee has to come from somewhere
    ///         and `ShareFeeHook` is where it comes from. Allowing exactly one known address
    ///         keeps what the rule was protecting, which is that this router never hands a swap
    ///         to code nobody chose. Set it to the zero address for a hookless-only deployment.
    address public immutable feeHook;

    /// @notice The one contract allowed to open a position on somebody else's behalf.
    /// @dev    The factory, so a launch can seed the market in the same transaction that creates
    ///         the index. It can only ever ADD liquidity and only ever to the owner it names;
    ///         removal still derives its salt from `msg.sender`, so nobody can be relieved of a
    ///         position they hold. Zero disables the path entirely.
    address public immutable launcher;

    constructor(IPoolManager manager_, address feeHook_, address launcher_) {
        if (address(manager_).code.length == 0) revert InvalidMarket();
        manager = manager_;
        feeHook = feeHook_;
        launcher = launcher_;
    }

    function positionSalt(address owner, bytes32 userSalt) public pure returns (bytes32) {
        return keccak256(abi.encode(owner, userSalt));
    }

    /// @notice Simulates native pricing without approvals or funds. Inner pool changes are reverted.
    function quoteExactInput(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint160 priceLimit)
        external nonReentrant returns (BalanceDelta delta)
    {
        _validate(key, type(uint256).max);
        if (amountIn == 0 || amountIn > uint256(uint128(type(int128).max))) revert InvalidAmount();
        Request memory r;
        r.key = key;
        r.swap = true;
        r.quote = true;
        r.zeroForOne = zeroForOne;
        r.amount = amountIn;
        r.priceLimit = priceLimit;
        unlocking = true;
        try manager.unlock(abi.encode(r)) returns (bytes memory) {
            revert UnexpectedQuoteResult();
        } catch (bytes memory reason) {
            unlocking = false;
            if (reason.length != 36 || bytes4(reason) != QuoteResult.selector) {
                assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
            }
            int256 packed;
            assembly ("memory-safe") { packed := mload(add(reason, 36)) }
            return BalanceDelta.wrap(packed);
        }
    }

    function marketState(PoolKey calldata key) external view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee, uint128 liquidity)
    {
        (sqrtPriceX96, tick, protocolFee, lpFee) = manager.getSlot0(key.toId());
        liquidity = manager.getLiquidity(key.toId());
    }

    function positionLiquidity(PoolKey calldata key, address owner, int24 lower, int24 upper, bytes32 userSalt)
        external view returns (uint128 liquidity)
    {
        (liquidity,,) = manager.getPositionInfo(key.toId(), address(this), lower, upper, positionSalt(owner, userSalt));
    }

    function swapExactInput(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minOut,
        uint160 priceLimit,
        uint256 deadline
    ) external nonReentrant returns (BalanceDelta delta) {
        _validate(key, deadline);
        if (amountIn == 0 || amountIn > uint256(uint128(type(int128).max))) revert InvalidAmount();
        Request memory r;
        r.payer = msg.sender;
        r.key = key;
        r.swap = true;
        r.zeroForOne = zeroForOne;
        r.amount = amountIn;
        r.priceLimit = priceLimit;
        r.limit0 = minOut;
        return _unlock(r);
    }

    /// @param limit0 Maximum token0 payment on add; minimum token0 receipt on remove/collect.
    /// @param limit1 Maximum token1 payment on add; minimum token1 receipt on remove/collect.
    function modifyLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        uint256 limit0,
        uint256 limit1,
        uint256 deadline
    ) external nonReentrant returns (BalanceDelta delta) {
        _validate(key, deadline);
        Request memory r;
        r.payer = msg.sender;
        r.key = key;
        r.position = params;
        r.position.salt = positionSalt(msg.sender, params.salt);
        r.owner = msg.sender;
        r.limit0 = limit0;
        r.limit1 = limit1;
        return _unlock(r);
    }

    /**
     * @notice Open a position owned by `owner`, paid for by the caller. Launcher only.
     *
     * @dev    Exists so an index is tradeable in the same transaction it is created. Without it
     *         a launch produces a share with no market, which is the cold-start problem this
     *         design has and the retired dealer design did not.
     *
     *         Three bounds, and they are what make lending the salt safe:
     *
     *         1. **Only the launcher may call it.** One immutable address, set at construction.
     *         2. **It may only add.** A negative delta is refused, so this can never be used to
     *            take a position away from the person who holds it.
     *         3. **Removal is unchanged.** Withdrawal still derives its salt from `msg.sender`,
     *            so the owner named here, and nobody else, can ever get these funds out.
     */
    function modifyLiquidityFor(
        address owner,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        uint256 limit0,
        uint256 limit1,
        uint256 deadline
    ) external nonReentrant returns (BalanceDelta delta) {
        if (msg.sender != launcher || launcher == address(0)) revert InvalidMarket();
        if (params.liquidityDelta <= 0) revert InvalidAmount();
        _validate(key, deadline);
        Request memory r;
        r.key = key;
        r.position = params;
        r.position.salt = positionSalt(owner, params.salt);
        r.payer = msg.sender;
        // The factory pays for a launch seed, but the position is the creator's, and the event
        // is what the indexer attributes it by.
        r.owner = owner;
        r.limit0 = limit0;
        r.limit1 = limit1;
        return _unlock(r);
    }

    function _validate(PoolKey calldata key, uint256 deadline) private view {
        if (block.timestamp > deadline) revert Expired();
        /*
         * No hook, or the one hook this router was deployed to know.
         *
         * A user is still protected by `minOut` rather than by the absence of a hook: the fee is
         * taken from the output and the swap reverts if what arrives is short. That is the same
         * bound that protects them from price impact, and it does not care why the output was
         * smaller than they hoped.
         */
        address hooks = address(key.hooks);
        if ((hooks != address(0) && hooks != feeHook) || Currency.unwrap(key.currency0) == address(0)
            || Currency.unwrap(key.currency0) >= Currency.unwrap(key.currency1)) revert InvalidMarket();
    }

    function _unlock(Request memory r) private returns (BalanceDelta) {
        unlocking = true;
        bytes memory result = manager.unlock(abi.encode(r));
        unlocking = false;
        return abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || !unlocking) revert UnauthorizedCallback();
        Request memory r = abi.decode(data, (Request));
        BalanceDelta delta;
        BalanceDelta fees;
        if (r.swap) {
            delta = manager.swap(r.key, SwapParams(r.zeroForOne, -int256(r.amount), r.priceLimit), "");
            if (r.quote) revert QuoteResult(BalanceDelta.unwrap(delta));
            int128 input = r.zeroForOne ? delta.amount0() : delta.amount1();
            int128 output = r.zeroForOne ? delta.amount1() : delta.amount0();
            if (input >= 0 || output <= 0 || uint256(-int256(input)) > r.amount
                || uint256(int256(output)) < r.limit0) revert Slippage();
        } else {
            (delta,fees) = manager.modifyLiquidity(r.key, r.position, "");
            if (r.position.liquidityDelta > 0) {
                if (_owed(delta.amount0()) > r.limit0 || _owed(delta.amount1()) > r.limit1) revert Slippage();
            } else if (delta.amount0() < 0 || delta.amount1() < 0
                || uint256(int256(delta.amount0())) < r.limit0
                || uint256(int256(delta.amount1())) < r.limit1) revert Slippage();
        }
        _settle(r.key.currency0, r.payer, delta.amount0());
        _settle(r.key.currency1, r.payer, delta.amount1());
        if (!r.swap) emit LiquidityChanged(r.owner, PoolId.unwrap(r.key.toId()), r.position.salt,
            Currency.unwrap(r.key.currency0), Currency.unwrap(r.key.currency1), r.position.tickLower,
            r.position.tickUpper, r.position.liquidityDelta, BalanceDelta.unwrap(delta), BalanceDelta.unwrap(fees));
        return abi.encode(delta);
    }

    function _owed(int128 amount) private pure returns (uint256) {
        return amount < 0 ? uint256(-int256(amount)) : 0;
    }

    function _settle(Currency currency, address payer, int128 amount) private {
        if (amount < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), _owed(amount));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, payer, uint256(int256(amount)));
        }
    }
}
