// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IndexFixture, TestAsset} from "./IndexLifecycle.t.sol";
import {LiquidityLocker, IMarketsLike} from "../src/LiquidityLocker.sol";
import {ShareFeeHook} from "../src/ShareFeeHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Stands in for `IndexMarketRegistry.marketFor`, the only call the locker makes to it.
contract MockMarkets is IMarketsLike {
    mapping(address => PoolKey) private keys;
    function set(address index, PoolKey memory key) external { keys[index] = key; }
    function marketFor(address index) external view returns (PoolKey memory) { return keys[index]; }
}

/// @notice The locker against a real PoolManager and the real fee hook, with a 6-decimal quote like USDG.
contract LiquidityLockerTest is IndexFixture {
    using StateLibrary for IPoolManager;

    address internal constant HOOK_ADDR = address(uint160(0x4444000000000000000000000000000000000044));
    int24 internal constant FULL_LOWER = -887220;
    int24 internal constant FULL_UPPER = 887220;
    uint16 internal constant OWNER_MOVE = 1_500;
    uint16 internal constant OPERATOR_MOVE = 300;
    uint32 internal constant COOLDOWN = 4 hours;
    uint16 internal constant MAX_LOSS = 50;

    IPoolManager internal pm;
    MockMarkets internal markets;
    TestAsset internal usd;
    PoolKey internal key;
    bool internal shareIs0;
    LiquidityLocker internal locker;
    address internal owner = address(0x0DD);
    address internal operatorKey = address(0x0B0);
    uint64 internal unlockAt;
    PoolModifyLiquidityTest internal lp;

    function setUp() public virtual override {
        super.setUp();
        vm.warp(1_790_000_000);
        pm = IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        deployCodeTo("out/ShareFeeHook.sol/ShareFeeHook.json", abi.encode(pm, address(this), address(0xBEEF)), HOOK_ADDR);
        usd = new TestAsset("USDG", 6);
        markets = new MockMarkets();
        key = keyFor(address(index));
        shareIs0 = address(index) < address(usd);
        ShareFeeHook(HOOK_ADDR).register(key, address(index), address(0xC0FFEE));
        markets.set(address(index), key);
        pm.initialize(key, sqrtPriceAt(address(index), 10.08e18));

        unlockAt = uint64(block.timestamp + 365 days);
        locker = newLocker(MAX_LOSS);
        index.transfer(owner, 100e18);
        usd.mint(owner, 10_000e6);
        vm.startPrank(owner);
        index.approve(address(locker), type(uint256).max);
        usd.approve(address(locker), type(uint256).max);
        vm.stopPrank();
        lp = new PoolModifyLiquidityTest(pm);
    }

    // ------------------------------------------------------------------ helpers

    function newLocker(uint16 maxLoss) internal returns (LiquidityLocker) {
        return new LiquidityLocker(pm, markets, owner, unlockAt, OWNER_MOVE, OPERATOR_MOVE, COOLDOWN, maxLoss);
    }

    function keyFor(address share) internal view returns (PoolKey memory) {
        bool s0 = share < address(usd);
        return PoolKey(Currency.wrap(s0 ? share : address(usd)), Currency.wrap(s0 ? address(usd) : share), 1_500, 60,
            IHooks(HOOK_ADDR));
    }

    /// @dev The pool price for a share worth `usd18` dollars against the 6-decimal quote.
    function sqrtPriceAt(address share, uint256 usd18) internal view returns (uint160) {
        bool s0 = share < address(usd);
        // price = currency1 per currency0 in raw units; one share is usd18 / 1e12 raw quote.
        uint256 q192 = uint256(1) << 192;
        uint256 priceX192 = s0 ? Math.mulDiv(q192, usd18, 1e30) : Math.mulDiv(q192, 1e30, usd18);
        return uint160(Math.sqrt(priceX192));
    }

    /// @dev Dollars a share at the pool's price, 18 decimals.
    function poolUsd(PoolKey memory k, address share) internal view returns (uint256) {
        (uint160 p,,,) = pm.getSlot0(k.toId());
        uint256 priceX192 = uint256(p) * uint256(p);
        bool s0 = Currency.unwrap(k.currency0) == share;
        return s0 ? Math.mulDiv(priceX192, 1e30, uint256(1) << 192) : Math.mulDiv(uint256(1) << 192, 1e30, priceX192);
    }

    function deposit(uint256 shares, uint256 quote, int24 lower, int24 upper) internal returns (uint128) {
        (uint256 a0, uint256 a1) = shareIs0 ? (shares, quote) : (quote, shares);
        vm.prank(owner);
        return locker.deposit(address(index), a0, a1, lower, upper, 0, block.timestamp);
    }

    function params(uint256 usd18, int24 lower, int24 upper) internal view returns (LiquidityLocker.Recenter memory r) {
        r.index = address(index);
        r.targetSqrtPriceX96 = sqrtPriceAt(address(index), usd18);
        r.tickLower = lower;
        r.tickUpper = upper;
        r.toleranceBps = 10;
        r.maxSwapIn = type(uint128).max;
        r.minLiquidity = 0;
        r.deadline = block.timestamp;
    }

    function around(uint256 usd18, uint256 bps) internal view returns (int24 lower, int24 upper) {
        int24 lo = TickMath.getTickAtSqrtPrice(sqrtPriceAt(address(index), usd18 * (10_000 - bps) / 10_000));
        int24 hi = TickMath.getTickAtSqrtPrice(sqrtPriceAt(address(index), usd18 * (10_000 + bps) / 10_000));
        if (lo > hi) (lo, hi) = (hi, lo);
        lower = (lo / 60) * 60;
        if (lo < 0 && lo % 60 != 0) lower -= 60;
        upper = (hi / 60 + 1) * 60;
    }

    function value(uint256 usd18) internal view returns (uint256) {
        (uint256 a0, uint256 a1) = locker.holdings(address(index));
        (uint256 s, uint256 q) = shareIs0 ? (a0, a1) : (a1, a0);
        return s * usd18 / 1e18 / 1e12 + q; // in raw quote units
    }

    function thirdPartyLiquidity(uint128 liquidity) internal {
        index.approve(address(lp), type(uint256).max);
        usd.mint(address(this), 1_000_000e6);
        usd.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(key, ModifyLiquidityParams(FULL_LOWER, FULL_UPPER, int256(uint256(liquidity)), bytes32(0)), "");
    }

    // ------------------------------------------------------------------ deposit

    function testDepositOpensAPositionTheLockerOwns() public {
        uint128 added = deposit(2.5e18, 25.2e6, FULL_LOWER, FULL_UPPER);
        assertGt(added, 0);
        assertEq(locker.positionLiquidity(address(index)), added);
        assertEq(pm.getLiquidity(key.toId()), added, "the locker is the pool's only liquidity");
        (uint128 held,,) = pm.getPositionInfo(key.toId(), address(locker), FULL_LOWER, FULL_UPPER, bytes32(0));
        assertEq(held, added, "held in the PoolManager under the locker's own address");
        assertApproxEqRel(value(10.08e18), 50.4e6, 1e15, "all of it is in the locker");
        (,,,, uint256 f0, uint256 f1) = locker.books(address(index));
        assertLt(shareIs0 ? f1 : f0, 1e3, "almost none of the quote is left over");
        assertLt(shareIs0 ? f0 : f1, 1e16, "almost none of the shares are left over");
    }

    function testDepositIsOwnerOnlyAndKeepsItsRange() public {
        vm.expectRevert(LiquidityLocker.NotOwner.selector);
        locker.deposit(address(index), 1, 1, FULL_LOWER, FULL_UPPER, 0, block.timestamp);
        deposit(2.5e18, 25.2e6, FULL_LOWER, FULL_UPPER);
        (uint256 a0, uint256 a1) = shareIs0 ? (uint256(1e18), uint256(10e6)) : (uint256(10e6), uint256(1e18));
        vm.prank(owner);
        vm.expectRevert(LiquidityLocker.RangeMismatch.selector);
        locker.deposit(address(index), a0, a1, -600, 600, 0, block.timestamp);
    }

    function testUnknownMarketRefused() public {
        vm.prank(owner);
        vm.expectRevert(LiquidityLocker.UnknownMarket.selector);
        locker.topUp(address(0x1234), 1, 1);
    }

    // ------------------------------------------------------------------ recenter

    function testRecenterMovesAnEmptyPoolToTargetAndKeepsEveryToken() public {
        uint128 before = deposit(2.5e18, 25.2e6, FULL_LOWER, FULL_UPPER);
        uint256 valueBefore = value(9.41e18);
        uint256 sharesHeld = index.balanceOf(address(locker)) + index.balanceOf(address(pm));
        vm.prank(owner);
        uint128 afterLiquidity = locker.recenter(params(9.41e18, FULL_LOWER, FULL_UPPER));

        assertApproxEqRel(poolUsd(key, address(index)), 9.41e18, 1e14, "the pool sits at backing");
        // Shares are the scarce side at the lower price: L falls by sqrt(9.41/10.08), about 3.4%.
        assertGe(uint256(afterLiquidity) * 10_000, uint256(before) * 9_600, "liquidity kept above the floor");
        assertGe(value(9.41e18) + 2, valueBefore, "nothing was spent: an empty pool moves for free");
        assertEq(index.balanceOf(address(locker)) + index.balanceOf(address(pm)), sharesHeld, "no share left the two");
        (,,,, uint256 f0, uint256 f1) = locker.books(address(index));
        assertGt(shareIs0 ? f1 : f0, 0, "the quote that no longer fits is float, not gone");
    }

    function testRecenterIntoANarrowRangeAroundBacking() public {
        uint128 full = deposit(2.5e18, 25.2e6, FULL_LOWER, FULL_UPPER);
        (int24 lower, int24 upper) = around(9.41e18, 200);
        vm.prank(owner);
        uint128 narrow = locker.recenter(params(9.41e18, lower, upper));
        assertGt(narrow, full * 40, "a 2% band is far deeper than full range with the same tokens");
        (int24 l, int24 u,,,,) = locker.books(address(index));
        assertEq(l, lower);
        assertEq(u, upper);
    }

    function testRecenterUsesTopUpFloat() public {
        deposit(2.5e18, 25.2e6, FULL_LOWER, FULL_UPPER);
        vm.startPrank(owner);
        locker.recenter(params(9.41e18, FULL_LOWER, FULL_UPPER));
        uint128 before = locker.positionLiquidity(address(index));
        (uint256 a0, uint256 a1) = shareIs0 ? (uint256(0.1e18), uint256(0)) : (uint256(0), uint256(0.1e18));
        locker.topUp(address(index), a0, a1);
        locker.recenter(params(9.41e18, FULL_LOWER, FULL_UPPER));
        vm.stopPrank();
        assertGt(locker.positionLiquidity(address(index)), before, "the topped-up shares went in");
    }

    function testFuzzRecenterWithinCapLandsOnTargetWithoutLoss(uint256 targetUsd) public {
        deposit(2.5e18, 25.2e6, FULL_LOWER, FULL_UPPER);
        targetUsd = bound(targetUsd, 8.8e18, 11.5e18);
        uint256 before = value(targetUsd);
        vm.prank(owner);
        locker.recenter(params(targetUsd, FULL_LOWER, FULL_UPPER));
        assertApproxEqRel(poolUsd(key, address(index)), targetUsd, 1e14);
        assertGe(value(targetUsd) + 2, before);
    }

    function testRecenterThatWouldLoseValueReverts() public {
        // Someone else's deep liquidity: now the swap to the target trades against it, and a small move
        // pays more in pool and hook fees than it gains. A zero-loss locker must refuse that.
        LiquidityLocker strict = newLocker(0);
        thirdPartyLiquidity(1e15);
        vm.startPrank(owner);
        index.approve(address(strict), type(uint256).max);
        usd.approve(address(strict), type(uint256).max);
        (uint256 a0, uint256 a1) = shareIs0 ? (uint256(2.5e18), uint256(25.2e6)) : (uint256(25.2e6), uint256(2.5e18));
        strict.deposit(address(index), a0, a1, FULL_LOWER, FULL_UPPER, 0, block.timestamp);
        LiquidityLocker.Recenter memory r = params(10.11e18, FULL_LOWER, FULL_UPPER);
        vm.expectPartialRevert(LiquidityLocker.ValueBelowFloor.selector);
        strict.recenter(r);
        vm.stopPrank();
        // The same move under the deployed tolerance goes through, and loses less than it allows.
        deposit(2.5e18, 25.2e6, FULL_LOWER, FULL_UPPER);
        uint256 before = value(10.11e18);
        vm.prank(owner);
        locker.recenter(r);
        assertLt(value(10.11e18), before, "it did cost something");
        assertGe(value(10.11e18) * 10_000, before * (10_000 - MAX_LOSS));
    }

    function testRecenterThatMissesTheTargetReverts() public {
        thirdPartyLiquidity(1e15);
        deposit(2.5e18, 25.2e6, FULL_LOWER, FULL_UPPER);
        LiquidityLocker.Recenter memory r = params(9.8e18, FULL_LOWER, FULL_UPPER);
        r.maxSwapIn = 1e15; // a thousandth of a share cannot move a deep pool 3%
        vm.prank(owner);
        vm.expectPartialRevert(LiquidityLocker.MissedTarget.selector);
        locker.recenter(r);
    }

    function testLiquidityFloorIsEnforced() public {
        uint128 before = deposit(2.5e18, 25.2e6, FULL_LOWER, FULL_UPPER);
        LiquidityLocker.Recenter memory r = params(9.41e18, FULL_LOWER, FULL_UPPER);
        r.minLiquidity = before;
        vm.prank(owner);
        vm.expectPartialRevert(LiquidityLocker.LiquidityBelowFloor.selector);
        locker.recenter(r);
    }

    function testRangeMustHoldTheTargetAndToleranceIsCapped() public {
        deposit(2.5e18, 25.2e6, FULL_LOWER, FULL_UPPER);
        (int24 lower, int24 upper) = around(12e18, 200);
        vm.startPrank(owner);
        vm.expectRevert(LiquidityLocker.BadRange.selector);
        locker.recenter(params(9.41e18, lower, upper));
        LiquidityLocker.Recenter memory r = params(9.41e18, FULL_LOWER, FULL_UPPER);
        r.toleranceBps = 101;
        vm.expectRevert(LiquidityLocker.BadTolerance.selector);
        locker.recenter(r);
        r = params(9.41e18, FULL_LOWER, FULL_UPPER);
        r.deadline = block.timestamp - 1;
        vm.expectRevert(LiquidityLocker.Expired.selector);
        locker.recenter(r);
        vm.stopPrank();
    }

    function testOwnerMoveIsCapped() public {
        deposit(2.5e18, 25.2e6, FULL_LOWER, FULL_UPPER);
        vm.prank(owner);
        vm.expectPartialRevert(LiquidityLocker.MoveTooLarge.selector);
        locker.recenter(params(8.6e18, FULL_LOWER, FULL_UPPER)); // 17% down
    }

    // ------------------------------------------------------------------ operator

    function testOperatorCanOnlyRecenterWithinItsCapAndCooldown() public {
        deposit(2.5e18, 25.2e6, FULL_LOWER, FULL_UPPER);
        vm.prank(operatorKey);
        vm.expectRevert(LiquidityLocker.NotAllowed.selector);
        locker.recenter(params(10e18, FULL_LOWER, FULL_UPPER));

        vm.prank(owner);
        locker.setOperator(operatorKey);
        vm.startPrank(operatorKey);
        vm.expectPartialRevert(LiquidityLocker.MoveTooLarge.selector);
        locker.recenter(params(9.41e18, FULL_LOWER, FULL_UPPER)); // 6.6%: owner territory only
        locker.recenter(params(9.9e18, FULL_LOWER, FULL_UPPER)); // 1.8%
        vm.expectRevert(LiquidityLocker.Cooldown.selector);
        locker.recenter(params(9.7e18, FULL_LOWER, FULL_UPPER));
        vm.warp(block.timestamp + COOLDOWN);
        locker.recenter(params(9.7e18, FULL_LOWER, FULL_UPPER));

        // Nothing else is open to it.
        vm.expectRevert(LiquidityLocker.NotOwner.selector);
        locker.deposit(address(index), 1, 1, FULL_LOWER, FULL_UPPER, 0, block.timestamp);
        vm.expectRevert(LiquidityLocker.NotOwner.selector);
        locker.topUp(address(index), 1, 1);
        vm.expectRevert(LiquidityLocker.NotOwner.selector);
        locker.withdraw(address(index));
        vm.expectRevert(LiquidityLocker.NotOwner.selector);
        locker.setOperator(address(0xBAD));
        vm.expectRevert(LiquidityLocker.NotOwner.selector);
        locker.extendLock(unlockAt + 1);
        vm.stopPrank();

        // The owner is not held to the operator's cooldown, and can revoke it.
        vm.startPrank(owner);
        locker.recenter(params(9.41e18, FULL_LOWER, FULL_UPPER));
        locker.setOperator(address(0));
        vm.stopPrank();
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(operatorKey);
        vm.expectRevert(LiquidityLocker.NotAllowed.selector);
        locker.recenter(params(9.41e18, FULL_LOWER, FULL_UPPER));
    }

    function testFloatIsPerIndex() public {
        // A second share in the same quote. Its USDG float must not pay for this index's swap.
        TestAsset other = new TestAsset("Other", 18);
        PoolKey memory otherKey = keyFor(address(other));
        ShareFeeHook(HOOK_ADDR).register(otherKey, address(other), address(0xC0FFEE));
        markets.set(address(other), otherKey);
        pm.initialize(otherKey, sqrtPriceAt(address(other), 10e18));
        other.mint(owner, 10e18);
        vm.startPrank(owner);
        other.approve(address(locker), type(uint256).max);
        bool o0 = address(other) < address(usd);
        locker.topUp(address(other), o0 ? 0 : 1_000e6, o0 ? 1_000e6 : 0);
        vm.stopPrank();

        thirdPartyLiquidity(1e13);
        (uint256 a0, uint256 a1) = shareIs0 ? (uint256(2.5e18), uint256(0)) : (uint256(0), uint256(2.5e18));
        vm.prank(owner);
        // A range on the far side of the price holds only shares.
        (int24 lower, int24 upper) = shareIs0 ? (int24(-120), FULL_UPPER) : (FULL_LOWER, int24(120));
        locker.deposit(address(index), a0, a1, lower, upper, 0, block.timestamp);
        uint256 quoteBefore = usd.balanceOf(address(locker));
        // Moving up needs quote in, and this index has almost none: the swap stops short.
        LiquidityLocker.Recenter memory r = params(10.5e18, FULL_LOWER, FULL_UPPER);
        vm.prank(owner);
        vm.expectRevert(LiquidityLocker.InsufficientFloat.selector);
        locker.recenter(r);
        assertEq(usd.balanceOf(address(locker)), quoteBefore);
    }

    // ------------------------------------------------------------------ the lock

    function testNothingLeavesBeforeUnlock() public {
        deposit(2.5e18, 25.2e6, FULL_LOWER, FULL_UPPER);
        vm.warp(unlockAt - 1);
        vm.prank(owner);
        vm.expectRevert(LiquidityLocker.Locked.selector);
        locker.withdraw(address(index));
    }

    function testOwnerWithdrawsEverythingAfterUnlock() public {
        deposit(2.5e18, 25.2e6, FULL_LOWER, FULL_UPPER);
        vm.prank(owner);
        locker.recenter(params(9.41e18, FULL_LOWER, FULL_UPPER));
        uint256 shares = index.balanceOf(owner);
        uint256 quote = usd.balanceOf(owner);
        vm.warp(unlockAt);
        vm.prank(address(0xBAD));
        vm.expectRevert(LiquidityLocker.NotOwner.selector);
        locker.withdraw(address(index));
        vm.prank(owner);
        locker.withdraw(address(index));
        assertEq(locker.positionLiquidity(address(index)), 0);
        assertEq(pm.getLiquidity(key.toId()), 0);
        assertApproxEqAbs(index.balanceOf(owner) - shares, 2.5e18, 1e7);
        assertApproxEqAbs(usd.balanceOf(owner) - quote, 25.2e6, 2);
        assertEq(index.balanceOf(address(locker)), 0);
        assertEq(usd.balanceOf(address(locker)), 0);
    }

    function testUnlockOnlyExtends() public {
        vm.startPrank(owner);
        vm.expectRevert(LiquidityLocker.LockNotExtended.selector);
        locker.extendLock(unlockAt - 1);
        vm.expectRevert(LiquidityLocker.LockNotExtended.selector);
        locker.extendLock(unlockAt);
        locker.extendLock(unlockAt + 30 days);
        assertEq(locker.unlockAt(), unlockAt + 30 days);

        // Per index: only later than whatever holds it now.
        vm.expectRevert(LiquidityLocker.LockNotExtended.selector);
        locker.extendIndexLock(address(index), unlockAt + 1 days);
        locker.extendIndexLock(address(index), unlockAt + 60 days);
        vm.expectRevert(LiquidityLocker.LockNotExtended.selector);
        locker.extendIndexLock(address(index), unlockAt + 59 days);
        assertEq(locker.lockedUntil(address(index)), unlockAt + 60 days);
        vm.stopPrank();

        deposit(2.5e18, 25.2e6, FULL_LOWER, FULL_UPPER);
        vm.warp(unlockAt + 30 days);
        vm.prank(owner);
        vm.expectRevert(LiquidityLocker.Locked.selector);
        locker.withdraw(address(index));
        vm.warp(unlockAt + 60 days);
        vm.prank(owner);
        locker.withdraw(address(index));
    }

    function testConstructorRefusesAPastUnlockOrALooserOperator() public {
        vm.expectRevert(LiquidityLocker.InvalidConfig.selector);
        new LiquidityLocker(pm, markets, owner, uint64(block.timestamp), OWNER_MOVE, OPERATOR_MOVE, COOLDOWN, MAX_LOSS);
        vm.expectRevert(LiquidityLocker.InvalidConfig.selector);
        new LiquidityLocker(pm, markets, owner, unlockAt, 300, 301, COOLDOWN, MAX_LOSS);
    }

    function testDirectCallbackRejected() public {
        vm.expectRevert(LiquidityLocker.UnauthorizedCallback.selector);
        locker.unlockCallback("");
        vm.prank(address(pm));
        vm.expectRevert(LiquidityLocker.UnauthorizedCallback.selector);
        locker.unlockCallback("");
    }
}
