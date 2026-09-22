// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MonthlyMandateFixture} from "./MonthlyMandate.t.sol";
import {TestAsset} from "./IndexLifecycle.t.sol";
import {IndexMarketRegistry} from "../src/IndexMarketRegistry.sol";
import {ShareFeeHook} from "../src/ShareFeeHook.sol";
import {ManagedIndexFactory} from "../src/ManagedIndexFactory.sol";
import {ShareMarketRouter} from "../src/ShareMarketRouter.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract MarketRegistryTest is MonthlyMandateFixture {
    IndexMarketRegistry internal registry;
    IPoolManager internal pm;
    TestAsset internal quote;

    function setUp() public override {
        super.setUp();
        pm = IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        quote = new TestAsset("Quote", 6);
        address[] memory quotes = new address[](1);
        quotes[0] = address(quote);
        // Hookless here: this suite asserts the registry itself, not the fee.
        registry = new IndexMarketRegistry(managedFactory, pm, ShareFeeHook(address(0)), quotes);
    }

    function testOnlyCreatorCanRegisterAdmittedQuote() public {
        vm.prank(alice);
        vm.expectRevert(IndexMarketRegistry.InvalidMarket.selector);
        registry.register(address(index), address(quote), uint160(1 << 96));
        vm.expectRevert(IndexMarketRegistry.InvalidMarket.selector);
        registry.register(address(index), address(a), uint160(1 << 96));
        PoolKey memory key = registry.register(address(index), address(quote), uint160(1 << 96));
        assertEq(address(key.hooks), address(0));
        // 15 bps to liquidity providers; the hook takes its own 15 on top when present.
        assertEq(key.fee, 1_500);
        vm.expectRevert(IndexMarketRegistry.InvalidMarket.selector);
        registry.register(address(index), address(quote), uint160(1 << 96));
    }

    function testPreinitializedPriceCannotBeSilentlyAdopted() public {
        bool shareIs0 = address(index) < address(quote);
        PoolKey memory key = PoolKey(Currency.wrap(shareIs0 ? address(index) : address(quote)),
            Currency.wrap(shareIs0 ? address(quote) : address(index)), 1_500, 60, IHooks(address(0)));
        pm.initialize(key, uint160(2 << 96));
        vm.expectRevert();
        registry.register(address(index), address(quote), uint160(1 << 96));
        assertEq(Currency.unwrap(registry.marketFor(address(index)).currency0), address(0));
    }

    function initializeExisting(uint160 price) internal returns (PoolKey memory key) {
        bool shareIs0 = address(index) < address(quote);
        key = PoolKey(Currency.wrap(shareIs0 ? address(index) : address(quote)),
            Currency.wrap(shareIs0 ? address(quote) : address(index)), 1_500, 60, IHooks(address(0)));
        vm.prank(alice);
        pm.initialize(key, price);
    }

    function testCreatorCanExplicitlyAdoptReviewedPoolWithoutMovingBacking() public {
        uint160 price = uint160(2 << 96);
        PoolKey memory expected = initializeExisting(price);
        assertEq(registry.existingPrice(address(index), address(quote)), price);
        (address[] memory assets, uint256[] memory beforeAmounts) = index.totalAssets();
        uint256 supply = index.totalSupply();
        PoolKey memory adopted = registry.adoptExisting(address(index), address(quote), price, block.timestamp + 300);
        assertEq(abi.encode(adopted), abi.encode(expected));
        assertEq(abi.encode(registry.marketFor(address(index))), abi.encode(expected));
        (address[] memory afterAssets, uint256[] memory afterAmounts) = index.totalAssets();
        assertEq(abi.encode(afterAssets, afterAmounts), abi.encode(assets, beforeAmounts));
        assertEq(index.totalSupply(), supply);
        vm.expectRevert(IndexMarketRegistry.InvalidMarket.selector);
        registry.adoptExisting(address(index), address(quote), price, block.timestamp + 300);
    }

    function testAdoptionRejectsOtherWalletAndUnapprovedQuote() public {
        initializeExisting(uint160(1 << 96));
        vm.prank(alice);
        vm.expectRevert(IndexMarketRegistry.InvalidMarket.selector);
        registry.adoptExisting(address(index), address(quote), uint160(1 << 96), block.timestamp + 300);
        vm.expectRevert(IndexMarketRegistry.InvalidMarket.selector);
        registry.adoptExisting(address(index), address(a), uint160(1 << 96), block.timestamp + 300);
    }

    function testAdoptionRejectsMissingPoolOrDifferentReviewedPrice() public {
        assertEq(registry.existingPrice(address(index), address(quote)), 0);
        vm.expectRevert(IndexMarketRegistry.MarketPriceChanged.selector);
        registry.adoptExisting(address(index), address(quote), 0, block.timestamp + 300);
        vm.expectRevert(IndexMarketRegistry.MarketPriceChanged.selector);
        registry.adoptExisting(address(index), address(quote), uint160(1 << 96), block.timestamp + 300);
        initializeExisting(uint160(2 << 96));
        vm.expectRevert(IndexMarketRegistry.MarketPriceChanged.selector);
        registry.adoptExisting(address(index), address(quote), uint160(1 << 96), block.timestamp + 300);
        assertEq(Currency.unwrap(registry.marketFor(address(index)).currency0), address(0));
    }

    function testAdoptionRejectsExpiredOrLongLivedReview() public {
        initializeExisting(uint160(1 << 96));
        vm.warp(1000);
        vm.expectRevert(IndexMarketRegistry.MarketReviewExpired.selector);
        registry.adoptExisting(address(index), address(quote), uint160(1 << 96), 999);
        vm.expectRevert(IndexMarketRegistry.MarketReviewExpired.selector);
        registry.adoptExisting(address(index), address(quote), uint160(1 << 96), 1301);
        assertEq(Currency.unwrap(registry.marketFor(address(index)).currency0), address(0));
    }

    function testSwapAfterReviewRequiresFreshAdoptionAndPreservesLpOwnership() public {
        PoolKey memory key = initializeExisting(uint160(1 << 96));
        ShareMarketRouter router = new ShareMarketRouter(pm, address(0), address(0));
        quote.mint(address(this), 101e18);
        index.approve(address(router), 101e18);
        quote.approve(address(router), 101e18);
        router.modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, 100e18, bytes32(0)),
            101e18, 101e18, block.timestamp);
        uint160 reviewed = registry.existingPrice(address(index), address(quote));
        bool direction = address(quote) < address(index);
        quote.mint(alice, 1e18);
        vm.startPrank(alice);
        quote.approve(address(router), 1e18);
        router.swapExactInput(key, direction, 1e18, 1,
            direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1, block.timestamp);
        vm.stopPrank();
        vm.expectRevert(IndexMarketRegistry.MarketPriceChanged.selector);
        registry.adoptExisting(address(index), address(quote), reviewed, block.timestamp + 300);
        assertEq(Currency.unwrap(registry.marketFor(address(index)).currency0), address(0));
        uint160 fresh = registry.existingPrice(address(index), address(quote));
        assertTrue(fresh != reviewed);
        registry.adoptExisting(address(index), address(quote), fresh, block.timestamp + 300);
        assertEq(router.positionLiquidity(key, address(this), -887220, 887220, bytes32(0)), 100e18);
        assertEq(router.positionLiquidity(key, alice, -887220, 887220, bytes32(0)), 0);
        router.modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, -100e18, bytes32(0)),
            1, 1, block.timestamp);
        assertEq(router.positionLiquidity(key, address(this), -887220, 887220, bytes32(0)), 0);
    }

    function testMetadataOwnerAndUnmanagedBypass() public {
        vm.prank(alice);
        vm.expectRevert();
        managedFactory.setMetadata(address(index), "ipfs://attacker");
        managedFactory.setMetadata(address(index), "ipfs://methodology");
        assertEq(managedFactory.metadataURI(address(index)), "ipfs://methodology");
        vm.expectRevert();
        managedFactory.create(seed());
    }

    /// @dev The whole point of registering in the same transaction: the hook refuses a swap on a
    ///      pool it does not know, so an unbound market is an untradeable one.
    function testRegistryBindsTheMarketToTheFeeHook() public {
        address hookAddr = address(uint160(0x4444000000000000000000000000000000000044));
        deployCodeTo("out/ShareFeeHook.sol/ShareFeeHook.json",
            abi.encode(pm, address(this), address(0xBEEF)), hookAddr);
        address[] memory quotes_ = new address[](1);
        quotes_[0] = address(quote);
        IndexMarketRegistry hooked =
            new IndexMarketRegistry(managedFactory, pm, ShareFeeHook(hookAddr), quotes_);

        // The registry must be the registrar for this to work, so a registry that is not one
        // cannot create a market at all rather than creating an unbound one.
        vm.expectRevert(ShareFeeHook.NotRegistrar.selector);
        hooked.register(address(index), address(quote), uint160(1 << 96));
    }

    /* ----------------------------------------------------- a launch must produce a market */

    function testMarketMustBeWiredBeforeASeededLaunch() public {
        // The factory cannot open a market it has not been told about, and it says so rather
        // than silently creating an index nobody can buy.
        assertFalse(managedFactory.marketWired(), "not wired in this fixture");
    }

    function testOnlyTheDeployerWiresTheMarketAndOnlyOnce() public {
        ShareMarketRouter router = new ShareMarketRouter(pm, address(0), address(managedFactory));
        vm.prank(alice);
        vm.expectRevert(ManagedIndexFactory.MarketAlreadyWired.selector);
        managedFactory.wireMarket(registry, router);

        managedFactory.wireMarket(registry, router);
        assertTrue(managedFactory.marketWired());
        assertEq(address(managedFactory.marketRegistry()), address(registry));

        vm.expectRevert(ManagedIndexFactory.MarketAlreadyWired.selector);
        managedFactory.wireMarket(registry, router);
    }

    function testOnlyTheLauncherMayOpenAPositionForSomeoneElse() public {
        // The router lends its salt to exactly one address. Anyone else naming an owner is
        // refused, which is what keeps `modifyLiquidityFor` from being a way to move positions.
        ShareMarketRouter router = new ShareMarketRouter(pm, address(0), address(managedFactory));
        // Read the key BEFORE expectRevert: a call in the argument list consumes the cheatcode.
        PoolKey memory k = registry.marketFor(address(index));
        vm.prank(alice);
        vm.expectRevert(ShareMarketRouter.InvalidMarket.selector);
        router.modifyLiquidityFor(alice, k,
            ModifyLiquidityParams(-887220, 887220, 1e18, bytes32(0)), 1e18, 1e18, block.timestamp);
    }

    function testTheLauncherCannotRemoveLiquidityItOpened() public {
        // It may only add. Withdrawal still derives its salt from msg.sender, so a position the
        // factory opened for a creator can only ever be taken out by that creator.
        ShareMarketRouter router = new ShareMarketRouter(pm, address(0), address(this));
        PoolKey memory k = registry.marketFor(address(index));
        vm.expectRevert(ShareMarketRouter.InvalidAmount.selector);
        router.modifyLiquidityFor(alice, k,
            ModifyLiquidityParams(-887220, 887220, -1e18, bytes32(0)), 0, 0, block.timestamp);
    }
}
