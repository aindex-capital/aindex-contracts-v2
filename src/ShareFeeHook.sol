// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFolioLike {
    function totalSupply() external view returns (uint256);
    function toAssets(uint256 shares, uint8 rounding)
        external view returns (address[] memory assets, uint256[] memory amounts);
    function redeem(uint256 shares, address receiver, address[] calldata assets, uint256[] calldata minAmountsOut)
        external returns (uint256[] memory amounts);
}

/// @title  ShareFeeHook
/// @notice Charges the index share's swap fee, and splits it three ways.
///
/// @dev    ## WHY THIS SHAPE AND NOT A CUSTOM CURVE
///
///         An earlier design made the pool a facade: `beforeSwapReturnDelta` consumed the swap
///         and a dealer filled it from inventory at net asset value. It was written, tested and
///         abandoned, because a pool whose curve is bypassed is invisible to the infrastructure
///         that makes a token tradable.
///
///         Two consequences, one cause. Such a pool holds no reserves, so an indexer deriving
///         liquidity and volume from reserves lists nothing. And `Swap` is emitted with **zero
///         amounts**, because the pool's own arithmetic never ran, so anything reading events
///         sees no trade at all. An aggregator cannot quote what it cannot simulate, and a chart
///         cannot draw what was never reported.
///
///         So this hook does not touch the curve. `afterSwap` only, after the pool's own
///         arithmetic has run and emitted a truthful `Swap`. Real reserves, real events, real
///         price, and a fee taken from the result rather than in place of it.
///
///         The pool keeps its own fee for liquidity providers and this hook charges on top. Both
///         are needed: without the first nobody supplies depth, and without the second the
///         protocol earns nothing from the depth it helped create.
///
///         ## WHERE THE FEE COMES FROM
///
///         Uniswap only lets `afterSwap` take from the **unspecified** currency, so on an
///         exact-input swap the fee is the output token, which the trader receives less of, and
///         on an exact-output swap it is the input token, which the trader pays more of. Across a
///         balanced market that is roughly half SHARE and half quote, and both are handled rather
///         than one being preferred.
///
///         ## THE THREE BUCKETS
///
///         Fixed in the contract rather than settable, so "the creator takes 40%" is a property
///         of this code and not of the values it happened to be deployed with.
contract ShareFeeHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    /// @dev afterSwap | afterSwapReturnDelta. The address this deploys to must carry exactly
    ///      these bits; `mine-hook-salt.mjs` finds the CREATE2 salt.
    uint160 internal constant REQUIRED_FLAGS =
        uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    uint256 internal constant BPS = 10_000;

    /// @notice Taken by this hook, in basis points, **on top of the pool's own LP fee**.
    ///
    /// @dev    The trader pays `LP_FEE_BPS + FEE_BPS`, which is 30 bps in total: 15 to whoever
    ///         provides the depth and 15 to the people who made the thing worth trading.
    ///
    ///         Charging on top of the LP fee rather than instead of it is deliberate and it is a
    ///         production pattern, not an invention: Uniswap's own hooklist carries
    ///         `BSC_FeeCaptureHook`, which applies a dynamic LP fee and separately takes a hook
    ///         fee through `poolManager.take`, and `UniswapV4SwapFeeHookV1` on Base does the same
    ///         with configurable buy and sell rates.
    ///
    ///         An earlier version took the whole fee and left the pool's own at zero. That is
    ///         coherent only where a single locked position supplies all the liquidity there will
    ///         ever be. Here depth is meant to come from anyone, and a provider earning nothing
    ///         does not turn up.
    uint16 public constant FEE_BPS = 15;

    /// @notice What the pool itself charges, paid to liquidity providers by Uniswap.
    /// @dev    Enforced in `register` so a market cannot be created that silently pays LPs
    ///         nothing, which is the failure this constant exists to make impossible.
    uint24 public constant LP_FEE_BPS = 1_500; // 0.15% in v4's hundredths-of-a-bip units

    /// @dev 40 / 40 / 20. Constants, not settings: see the note above.
    uint16 public constant CREATOR_BPS = 4_000;
    uint16 public constant PROTOCOL_BPS = 4_000;
    uint16 public constant HOLDER_BPS = 2_000;

    IPoolManager public immutable poolManager;
    address public immutable registrar;
    address public immutable protocolRecipient;

    struct Market {
        address share;
        address creator;
        bool registered;
    }

    mapping(PoolId => Market) public markets;


    /// @dev Accrued per pool per currency. Settled by `claim` and `payHolders`.
    mapping(PoolId => mapping(Currency => uint256)) public creatorFees;
    mapping(PoolId => mapping(Currency => uint256)) public protocolFees;
    mapping(PoolId => mapping(Currency => uint256)) public holderFees;


    event MarketRegistered(PoolId indexed id, address indexed share, address indexed creator);
    event FeeCharged(PoolId indexed id, Currency indexed currency, uint256 creator, uint256 protocol, uint256 holder);
    event FeeClaimed(PoolId indexed id, Currency indexed currency, address indexed to, uint256 amount);
    event HoldersPaid(PoolId indexed id, Currency indexed currency, uint256 amount, uint256 sharesBurned);

    error NotPoolManager();
    error NotRegistrar();
    error AlreadyRegistered();
    error UnknownMarket();
    error HookNotImplemented();
    error BadFlags();
    error WrongLpFee();
    error NothingAccrued();
    error NotPayableToHolders();
    error BuybackBelowMinimum(uint256 shares, uint256 minimum);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager_, address registrar_, address protocolRecipient_) {
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != REQUIRED_FLAGS) revert BadFlags();
        poolManager = poolManager_;
        registrar = registrar_;
        protocolRecipient = protocolRecipient_;
    }

    /// @notice Bind a pool to the index whose share it trades, and to that index's creator.
    /// @dev    Called by the market registry at launch. One hook serves every index, keyed by
    ///         pool id, so the address is mined once rather than per launch.
    function register(PoolKey calldata key, address share, address creator) external {
        if (msg.sender != registrar) revert NotRegistrar();
        // The pool must pay its liquidity providers. See LP_FEE_BPS.
        if (key.fee != LP_FEE_BPS) revert WrongLpFee();
        PoolId id = key.toId();
        if (markets[id].registered) revert AlreadyRegistered();
        markets[id] = Market({share: share, creator: creator, registered: true});
        emit MarketRegistered(id, share, creator);
    }

    // ------------------------------------------------------------------ the hook

    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        Market memory m = markets[id];
        if (!m.registered) revert UnknownMarket();

        /*
         * The unspecified currency is the only one `afterSwap` may take from, and which one that
         * is depends on the direction and on whether the swap was exact input or exact output.
         *
         * `amountSpecified < 0` is exact input, so the specified side is the input and the
         * unspecified side is the output.
         */
        bool exactInput = params.amountSpecified < 0;
        (Currency currency, int128 unspecified) = exactInput
            ? (params.zeroForOne ? key.currency1 : key.currency0,
               params.zeroForOne ? delta.amount1() : delta.amount0())
            : (params.zeroForOne ? key.currency0 : key.currency1,
               params.zeroForOne ? delta.amount0() : delta.amount1());

        /*
         * This hook's own buyback (see `payHolders`) is holders' money buying shares for holders.
         * Charging it would pay part of that back to the creator and the protocol.
         */
        if (sender == address(this)) return (IHooks.afterSwap.selector, int128(0));

        /*
         * Either side can carry the fee. On exact input the unspecified side is the output, which
         * the trader is owed (positive); returning the fee pays them that much less. On exact
         * output it is the input, which the trader owes (negative); returning the fee makes them
         * owe that much more. Either way the hook is then credited the fee and takes it.
         *
         * This used to return early on a negative delta, so an exact-output swap paid the pool's
         * LP fee and nothing else. Our own router only swaps exact input; an aggregator need not.
         */
        if (unspecified == 0) return (IHooks.afterSwap.selector, int128(0));
        uint128 magnitude = unspecified > 0 ? uint128(unspecified) : uint128(-unspecified);

        uint256 fee = (uint256(magnitude) * FEE_BPS) / BPS;
        if (fee == 0) return (IHooks.afterSwap.selector, int128(0));

        /*
         * Split before taking, and give the remainder to holders.
         *
         * Rounding down on two buckets and assigning what is left to the third means the three
         * always sum to exactly `fee`. Rounding all three independently would leave dust that
         * belongs to nobody and accumulates in this contract forever.
         */
        uint256 toCreator = (fee * CREATOR_BPS) / BPS;
        uint256 toProtocol = (fee * PROTOCOL_BPS) / BPS;
        uint256 toHolders = fee - toCreator - toProtocol;

        creatorFees[id][currency] += toCreator;
        protocolFees[id][currency] += toProtocol;
        holderFees[id][currency] += toHolders;

        // Take the fee into this contract as ERC-6909 credit, then withdraw it to real tokens.
        poolManager.take(currency, address(this), fee);

        emit FeeCharged(id, currency, toCreator, toProtocol, toHolders);
        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }

    // ------------------------------------------------------------------ settlement

    /// @notice Pay out the creator's and the protocol's accrued fees. Permissionless: the
    ///         destination is read from storage, never from the caller.
    function claim(PoolKey calldata key, Currency currency) external {
        PoolId id = key.toId();
        Market memory m = markets[id];
        if (!m.registered) revert UnknownMarket();

        uint256 c = creatorFees[id][currency];
        uint256 p = protocolFees[id][currency];
        if (c == 0 && p == 0) revert NothingAccrued();

        if (c != 0) {
            creatorFees[id][currency] = 0;
            _send(currency, m.creator, c);
            emit FeeClaimed(id, currency, m.creator, c);
        }
        if (p != 0) {
            protocolFees[id][currency] = 0;
            _send(currency, protocolRecipient, p);
            emit FeeClaimed(id, currency, protocolRecipient, p);
        }
    }

    /**
     * @notice Pay the holders' accrued fees into the index, raising backing per share.
     *
     * @param  minSharesOut Only used when the fee is in a quote token that is not in the basket,
     *         which is bought back into shares first. The fewest shares the caller accepts for it;
     *         the call reverts below that. Ignored for the other two currencies.
     *
     * @dev    Permissionless, because it is holders' money and they should not need us to move it.
     *
     *         ## WHY BACKING RATHER THAN A CLAIM, WHICH WAS TRIED
     *
     *         A per-holder accrual needs a checkpoint on every share transfer, and the share is
     *         Reserve's Folio. Two things rule it out and the second is absolute:
     *
     *         Folio's `_update` is not `virtual`, so it cannot be overridden by a subclass. That
     *         one is fixable: a four-line patch adding `virtual` to four functions, changing no
     *         logic, was written and worked.
     *
     *         **Folio's deployed bytecode is 24,553 bytes against an EIP-170 limit of 24,576.**
     *         Twenty-three bytes of headroom. A subclass whose only addition is one external call
     *         in `_update` measures 24,696 even with no public getter and no try/catch, which is
     *         120 bytes over. Folio cannot be extended at all, by anyone, and no amount of care
     *         with the override changes that.
     *
     *         So the accrual lives nowhere and the value goes into backing instead. Folio prices
     *         its basket from `balanceOf(address(this))`, so an asset sent to it raises backing
     *         per share for every holder at once, permissionlessly, with nothing to claim, forget
     *         or round wrong.
     *
     *         ## THE THREE CURRENCIES
     *
     *         **A basket asset** goes straight in.
     *
     *         **The share itself** cannot: Folio rejects a transfer to itself by design. So it is
     *         redeemed and the proceeds are sent back. Supply falls by the redeemed shares and the
     *         basket returns whole, so backing per share rises by exactly the proportion a burn
     *         would give. Both steps are Folio's own public API.
     *
     *         **The pool's quote token, when it is not a basket asset**, is the fee every exact-input
     *         sell pays. It used to be refused, and with no other way out it sat here forever:
     *         holders were owed it and could never receive it. Now it buys shares in this pool and
     *         those are redeemed as above, a buyback and burn. That needs a price, which the rest of
     *         this design avoids, so the caller brings one as `minSharesOut`. A caller could pass
     *         zero and sandwich its own call; what they could take is bounded by the accrual, while
     *         moving this pool's price enough to take it costs the fee on the capital used to move
     *         it, both ways. Paying out often keeps the accrual, and so the prize, small.
     */
    function payHolders(PoolKey calldata key, Currency currency, uint256 minSharesOut) external {
        PoolId id = key.toId();
        Market memory m = markets[id];
        if (!m.registered) revert UnknownMarket();

        uint256 amount = holderFees[id][currency];
        if (amount == 0) revert NothingAccrued();
        holderFees[id][currency] = 0;

        address token = Currency.unwrap(currency);

        if (token == m.share) {
            uint256 burned = _returnThroughRedeem(m.share, amount);
            emit HoldersPaid(id, currency, amount, burned);
            return;
        }

        if (_isBasketAsset(m.share, token)) {
            IERC20(token).safeTransfer(m.share, amount);
            emit HoldersPaid(id, currency, amount, 0);
            return;
        }

        // Only this pool's own other currency can be bought back through it.
        if (!(key.currency0 == currency || key.currency1 == currency)) {
            holderFees[id][currency] = amount; // untouched; this call changes nothing
            revert NotPayableToHolders();
        }

        (uint256 spent, uint256 shares) = abi.decode(poolManager.unlock(abi.encode(key, currency, amount)), (uint256, uint256));
        if (shares < minSharesOut) revert BuybackBelowMinimum(shares, minSharesOut);
        // A price limit can stop a swap short; whatever it did not spend stays owed to holders.
        if (spent < amount) holderFees[id][currency] = amount - spent;
        _returnThroughRedeem(m.share, shares);
        emit HoldersPaid(id, currency, spent, shares);
    }

    /// @notice The buyback swap, inside the PoolManager's lock. Only the PoolManager calls this,
    ///         and only because `payHolders` asked it to.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (PoolKey memory key, Currency currency, uint256 amount) = abi.decode(data, (PoolKey, Currency, uint256));
        bool zeroForOne = key.currency0 == currency;
        BalanceDelta d = poolManager.swap(key, SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        }), "");
        (int128 inDelta, int128 outDelta) = zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        uint256 spent = uint256(uint128(-inDelta));
        uint256 shares = uint256(uint128(outDelta));

        // Pay what the swap used, then take the shares it bought.
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), spent);
        poolManager.settle();
        poolManager.take(zeroForOne ? key.currency1 : key.currency0, address(this), shares);
        return abi.encode(spent, shares);
    }

    /// @dev Redeem shares back into the basket and return every asset to it. Net effect: supply
    ///      falls, holdings are unchanged, backing per share rises.
    function _returnThroughRedeem(address share, uint256 shares) private returns (uint256) {
        (address[] memory assets,) = IFolioLike(share).toAssets(shares, 0);
        uint256[] memory floors = new uint256[](assets.length);
        uint256[] memory got = IFolioLike(share).redeem(shares, address(this), assets, floors);
        for (uint256 i; i < assets.length; ++i) {
            if (got[i] != 0) IERC20(assets[i]).safeTransfer(share, got[i]);
        }
        return shares;
    }

    function _isBasketAsset(address share, address token) private view returns (bool) {
        (address[] memory assets,) = IFolioLike(share).toAssets(1e18, 0);
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == token) return true;
        }
        return false;
    }

    function _send(Currency currency, address to, uint256 amount) private {
        IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
    }

    // ------------------------------------------------------------------ unused callbacks

    /*
     * Every other callback reverts rather than returning its selector. The permission bits in
     * this contract's address mean the PoolManager will never call them, so a call arriving here
     * is evidence something is wrong, and answering it politely would hide that.
     */
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure returns (bytes4) { revert HookNotImplemented(); }
    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure returns (bytes4) { revert HookNotImplemented(); }
    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external pure returns (bytes4, BeforeSwapDelta, uint24) { revert HookNotImplemented(); }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure returns (bytes4) { revert HookNotImplemented(); }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure returns (bytes4) { revert HookNotImplemented(); }
}
