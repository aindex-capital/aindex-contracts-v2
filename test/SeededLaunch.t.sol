// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Folio} from "folio/Folio.sol";
import {IFolio} from "folio/interfaces/IFolio.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {MonthlyMandate} from "../src/MonthlyMandate.sol";
import {FixedFeeRegistry, MintSplit} from "../src/FixedFeeRegistry.sol";
import {IndexMarketRegistry} from "../src/IndexMarketRegistry.sol";
import {ShareMarketRouter} from "../src/ShareMarketRouter.sol";
import {ShareFeeHook} from "../src/ShareFeeHook.sol";
import {TestAsset} from "./IndexLifecycle.t.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/**
 * The production launch path, end to end: `createManagedWithMarket` through the fee hook, the
 * router and the registry, then trading, fees, the holder cut and the creator's withdrawal.
 *
 * Abstract over the PoolManager and the assets so the same assertions run against a local
 * PoolManager here and against the live one, with real WETH and USDG, in `test/fork/`.
 */
abstract contract SeededLaunchBase is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal pm;
    IndexFactory internal factory;
    IndexMarketRegistry internal registry;
    ShareMarketRouter internal router;
    address internal hook = address(uint160(0x4444000000000000000000000000000000000044));

    address internal creator = address(0xC0FFEE);
    address internal trader = address(0xA11CE);
    address internal protocol = address(0xFEE5);

    address[] internal assets;
    uint256[] internal amounts;
    address internal quote;

    uint256 internal constant INITIAL_SHARES = 100e18;
    uint256 internal constant SHARE_SEED = 50e18;
    int24 internal constant FULL_LOWER = -887220;
    int24 internal constant FULL_UPPER = 887220;

    function poolManagerFixture() internal virtual returns (IPoolManager);
    /// @dev Sets `assets`, `amounts` and `quote`. `quote` must have 6 decimals.
    function assetFixture() internal virtual;
    function fund(address token, address to, uint256 amount) internal virtual;

    function setUp() public virtual {
        pm = poolManagerFixture();
        assetFixture();
        factory = new IndexFactory(address(new Folio()),
            address(new FixedFeeRegistry(protocol, MintSplit.PROTOCOL_PORTION_FOR_35BPS, 0)));

        // The hook names the registry as its registrar and the registry reads the hook in its
        // constructor, so the hook goes first, at a flag-bearing address, told where the
        // registry will land.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        deployCodeTo("out/ShareFeeHook.sol/ShareFeeHook.json", abi.encode(pm, predicted, protocol), hook);
        address[] memory quotes = new address[](1);
        quotes[0] = quote;
        registry = new IndexMarketRegistry(factory, pm, ShareFeeHook(hook), quotes);
        assertEq(address(registry), predicted, "registry landed where the hook expects");
        router = new ShareMarketRouter(pm, hook, address(factory));
        factory.wireMarket(registry, router);
    }

    /* ------------------------------------------------------------------------ helpers */

    /// sqrtPriceX96 of `quoteRawPerShare` quote units per whole share, share as currency0.
    function sharePrice(uint256 quoteRawPerShare) internal pure returns (uint160) {
        return uint160(Math.sqrt(FullMath.mulDiv(quoteRawPerShare, uint256(1) << 192, 1e18)));
    }

    /// Quote units per whole share, read back off the pool whichever way it sorted.
    function poolQuotePerShare(Folio index, PoolKey memory key) internal view returns (uint256) {
        (uint160 sqrtP,,,) = pm.getSlot0(key.toId());
        uint256 p = FullMath.mulDiv(sqrtP, sqrtP, uint256(1) << 96); // token1/token0, X96
        return Currency.unwrap(key.currency0) == address(index)
            ? FullMath.mulDiv(p, 1e18, uint256(1) << 96)
            : FullMath.mulDiv(uint256(1) << 96, 1e18, p);
    }

    function launch(uint256 quoteRawPerShare) internal returns (Folio index, PoolKey memory key) {
        uint256 quoteSeed = quoteRawPerShare * SHARE_SEED / 1e18;
        for (uint256 i; i < assets.length; ++i) fund(assets[i], creator, amounts[i]);
        fund(quote, creator, quoteSeed);
        MonthlyMandate.TokenRule[] memory rules = new MonthlyMandate.TokenRule[](assets.length);
        for (uint256 i; i < assets.length; ++i) rules[i] = MonthlyMandate.TokenRule(assets[i], 0, 1e36, amounts[i]);
        vm.startPrank(creator);
        for (uint256 i; i < assets.length; ++i) IERC20(assets[i]).approve(address(factory), amounts[i]);
        // Add to, not replace, the allowance: the quote can also be a basket asset.
        IERC20(quote).approve(address(factory), IERC20(quote).allowance(creator, address(factory)) + quoteSeed);
        (index,, key) = factory.createManagedWithMarket(
            IFolio.FolioBasicDetails("Seeded launch", "SEED", assets, amounts, INITIAL_SHARES),
            MonthlyMandate.Config(creator, address(0xB0B), address(0xCAFE), 1 hours, 30 days, 300, 100,
                keccak256("seeded launch")),
            rules, quote, sharePrice(quoteRawPerShare), quoteSeed, SHARE_SEED, FULL_LOWER, FULL_UPPER, "ipfs://profile");
        vm.stopPrank();
    }

    function limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function buy(Folio index, PoolKey memory key, uint256 quoteIn) internal returns (uint256 shares) {
        bool zeroForOne = Currency.unwrap(key.currency0) == quote;
        fund(quote, trader, quoteIn);
        uint256 before = index.balanceOf(trader);
        vm.startPrank(trader);
        IERC20(quote).approve(address(router), quoteIn);
        router.swapExactInput(key, zeroForOne, quoteIn, 1, limit(zeroForOne), block.timestamp);
        vm.stopPrank();
        shares = index.balanceOf(trader) - before;
    }

    function sell(Folio index, PoolKey memory key, uint256 sharesIn) internal returns (uint256 quoteOut) {
        bool zeroForOne = Currency.unwrap(key.currency0) == address(index);
        uint256 before = IERC20(quote).balanceOf(trader);
        vm.startPrank(trader);
        index.approve(address(router), sharesIn);
        router.swapExactInput(key, zeroForOne, sharesIn, 1, limit(zeroForOne), block.timestamp);
        vm.stopPrank();
        quoteOut = IERC20(quote).balanceOf(trader) - before;
    }

    /* -------------------------------------------------------------------------- tests */

    function testLaunchOpensATradeableMarketInOneTransaction() public {
        (Folio index, PoolKey memory key) = launch(50e6);

        assertEq(abi.encode(registry.marketFor(address(index))), abi.encode(key), "registered");
        assertEq(address(key.hooks), hook, "carries the fee hook");
        (,,bool registered) = ShareFeeHook(hook).markets(key.toId());
        assertTrue(registered, "bound to the hook in the same transaction");
        assertEq(factory.creatorOf(address(index)), creator);
        assertEq(factory.metadataURI(address(index)), "ipfs://profile", "the profile is set in the launch itself");

        assertGt(pm.getLiquidity(key.toId()), 0, "the pool has depth");
        assertGt(router.positionLiquidity(key, creator, FULL_LOWER, FULL_UPPER, bytes32(0)), 0, "creator owns it");
        assertEq(router.positionLiquidity(key, address(factory), FULL_LOWER, FULL_UPPER, bytes32(0)), 0);

        // Nothing is left behind in the factory, and no allowance survives the launch.
        assertEq(index.balanceOf(address(factory)), 0);
        assertEq(IERC20(quote).balanceOf(address(factory)), 0);
        assertEq(IERC20(quote).allowance(address(factory), address(router)), 0);
        assertEq(index.allowance(address(factory), address(router)), 0);
        // Every share is in the pool or with the creator. Liquidity is shaved by a part per
        // million so rounding cannot trip the router's limits; that dust is returned too.
        uint256 pooled = index.balanceOf(address(pm));
        assertEq(index.balanceOf(creator) + pooled, INITIAL_SHARES, "unseeded shares go to the creator");
        assertApproxEqRel(pooled, SHARE_SEED, 2e12, "the seed is placed, less the shave");

        uint256 price = poolQuotePerShare(index, key);
        assertApproxEqRel(price, 50e6, 1e12, "starts at the price asked for, in share terms");
    }

    /// @dev Which side the share sorts to depends on a clone address nobody chooses. Launch until
    ///      both orientations have been seen and check the price reads the same either way.
    function testPriceIsTheSameWhicheverWayTheShareSorts() public {
        bool sawFirst;
        bool sawSecond;
        for (uint256 i; i < 16 && !(sawFirst && sawSecond); ++i) {
            (Folio index, PoolKey memory key) = launch(50e6);
            if (address(index) < quote) sawFirst = true;
            else sawSecond = true;
            assertApproxEqRel(poolQuotePerShare(index, key), 50e6, 1e12);
        }
        assertTrue(sawFirst && sawSecond, "both orientations exercised");
    }

    function testTradingBothWaysEmitsTruthfulSwapsAndPaysTheHook() public {
        (Folio index, PoolKey memory key) = launch(50e6);
        PoolId id = key.toId();

        vm.recordLogs();
        uint256 shares = buy(index, key, 100e6);
        assertGt(shares, 0);
        assertSwapCarriesAmounts(id);

        uint256 quoteOut = sell(index, key, shares);
        assertGt(quoteOut, 0);
        assertLt(quoteOut, 100e6, "a round trip costs the fees");
        assertSwapCarriesAmounts(id);

        ShareFeeHook h = ShareFeeHook(hook);
        Currency shareC = Currency.wrap(address(index));
        Currency quoteC = Currency.wrap(quote);
        // A buy pays its fee in shares and a sell in quote: the fee is taken from the output.
        assertGt(h.creatorFees(id, shareC), 0);
        assertGt(h.creatorFees(id, quoteC), 0);
        assertEq(h.creatorFees(id, quoteC), h.protocolFees(id, quoteC), "6 bps each");
        assertApproxEqAbs(h.holderFees(id, quoteC) * 2, h.creatorFees(id, quoteC), 2, "3 bps to holders");

        uint256 creatorQuote = IERC20(quote).balanceOf(creator);
        uint256 owed = h.creatorFees(id, quoteC);
        h.claim(key, quoteC);
        assertEq(IERC20(quote).balanceOf(creator) - creatorQuote, owed, "creator claims");
        assertGt(IERC20(quote).balanceOf(protocol), 0, "protocol claims");
    }

    function testTheHolderCutRaisesBackingPerShare() public {
        (Folio index, PoolKey memory key) = launch(50e6);
        buy(index, key, 1_000e6);
        uint256 supplyBefore = index.totalSupply();
        (, uint256[] memory before) = index.toAssets(1e18, Math.Rounding.Floor);

        ShareFeeHook(hook).payHolders(key, Currency.wrap(address(index)), 0);

        assertLt(index.totalSupply(), supplyBefore, "the cut is redeemed, so supply falls");
        (, uint256[] memory afterwards) = index.toAssets(1e18, Math.Rounding.Floor);
        for (uint256 i; i < before.length; ++i) assertGe(afterwards[i], before[i], "no holder loses backing");
        assertGt(afterwards[0], before[0], "and at least one asset per share rises");
    }

    function testOnlyTheCreatorCanWithdrawTheSeed() public {
        (, PoolKey memory key) = launch(50e6);
        uint128 liquidity = router.positionLiquidity(key, creator, FULL_LOWER, FULL_UPPER, bytes32(0));

        // Anyone else asking removes from their own, empty, position.
        vm.prank(trader);
        vm.expectRevert();
        router.modifyLiquidity(key, ModifyLiquidityParams(FULL_LOWER, FULL_UPPER, -int256(uint256(liquidity)),
            bytes32(0)), 0, 0, block.timestamp);

        uint256 quoteBefore = IERC20(quote).balanceOf(creator);
        vm.prank(creator);
        router.modifyLiquidity(key, ModifyLiquidityParams(FULL_LOWER, FULL_UPPER, -int256(uint256(liquidity)),
            bytes32(0)), 0, 0, block.timestamp);
        assertEq(router.positionLiquidity(key, creator, FULL_LOWER, FULL_UPPER, bytes32(0)), 0);
        assertGt(IERC20(quote).balanceOf(creator), quoteBefore, "the seed comes back to its owner");
    }

    function testTheSeedPositionIsAttributedToTheCreator() public {
        vm.recordLogs();
        launch(50e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256(
            "LiquidityChanged(address,bytes32,bytes32,address,address,int24,int24,int256,int256,int256)");
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router) || logs[i].topics[0] != topic) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), creator, "owner is the creator, not the factory");
            seen = true;
        }
        assertTrue(seen);
    }

    function testALaunchCannotSkipTheMarket() public {
        uint256 quoteSeed = 2_500e6;
        for (uint256 i; i < assets.length; ++i) fund(assets[i], creator, amounts[i]);
        MonthlyMandate.TokenRule[] memory rules = new MonthlyMandate.TokenRule[](assets.length);
        for (uint256 i; i < assets.length; ++i) rules[i] = MonthlyMandate.TokenRule(assets[i], 0, 1e36, amounts[i]);
        IFolio.FolioBasicDetails memory s = IFolio.FolioBasicDetails("No market", "NOM", assets, amounts, INITIAL_SHARES);
        MonthlyMandate.Config memory cfg = MonthlyMandate.Config(creator, address(0xB0B), address(0xCAFE),
            1 hours, 30 days, 300, 100, keccak256("x"));
        uint160 price = sharePrice(50e6);
        vm.startPrank(creator);
        vm.expectRevert(IndexFactory.SeedTooSmall.selector);
        factory.createManagedWithMarket(s, cfg, rules, quote, price, 0, SHARE_SEED, FULL_LOWER, FULL_UPPER, "ipfs://profile");
        vm.expectRevert(IndexFactory.SeedTooSmall.selector);
        factory.createManagedWithMarket(s, cfg, rules, quote, price, quoteSeed, 0, FULL_LOWER, FULL_UPPER, "");
        vm.expectRevert(IndexFactory.SeedTooSmall.selector);
        factory.createManagedWithMarket(s, cfg, rules, quote, price, quoteSeed, INITIAL_SHARES, FULL_LOWER, FULL_UPPER, "");
        vm.stopPrank();
    }

    function testALaunchRefusesAnOversizedProfileLink() public {
        for (uint256 i; i < assets.length; ++i) fund(assets[i], creator, amounts[i]);
        fund(quote, creator, 2_500e6);
        MonthlyMandate.TokenRule[] memory rules = new MonthlyMandate.TokenRule[](assets.length);
        for (uint256 i; i < assets.length; ++i) rules[i] = MonthlyMandate.TokenRule(assets[i], 0, 1e36, amounts[i]);
        bytes memory long = new bytes(2049);
        for (uint256 i; i < long.length; ++i) long[i] = "a";
        vm.startPrank(creator);
        for (uint256 i; i < assets.length; ++i) IERC20(assets[i]).approve(address(factory), amounts[i]);
        IERC20(quote).approve(address(factory), IERC20(quote).allowance(creator, address(factory)) + 2_500e6);
        vm.expectRevert();
        factory.createManagedWithMarket(IFolio.FolioBasicDetails("Long", "LNG", assets, amounts, INITIAL_SHARES),
            MonthlyMandate.Config(creator, address(0xB0B), address(0xCAFE), 1 hours, 30 days, 300, 100, keccak256("x")),
            rules, quote, sharePrice(50e6), 2_500e6, SHARE_SEED, FULL_LOWER, FULL_UPPER, string(long));
        vm.stopPrank();
    }

    function assertSwapCarriesAmounts(PoolId id) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pm) || logs[i].topics[0] != topic) continue;
            if (logs[i].topics[1] != PoolId.unwrap(id)) continue;
            (int128 a0, int128 a1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            // The failure the retired dealer hook had: a Swap with zero amounts that no indexer
            // or aggregator can price. The fee here is taken after the pool's own arithmetic.
            assertTrue(a0 != 0 && a1 != 0, "Swap reports real amounts");
            seen = true;
        }
        assertTrue(seen, "the pool emitted a Swap");
    }
}

contract SeededLaunchTest is SeededLaunchBase {
    function poolManagerFixture() internal override returns (IPoolManager) {
        return IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
    }

    function assetFixture() internal override {
        assets.push(address(new TestAsset("Asset A", 18)));
        assets.push(address(new TestAsset("Asset B", 6)));
        amounts.push(1e18);
        amounts.push(1_000e6);
        quote = address(new TestAsset("Quote", 6));
    }

    function fund(address token, address to, uint256 amount) internal override {
        TestAsset(token).mint(to, amount);
    }
}
