// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ManagedIndexFactory} from "./ManagedIndexFactory.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ShareFeeHook} from "./ShareFeeHook.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice One creator-selected canonical hookless market per managed index.
/// @dev Registration initializes a pool but is not evidence of liquidity or third-party listing.
contract IndexMarketRegistry {
    using StateLibrary for IPoolManager;
    ManagedIndexFactory public immutable factory;
    IPoolManager public immutable manager;
    mapping(address => bool) public quoteAllowed;
    mapping(address => PoolKey) private markets;
    error InvalidMarket();
    error MarketReviewExpired();
    error MarketPriceChanged();
    event MarketRegistered(address indexed index, address indexed quote, PoolId indexed poolId,
        uint24 fee, int24 tickSpacing, uint160 initialPrice);
    event ExistingMarketAdopted(address indexed index, PoolId indexed poolId, uint160 reviewedPrice);

    /// @notice The fee hook every market this registry creates will carry.
    /// @dev    Immutable, because it is part of the PoolKey: a registry that could change it
    ///         would be a registry that silently creates two incompatible pools for one share.
    ///         The zero address means hookless markets, which is what this was before the fee.
    ShareFeeHook public immutable feeHook;

    /// @notice The pool fee every market this registry creates carries, paid to its LPs.
    /// @dev    Read from the hook once at construction rather than per call, so the two can never
    ///         disagree and a hookless deployment still names a fee that pays its providers.
    uint24 public immutable lpFee;

    constructor(ManagedIndexFactory factory_, IPoolManager manager_, ShareFeeHook feeHook_, address[] memory quotes) {
        if (address(factory_).code.length == 0 || address(manager_).code.length == 0 || quotes.length == 0) revert InvalidMarket();
        factory = factory_;
        manager = manager_;
        feeHook = feeHook_;
        lpFee = address(feeHook_) == address(0) ? 1_500 : feeHook_.LP_FEE_BPS();
        for (uint256 i; i < quotes.length; ++i) {
            if (quotes[i].code.length == 0) revert InvalidMarket();
            quoteAllowed[quotes[i]] = true;
        }
    }

    function register(address index, address quote, uint160 initialPrice) external returns (PoolKey memory key) {
        key = _registrationKey(index, quote);
        // Initialization never silently falls back to adoption.
        manager.initialize(key, initialPrice);
        /*
         * Bound to its index in the same transaction that creates it.
         *
         * The hook refuses a swap on a pool it does not know, so a market that existed for even
         * one block before being bound would be a market nobody could trade. Doing both here
         * means there is no such window and no second step for anybody to forget.
         */
        if (address(feeHook) != address(0)) feeHook.register(key, index, factory.creatorOf(index));
        _record(index, quote, key, initialPrice);
    }

    /// @notice Inspect the exact canonical pool before separately authorizing adoption.
    /// @return price Zero when the pool has not been initialized. Not a NAV or liquidity guarantee.
    function existingPrice(address index, address quote) external view returns (uint160 price) {
        PoolKey memory key = _key(index, quote);
        (price,,,) = manager.getSlot0(key.toId());
    }

    /// @notice Adopt an existing pool only at the creator's explicitly reviewed spot price.
    /// @dev Does not move assets or establish liquidity. A changed price requires a new review.
    function adoptExisting(address index, address quote, uint160 reviewedPrice, uint256 deadline)
        external returns (PoolKey memory key)
    {
        key = _registrationKey(index, quote);
        if (block.timestamp > deadline || deadline > block.timestamp + 5 minutes) revert MarketReviewExpired();
        (uint160 currentPrice,,,) = manager.getSlot0(key.toId());
        if (reviewedPrice == 0 || currentPrice != reviewedPrice) revert MarketPriceChanged();
        _record(index, quote, key, currentPrice);
        emit ExistingMarketAdopted(index, key.toId(), currentPrice);
    }

    function _registrationKey(address index, address quote) private view returns (PoolKey memory) {
        if (factory.creatorOf(index) != msg.sender || !quoteAllowed[quote] || index == quote
            || Currency.unwrap(markets[index].currency0) != address(0)) revert InvalidMarket();
        return _key(index, quote);
    }

    function _key(address index, address quote) private view returns (PoolKey memory) {
        if (factory.creatorOf(index) == address(0) || !quoteAllowed[quote] || index == quote) revert InvalidMarket();
        /*
         * 15 bps to liquidity providers, and `ShareFeeHook` takes another 15 on top. A trader
         * pays 0.30% in total, split evenly between the people who supply the depth and the
         * people who made the thing worth trading.
         *
         * Not zero. A zero pool fee pays LPs nothing, and this design needs outside liquidity in
         * a way the pons design does not: there, the creator's locked position is all there is.
         *
         * Was `(3000, 60, hook 0x0)` and changing it changes the pool id, so every market this
         * registry made before is orphaned. Safe only because `managed/` has never been deployed
         * to mainnet. It must never change again once it has.
         */
        return PoolKey(Currency.wrap(index < quote ? index : quote), Currency.wrap(index < quote ? quote : index),
            lpFee, 60, IHooks(address(feeHook)));
    }

    function _record(address index, address quote, PoolKey memory key, uint160 price) private {
        markets[index] = key;
        emit MarketRegistered(index, quote, key.toId(), key.fee, key.tickSpacing, price);
    }

    function marketFor(address index) external view returns (PoolKey memory) {
        return markets[index];
    }
}
