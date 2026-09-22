// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Folio} from "folio/Folio.sol";
import {IFolio} from "folio/interfaces/IFolio.sol";
import {IndexFactoryBase} from "./IndexFactoryBase.sol";
import {MonthlyMandate} from "./MonthlyMandate.sol";
import {IndexMarketRegistry} from "./IndexMarketRegistry.sol";
import {ShareMarketRouter} from "./ShareMarketRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Atomic seed and fixed monthly mandate deployment. Release candidate, not audited.
/// @dev No transaction leaves the creator or factory with a bypass role on a managed index.
contract ManagedIndexFactory is IndexFactoryBase {
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
    bool public marketWired;

    mapping(address => address) public mandateOf;
    mapping(address => address) public creatorOf;
    mapping(address => bool) public assetAllowed;
    mapping(address => string) public metadataURI;
    address public admissionOwner;
    bool public admissionFrozen;
    uint256 public admittedAssetCount;
    bytes32 public admissionCommitment;
    uint256 public constant MAX_ADMISSION_BATCH = 128;
    error AdmissionUnauthorized();
    error AdmissionNotFrozen();
    error MarketAlreadyWired();
    error MarketNotWired();
    error SeedTooSmall();
    event AssetAdmitted(address indexed token, uint256 count, bytes32 commitment);
    event AdmissionFrozen(uint256 count, bytes32 commitment);
    event MetadataUpdated(address indexed index, string uri);
    event ManagedIndexCreated(address indexed index, address indexed mandate, address indexed creator,
        bytes32 methodologyHash);

    constructor(address implementation_, address feeRegistry_, address[] memory supportedAssets)
        IndexFactoryBase(implementation_, feeRegistry_)
    {
        deployer = msg.sender;
        // Small catalogs retain atomic construction. Empty input selects bounded setup,
        // with index creation disabled until the reviewed count/commitment is frozen.
        if (supportedAssets.length == 0) {
            admissionOwner = msg.sender;
        } else {
            _admit(supportedAssets);
            admissionFrozen = true;
            emit AdmissionFrozen(admittedAssetCount, admissionCommitment);
        }
    }

    function admitAssets(address[] calldata assets) external {
        if (msg.sender != admissionOwner || admissionFrozen) revert AdmissionUnauthorized();
        _admit(assets);
    }

    function freezeAdmission(uint256 expectedCount, bytes32 expectedCommitment) external {
        if (msg.sender != admissionOwner || admissionFrozen) revert AdmissionUnauthorized();
        if (expectedCount == 0 || expectedCount != admittedAssetCount || expectedCommitment != admissionCommitment) revert InvalidConfiguration();
        admissionFrozen = true;
        admissionOwner = address(0);
        emit AdmissionFrozen(admittedAssetCount, admissionCommitment);
    }

    function _admit(address[] memory assets) private {
        if (assets.length == 0 || assets.length > MAX_ADMISSION_BATCH) revert InvalidConfiguration();
        for (uint256 i; i < assets.length; ++i) {
            address token = assets[i];
            if (token.code.length == 0 || assetAllowed[token]) revert InvalidConfiguration();
            assetAllowed[token] = true;
            admittedAssetCount++;
            admissionCommitment = keccak256(abi.encodePacked(admissionCommitment, token));
            emit AssetAdmitted(token, admittedAssetCount, admissionCommitment);
        }
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
        if (!admissionFrozen) revert AdmissionNotFrozen();
        if (bytes(seed.name).length == 0 || bytes(seed.name).length > 64
            || bytes(seed.symbol).length == 0 || bytes(seed.symbol).length > 16) revert InvalidConfiguration();
        for (uint256 i; i < seed.assets.length; ++i) if (!assetAllowed[seed.assets[i]]) revert InvalidConfiguration();
        index = _createFor(seed, shareRecipient, msg.sender);
        index.setMaxAuctionLength(cfg.auctionLength);
        index.setMandate("Fixed-universe monthly mandate; independent reviewer approves prices; see mandate registry.");
        mandate = new MonthlyMandate(index, cfg, rules);
        index.grantRole(bytes32(0), address(mandate));
        index.grantRole(keccak256("REBALANCE_MANAGER"), address(mandate));
        index.grantRole(keccak256("AUCTION_LAUNCHER"), address(mandate));
        index.renounceRole(bytes32(0), address(this));
        mandate.activate();
        mandateOf[address(index)] = address(mandate);
        creatorOf[address(index)] = msg.sender;
        emit ManagedIndexCreated(address(index), address(mandate), msg.sender, cfg.methodologyHash);
    }

    function setMetadata(address index, string calldata uri) external {
        if (creatorOf[index] != msg.sender || bytes(uri).length > 2048) revert InvalidConfiguration();
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
     * @param  initialPrice  sqrtPriceX96 for the new pool, which sets where trading starts
     * @param  quoteSeed     how much quote to put in the pool alongside the shares
     * @param  shareSeed     how many of the freshly minted shares to put in beside it
     * @param  tickLower     position bounds; full range is the sane default and what the UI sends
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
        int24 tickUpper
    ) external nonReentrant returns (Folio index, MonthlyMandate mandate, PoolKey memory key) {
        if (!marketWired) revert MarketNotWired();
        if (quoteSeed == 0 || shareSeed == 0 || shareSeed >= seed.initialShares) revert SeedTooSmall();

        (index, mandate) = _createManaged(seed, cfg, rules, address(this));
        key = marketRegistry.register(address(index), quote, initialPrice);

        /*
         * The shares are here, not with the creator: `_createManaged` mints to this contract so
         * the seed can be placed without a round trip. Everything not seeded goes straight on.
         */
        IERC20(quote).safeTransferFrom(msg.sender, address(this), quoteSeed);
        IERC20(quote).forceApprove(address(marketRouter), quoteSeed);
        IERC20(address(index)).forceApprove(address(marketRouter), shareSeed);

        marketRouter.modifyLiquidityFor(
            msg.sender, key,
            ModifyLiquidityParams(tickLower, tickUpper, int256(_liquidityFor(shareSeed)), bytes32(0)),
            shareSeed, quoteSeed, block.timestamp
        );

        // Whatever the pool did not take, and every share not seeded, belongs to the creator.
        IERC20(address(index)).safeTransfer(msg.sender, IERC20(address(index)).balanceOf(address(this)));
        uint256 quoteLeft = IERC20(quote).balanceOf(address(this));
        if (quoteLeft != 0) IERC20(quote).safeTransfer(msg.sender, quoteLeft);
    }

    /// @dev A deliberately conservative liquidity amount for the seed. The router's `limit0` and
    ///      `limit1` are the real bound on what is spent, so understating this leaves quote with
    ///      the creator rather than reverting the launch.
    function _liquidityFor(uint256 shareSeed) private pure returns (uint256) {
        return shareSeed;
    }
}
