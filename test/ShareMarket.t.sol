// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IndexFixture, TestAsset} from "./IndexLifecycle.t.sol";
import {ShareMarketRouter} from "../src/ShareMarketRouter.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract ShareMarketTest is IndexFixture {
    ShareMarketRouter internal router;
    IPoolManager internal pm;
    TestAsset internal quote;
    PoolKey internal key;
    bool internal shareIs0;

    function setUp() public virtual override {
        super.setUp();
        pm = poolManagerFixture();
        router = new ShareMarketRouter(pm, routerFeeHook(), routerLauncher());
        quote = new TestAsset("Quote", 18);
        quote.mint(address(this), 10_000e18);
        quote.mint(alice, 100e18);
        shareIs0 = address(index) < address(quote);
        key = PoolKey(
            Currency.wrap(shareIs0 ? address(index) : address(quote)),
            Currency.wrap(shareIs0 ? address(quote) : address(index)), 3000, 60, IHooks(address(0))
        );
        pm.initialize(key, uint160(1 << 96));
        index.approve(address(router), type(uint256).max);
        quote.approve(address(router), type(uint256).max);
        router.modifyLiquidity(key, position(100e18), 101e18, 101e18, block.timestamp);
        vm.prank(alice);
        quote.approve(address(router), type(uint256).max);
    }

    /// @dev Hookless by default, so every existing test keeps asserting the original guarantee.
    ///      `ShareFeeHookTest` overrides it with the hook it is testing.
    function routerFeeHook() internal view virtual returns (address) {
        return address(0);
    }

    /// @dev Only a launcher may open a position for someone else. None by default.
    function routerLauncher() internal view virtual returns (address) {
        return address(0);
    }

    function poolManagerFixture() internal virtual returns (IPoolManager) {
        return IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
    }

    function position(int256 liquidity) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams(-887220, 887220, liquidity, bytes32(0));
    }

    function buy(uint256 amount) internal returns (BalanceDelta) {
        bool direction = !shareIs0;
        vm.prank(alice);
        return router.swapExactInput(key, direction, amount, 1, limit(direction), block.timestamp);
    }

    function limit(bool direction) internal pure returns (uint160) {
        return direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function testBuySellEmitsNativeSwapsAndDoesNotTouchBasket() public {
        uint256 assetA = a.balanceOf(address(index));
        uint256 assetB = b.balanceOf(address(index));
        uint256 supply = index.totalSupply();
        vm.recordLogs();
        buy(10e18);
        uint256 bought = index.balanceOf(alice);
        assertGt(bought, 0);
        vm.startPrank(alice);
        index.approve(address(router), bought);
        router.swapExactInput(key, shareIs0, bought, 1, limit(shareIs0), block.timestamp);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        uint256 swaps;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pm) && logs[i].topics[0] == swapTopic) {
                (int128 amount0, int128 amount1,,,,) = abi.decode(logs[i].data, (int128,int128,uint160,uint128,int24,uint24));
                assertTrue(amount0 != 0 && amount1 != 0);
                swaps++;
            }
        }
        assertEq(swaps, 2);
        assertEq(a.balanceOf(address(index)), assetA);
        assertEq(b.balanceOf(address(index)), assetB);
        assertEq(index.totalSupply(), supply);
        assertEq(index.balanceOf(alice), 0);
        assertLt(quote.balanceOf(alice), 100e18);
        assertEq(index.balanceOf(address(router)), 0);
        assertEq(quote.balanceOf(address(router)), 0);
    }

    function testLpCanWithdrawAfterTrading() public {
        buy(10e18);
        uint256 beforeShares = index.balanceOf(address(this));
        uint256 beforeQuote = quote.balanceOf(address(this));
        router.modifyLiquidity(key, position(-100e18), 1, 1, block.timestamp);
        assertGt(index.balanceOf(address(this)), beforeShares);
        assertGt(quote.balanceOf(address(this)), beforeQuote);
    }

    function testDifferentWalletCannotRemoveSponsorsLiquidity() public {
        vm.prank(alice);
        vm.expectRevert();
        router.modifyLiquidity(key, position(-100e18), 0, 0, block.timestamp);
    }

    function testSlippageFailureRevertsAssetMovement() public {
        vm.prank(alice);
        vm.expectRevert(ShareMarketRouter.Slippage.selector);
        router.swapExactInput(key, !shareIs0, 10e18, 100e18, limit(!shareIs0), block.timestamp);
        assertEq(quote.balanceOf(alice), 100e18);
        assertEq(index.balanceOf(alice), 0);
    }

    function testExpiredTradeAndDirectCallbackRejected() public {
        vm.warp(100);
        vm.expectRevert(ShareMarketRouter.Expired.selector);
        router.swapExactInput(key, true, 1, 0, limit(true), 99);
        vm.expectRevert(ShareMarketRouter.UnauthorizedCallback.selector);
        router.unlockCallback("");
    }

    function testQuoteWithoutFundsMatchesExecutionAndDoesNotMovePrice() public {
        (uint160 beforePrice,,,,) = router.marketState(key);
        vm.prank(address(0x1234));
        BalanceDelta quoted = router.quoteExactInput(key, !shareIs0, 10e18, limit(!shareIs0));
        (uint160 afterPrice,,,,) = router.marketState(key);
        assertEq(beforePrice, afterPrice);
        assertEq(BalanceDelta.unwrap(buy(10e18)), BalanceDelta.unwrap(quoted));
    }

    function testLiquidityFlowAttributesOwnerAndFeesWithoutDoubleCounting() public {
        buy(10e18);
        uint256 beforeShares = index.balanceOf(address(this));
        uint256 beforeQuote = quote.balanceOf(address(this));
        vm.recordLogs();
        BalanceDelta collected = router.modifyLiquidity(key, position(0), 0, 0, block.timestamp);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("LiquidityChanged(address,bytes32,bytes32,address,address,int24,int24,int256,int256,int256)");
        uint256 found;
        for (uint256 i; i < logs.length; ++i) if (logs[i].emitter == address(router) && logs[i].topics[0] == topic) {
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(this));
            assertEq(logs[i].topics[2], keccak256(abi.encode(key)));
            assertEq(logs[i].topics[3], router.positionSalt(address(this), bytes32(0)));
            (,,,,int256 change,int256 net,int256 fees) = abi.decode(logs[i].data,(address,address,int24,int24,int256,int256,int256));
            assertEq(change, 0);
            assertEq(net, BalanceDelta.unwrap(collected));
            assertEq(net, fees); // A pure collection pays precisely the settled fees once.
            assertTrue(fees != 0);
            ++found;
        }
        assertEq(found,1);
        assertEq(index.balanceOf(address(this))-beforeShares, uint256(uint128(shareIs0 ? collected.amount0() : collected.amount1())));
        assertEq(quote.balanceOf(address(this))-beforeQuote, uint256(uint128(shareIs0 ? collected.amount1() : collected.amount0())));
    }
}
