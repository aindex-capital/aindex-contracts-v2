// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Folio} from "folio/Folio.sol";
import {IFolio} from "folio/interfaces/IFolio.sol";
import {IndexFactoryBase} from "./IndexFactoryBase.sol";
import {MonthlyMandate} from "./MonthlyMandate.sol";
import {MandateDeployer} from "./MandateDeployer.sol";
import {IndexMarketRegistry} from "./IndexMarketRegistry.sol";
import {ShareMarketRouter} from "./ShareMarketRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Creates indexes, each run by a monthly mandate and each with its market. Not audited.
/// @dev The creator never holds a role on the index itself: it answers only to its mandate, whose
///      roles the creator may hold alone or share with an independent reviewer and guardian.
contract IndexFactory is IndexFactoryBase {
    using SafeERC20 for IERC20;

    /**
     * The market plumbing, wired once after deployment.
     *
     * A setter rather than a constructor argument because the registry takes this factory in
     * *its* constructor, so one of the two has to learn about the other afterwards. It can be
     * called once and only by whoever deployed this, which is the smallest exception that closes
     * the cycle: the alternative is predicting addresses from nonces, and a launch flow that
     * breaks when somebody adds a transaction to the deploy script is worse than one setter.
     */
    IndexMarketRegistry public marketRegistry;
    ShareMarketRouter public marketRouter;
    address public immutable deployer;
    /// @notice Creates each index's mandate, so the mandate's code does not count against this contract's size.
    MandateDeployer public immutable mandateDeployer;
    bool public marketWired;

    mapping(address => address) public mandateOf;
    mapping(address => address) public creatorOf;
    mapping(address => string) public metadataURI;
    error MarketAlreadyWired();
    error MarketNotWired();
    error SeedTooSmall();
    event MetadataUpdated(address indexed index, string uri);
    event ManagedIndexCreated(address indexed index, address indexed mandate, address indexed creator,
        bytes32 methodologyHash);

    /**
     * @dev Admission is open: any token contract may be put in a basket. There is no list here
     *      and nobody holds a power to change one.
     *
     *      Each index still fixes its own universe at creation and its mandate can never add to
     *      it, so what a creator picks affects only the people who choose to hold that index.
     *      What is checked is what can be checked on chain: the token has code and the seed
     *      arrives in full, which rejects fee-on-transfer tokens at launch (`IndexFactoryBase`).
     *
     *      What cannot be checked is behaviour later. Folio's `redeem` transfers every asset in
     *      one loop, so a token that is paused, blacklists the index or simply starts reverting
     *      blocks redemption of the whole basket. Which tokens are known to be sound is therefore
     *      an application concern, shown to people as verification, not a rule enforced here.
     */
    constructor(address implementation_, address feeRegistry_) IndexFactoryBase(implementation_, feeRegistry_) {
        deployer = msg.sender;
        mandateDeployer = new MandateDeployer();
    }

    function create(IFolio.FolioBasicDetails calldata) external pure override returns (Folio) {
        revert InvalidConfiguration();
    }

    function createManaged(
        IFolio.FolioBasicDetails calldata seed,
        MonthlyMandate.Config calldata cfg,
        MonthlyMandate.TokenRule[] calldata rules
    ) external nonReentrant returns (Folio index, MonthlyMandate mandate) {
        return _createManaged(seed, cfg, rules, msg.sender);
    }

    /// @dev `shareRecipient` is the factory itself on the seeded path, so the shares are here to
    ///      open the market with. The creator is `msg.sender` in both cases.
    function _createManaged(
        IFolio.FolioBasicDetails calldata seed,
        MonthlyMandate.Config calldata cfg,
        MonthlyMandate.TokenRule[] calldata rules,
        address shareRecipient
    ) private returns (Folio index, MonthlyMandate mandate) {
        index = _createIndex(seed, shareRecipient);
        mandate = _attachMandate(index, cfg, rules);
        emit ManagedIndexCreated(address(index), address(mandate), msg.sender, cfg.methodologyHash);
    }

    function _createIndex(IFolio.FolioBasicDetails calldata seed, address shareRecipient) private returns (Folio index) {
        if (bytes(seed.name).length == 0 || bytes(seed.name).length > 64
            || bytes(seed.symbol).length == 0 || bytes(seed.symbol).length > 16) revert InvalidConfiguration();
        index = _createFor(seed, shareRecipient, msg.sender);
        creatorOf[address(index)] = msg.sender;
    }

    /// @dev Hands the index to its mandate and gives up the factory's admin role, so after this the
    ///      mandate is the only authority over the index and nothing can take it back.
    function _attachMandate(Folio index, MonthlyMandate.Config calldata cfg, MonthlyMandate.TokenRule[] calldata rules)
        private returns (MonthlyMandate mandate)
    {
        index.setMaxAuctionLength(cfg.auctionLength);
        index.setMandate("Monthly mandate: announced token universe and fixed limits; roles and notice are on the mandate contract.");
        mandate = mandateDeployer.deploy(index, cfg, rules);
        index.grantRole(bytes32(0), address(mandate));
        index.grantRole(keccak256("REBALANCE_MANAGER"), address(mandate));
        index.grantRole(keccak256("AUCTION_LAUNCHER"), address(mandate));
        index.renounceRole(bytes32(0), address(this));
        mandate.activate();
        mandateOf[address(index)] = address(mandate);
    }

    /**
     * @notice Point an index at its public profile: name, image, description and links, as a JSON
     *         document (normally on IPFS). Its creator only; it can be changed later.
     * @dev    Where explorers and listing sites can find what an index looks like. Folio itself has
     *         no room for such fields, so they live here, keyed by the index, as a launchpad would
     *         keep them on its tokens.
     */
    function setMetadata(address index, string calldata uri) external {
        if (creatorOf[index] != msg.sender) revert InvalidConfiguration();
        _setMetadata(index, uri);
    }

    function _setMetadata(address index, string calldata uri) private {
        if (bytes(uri).length > 2048) revert InvalidConfiguration();
        metadataURI[index] = uri;
        emit MetadataUpdated(index, uri);
    }

    /// @notice Point this factory at the market it launches into. Once, by the deployer.
    function wireMarket(IndexMarketRegistry registry_, ShareMarketRouter router_) external {
        if (msg.sender != deployer || marketWired) revert MarketAlreadyWired();
        if (address(registry_).code.length == 0 || address(router_).code.length == 0) revert InvalidConfiguration();
        marketRegistry = registry_;
        marketRouter = router_;
        marketWired = true;
    }

    /**
     * @notice Create a managed index and its market in one transaction.
     *
     * @dev    **This is the production entry point. `createManaged` leaves an index nobody can
     *         buy.** A share with no pool is not a product: the design gave up the dealer hook
     *         precisely so that depth comes from a real pool, and a launch that does not open one
     *         hands the creator an asset with no market and no way to get one without a second
     *         transaction they may never send.
     *
     *         So the seed is required and atomic. The creator supplies the basket, as they
     *         already did, plus quote currency, and leaves holding both their shares and the
     *         liquidity position. The position is theirs: `modifyLiquidityFor` names them as the
     *         owner and only they can ever withdraw it.
     *
     * @param  quote         the currency the market prices the share in
     * @param  initialPrice  quote per share, as a sqrtPriceX96 read with the share as currency0.
     *                       Always this orientation, because which side the share actually sorts
     *                       to depends on the index address, and that does not exist until this
     *                       transaction runs. The factory flips it when the share sorts second.
     * @param  quoteSeed     how much quote to put in the pool alongside the shares
     * @param  shareSeed     how many of the freshly minted shares to put in beside it
     * @param  tickLower     position bounds; full range is the sane default and what the UI sends
     * @param  metadata      the index's profile URI (see `setMetadata`); empty to set none
     */
    function createManagedWithMarket(
        IFolio.FolioBasicDetails calldata seed,
        MonthlyMandate.Config calldata cfg,
        MonthlyMandate.TokenRule[] calldata rules,
        address quote,
        uint160 initialPrice,
        uint256 quoteSeed,
        uint256 shareSeed,
        int24 tickLower,
        int24 tickUpper,
        string calldata metadata
    ) external nonReentrant returns (Folio index, MonthlyMandate mandate, PoolKey memory key) {
        if (!marketWired) revert MarketNotWired();
        if (quoteSeed == 0 || shareSeed == 0 || shareSeed >= seed.initialShares) revert SeedTooSmall();

        (index, mandate) = _createManaged(seed, cfg, rules, address(this));
        // The profile is set in the launch itself, so an index is never public without one.
        if (bytes(metadata).length != 0) _setMetadata(address(index), metadata);
        key = _launchMarket(address(index), MarketSeed(quote, initialPrice, quoteSeed, shareSeed, tickLower, tickUpper));
    }

    function _launchMarket(address index, MarketSeed memory m) private returns (PoolKey memory key) {
        m.initialPrice = index < m.quote ? m.initialPrice : _invert(m.initialPrice);
        key = marketRegistry.register(index, m.quote, m.initialPrice);
        _openMarket(index, key, m);
    }

    /// @dev The launch's market arguments, grouped so the seeding step fits on the stack.
    struct MarketSeed {
        address quote;
        uint160 initialPrice;
        uint256 quoteSeed;
        uint256 shareSeed;
        int24 tickLower;
        int24 tickUpper;
    }

    function _openMarket(address index, PoolKey memory key, MarketSeed memory m) private {
        /*
         * The shares are here, not with the creator: `_createManaged` mints to this contract so
         * the seed can be placed without a round trip. Everything not seeded goes straight on.
         */
        IERC20(m.quote).safeTransferFrom(msg.sender, address(this), m.quoteSeed);
        IERC20(m.quote).forceApprove(address(marketRouter), m.quoteSeed);
        IERC20(index).forceApprove(address(marketRouter), m.shareSeed);

        // The router's limits are per currency, and which side the share lands on depends on
        // how the two addresses sort.
        (uint256 amount0, uint256 amount1) = Currency.unwrap(key.currency0) == index
            ? (m.shareSeed, m.quoteSeed) : (m.quoteSeed, m.shareSeed);
        uint128 liquidity = _liquidityFor(m.initialPrice, m.tickLower, m.tickUpper, amount0, amount1);
        if (liquidity == 0) revert SeedTooSmall();

        marketRouter.modifyLiquidityFor(
            msg.sender, key,
            ModifyLiquidityParams(m.tickLower, m.tickUpper, int256(uint256(liquidity)), bytes32(0)),
            amount0, amount1, block.timestamp
        );

        // Whatever the pool did not take, and every share not seeded, belongs to the creator.
        // Allowances are cleared so the factory never leaves a standing approval behind.
        IERC20(m.quote).forceApprove(address(marketRouter), 0);
        IERC20(index).forceApprove(address(marketRouter), 0);
        IERC20(index).safeTransfer(msg.sender, IERC20(index).balanceOf(address(this)));
        uint256 quoteLeft = IERC20(m.quote).balanceOf(address(this));
        if (quoteLeft != 0) IERC20(m.quote).safeTransfer(msg.sender, quoteLeft);
    }

    /**
     * @dev The most liquidity the two seed amounts can fund at the pool's starting price, as
     *      Uniswap's `LiquidityAmounts` computes it, less one part in a million.
     *
     *      The shave is there because the pool rounds what it charges up and this rounds what it
     *      asks for down, through different sequences of divisions, so the exact figure can come
     *      out a wei over one of the router's limits and revert the launch. Whatever the pool does
     *      not take is returned to the creator, so understating costs them nothing but dust.
     */
    function _liquidityFor(uint160 sqrtP, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1)
        private pure returns (uint128)
    {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        uint256 l;
        if (sqrtP <= sqrtA) {
            l = _liquidity0(sqrtA, sqrtB, amount0);
        } else if (sqrtP < sqrtB) {
            uint256 l0 = _liquidity0(sqrtP, sqrtB, amount0);
            uint256 l1 = _liquidity1(sqrtA, sqrtP, amount1);
            l = l0 < l1 ? l0 : l1;
        } else {
            l = _liquidity1(sqrtA, sqrtB, amount1);
        }
        l -= l / 1e6;
        l = l == 0 ? 0 : l - 1;
        return l > type(uint128).max ? type(uint128).max : uint128(l);
    }

    /// @dev The same price seen from the other currency: 1/p, which in sqrtPriceX96 is 2^192 / p.
    function _invert(uint160 sqrtPrice) private pure returns (uint160) {
        if (sqrtPrice == 0) revert InvalidConfiguration();
        uint256 inverted = (uint256(1) << 192) / sqrtPrice;
        if (inverted > type(uint160).max) revert InvalidConfiguration();
        return uint160(inverted);
    }

    function _liquidity0(uint160 a, uint160 b, uint256 amount0) private pure returns (uint256) {
        return FullMath.mulDiv(amount0, FullMath.mulDiv(a, b, FixedPoint96.Q96), b - a);
    }

    function _liquidity1(uint160 a, uint160 b, uint256 amount1) private pure returns (uint256) {
        return FullMath.mulDiv(amount1, FixedPoint96.Q96, b - a);
    }
}
