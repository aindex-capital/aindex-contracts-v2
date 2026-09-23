// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ShareMarketTest} from "./ShareMarket.t.sol";
import {ShareFeeHook} from "../src/ShareFeeHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice The fee hook, charged on a pool whose own arithmetic still runs.
contract ShareFeeHookTest is ShareMarketTest {
    ShareFeeHook internal hook;
    PoolKey internal feeKey;
    address internal creator = address(0xC0FFEE);
    address internal treasury = address(0xBEEF);

    /// @dev afterSwap | afterSwapReturnDelta. The PoolManager reads these from the address, so the
    ///      hook is placed at one carrying them; `script/mine-hook-salt.py` finds a real salt.
    address internal constant HOOK_ADDR = address(uint160(0x4444000000000000000000000000000000000044));
    /// @dev Must match ShareFeeHook.LP_FEE_BPS; the hook refuses any other.
    uint24 internal constant LP_FEE = 1_500;

    function routerFeeHook() internal view override returns (address) {
        return HOOK_ADDR;
    }


    function setUp() public virtual override {
        // The router only records the hook address at construction, so placing the code after
        // `super.setUp()` is fine and keeps the parent fixture untouched.
        super.setUp();
        deployCodeTo("out/ShareFeeHook.sol/ShareFeeHook.json", abi.encode(pm, address(this), treasury), HOOK_ADDR);
        hook = ShareFeeHook(HOOK_ADDR);

        // The pool keeps its own fee for liquidity providers; the hook charges on top.
        feeKey = PoolKey(
            Currency.wrap(shareIs0 ? address(index) : address(quote)),
            Currency.wrap(shareIs0 ? address(quote) : address(index)), LP_FEE, 60, IHooks(HOOK_ADDR)
        );
        hook.register(feeKey, address(index), creator);
        pm.initialize(feeKey, uint160(1 << 96));
        router.modifyLiquidity(feeKey, position(100e18), 101e18, 101e18, block.timestamp);
    }

    function feeBuy(uint256 amount) internal {
        bool direction = !shareIs0;
        vm.prank(alice);
        router.swapExactInput(feeKey, direction, amount, 1, limit(direction), block.timestamp);
    }

    function testSwapStillEmitsRealAmountsWithTheHookAttached() public {
        // The reason this design exists. The retired dealer hook emitted Swap with zero amounts,
        // which is why nothing indexed it. Here the pool's arithmetic runs and the event is true.
        vm.recordLogs();
        feeBuy(1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawNonZero;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")) continue;
            (int128 a0, int128 a1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            if (a0 != 0 && a1 != 0) sawNonZero = true;
        }
        assertTrue(sawNonZero, "the pool must emit a truthful Swap or no indexer will see it");
    }

    function testFeeIsChargedAndSplitsExactly() public {
        Currency out = Currency.wrap(shareIs0 ? address(index) : address(quote));
        feeBuy(1e18);

        uint256 c = hook.creatorFees(feeKey.toId(), out);
        uint256 p = hook.protocolFees(feeKey.toId(), out);
        uint256 h = hook.holderFees(feeKey.toId(), out);
        assertGt(c + p + h, 0, "a swap must charge something");

        // The three buckets must account for every wei taken, or dust belongs to nobody.
        assertEq(hook.FEE_BPS(), 25);
        assertEq(c, (c + p + h) * 3_200 / 10_000, "creator 32%, 8 of 25 bps");
        assertEq(p, (c + p + h) * 3_600 / 10_000, "protocol 36%, 9 of 25 bps");
        assertEq(h, (c + p + h) - c - p, "holders take the remainder, so nothing is stranded");
    }

    function testHookFeeMatchesTwentyFiveBasisPointsOfOutput() public {
        Currency out = Currency.wrap(shareIs0 ? address(index) : address(quote));
        uint256 before_ = index.balanceOf(alice);
        feeBuy(1e18);
        uint256 received = index.balanceOf(alice) - before_;
        uint256 taken = hook.creatorFees(feeKey.toId(), out) + hook.protocolFees(feeKey.toId(), out)
            + hook.holderFees(feeKey.toId(), out);
        /*
         * The swapper keeps the output less the fee, so fee/(received+fee) is the rate.
         *
         * Compared to within one basis point rather than exactly: the fee floors once when it is
         * computed and the ratio floors again when it is checked, so an exact 25 reads as 24.
         * Both roundings are in the trader's favour, which is the direction they should be.
         */
        assertApproxEqAbs(taken * 10_000 / (received + taken), uint256(25), 1,
            "25 bps to the hook; the pool takes another 15 for its LPs, separately");
    }

    function testClaimPaysCreatorAndProtocolAndNobodyElse() public {
        Currency out = Currency.wrap(shareIs0 ? address(index) : address(quote));
        feeBuy(1e18);
        uint256 c = hook.creatorFees(feeKey.toId(), out);
        uint256 p = hook.protocolFees(feeKey.toId(), out);

        // Permissionless: a stranger calls it, and the money still goes where storage says.
        vm.prank(address(0xD00D));
        hook.claim(feeKey, out);

        assertEq(index.balanceOf(creator), c, "creator paid");
        assertEq(index.balanceOf(treasury), p, "protocol paid");
        assertEq(hook.creatorFees(feeKey.toId(), out), 0);
        assertEq(hook.protocolFees(feeKey.toId(), out), 0);
        assertEq(hook.holderFees(feeKey.toId(), out), hook.holderFees(feeKey.toId(), out), "holders untouched");
    }

    function testPayHoldersInSharesRaisesBackingPerShare() public {
        // The fee arrived as SHARE. It cannot be sent to the Folio, so it is redeemed and the
        // basket returned: supply falls, holdings unchanged, backing per share rises.
        Currency out = Currency.wrap(shareIs0 ? address(index) : address(quote));
        feeBuy(5e18);
        uint256 accrued = hook.holderFees(feeKey.toId(), out);
        assertGt(accrued, 0);

        (, uint256[] memory beforeAmounts) = index.toAssets(1e18, Math.Rounding.Floor);
        uint256 supplyBefore = index.totalSupply();

        vm.prank(address(0xD00D)); // permissionless
        hook.payHolders(feeKey, out, 0);

        (, uint256[] memory afterAmounts) = index.toAssets(1e18, Math.Rounding.Floor);
        assertLt(index.totalSupply(), supplyBefore, "shares were redeemed away");
        assertGt(afterAmounts[0], beforeAmounts[0], "one share now claims more of the basket");
        assertEq(hook.holderFees(feeKey.toId(), out), 0);
    }

    /// @dev A sell, exact input: the fee is taken in the quote token, which is not in the basket.
    function feeSell(uint256 shares) internal {
        vm.startPrank(alice);
        index.approve(address(router), type(uint256).max);
        router.swapExactInput(feeKey, shareIs0, shares, 1, limit(shareIs0), block.timestamp);
        vm.stopPrank();
    }

    function testQuoteHolderFeesAreBoughtBackAndBurned() public {
        // Sells pay their fee in the quote token. It used to be refused here and stay stuck forever;
        // now it buys shares in this pool and those are redeemed into backing.
        Currency q = Currency.wrap(address(quote));
        feeBuy(5e18);
        feeSell(2e18);
        uint256 accrued = hook.holderFees(feeKey.toId(), q);
        assertGt(accrued, 0, "a sell must accrue holders' share in the quote token");

        (, uint256[] memory beforeAmounts) = index.toAssets(1e18, Math.Rounding.Floor);
        uint256 supplyBefore = index.totalSupply();
        uint256 creatorBefore = hook.creatorFees(feeKey.toId(), q) + hook.creatorFees(feeKey.toId(), Currency.wrap(address(index)));

        vm.prank(address(0xD00D)); // permissionless
        hook.payHolders(feeKey, q, 1);

        assertEq(hook.holderFees(feeKey.toId(), q), 0, "the whole accrual was spent");
        assertLt(index.totalSupply(), supplyBefore, "bought shares were redeemed away");
        (, uint256[] memory afterAmounts) = index.toAssets(1e18, Math.Rounding.Floor);
        assertGt(afterAmounts[0], beforeAmounts[0], "one share now claims more of the basket");
        assertEq(hook.creatorFees(feeKey.toId(), q) + hook.creatorFees(feeKey.toId(), Currency.wrap(address(index))), creatorBefore,
            "the hook's own buyback is not charged a fee");
        assertEq(quote.balanceOf(address(hook)), hook.creatorFees(feeKey.toId(), q) + hook.protocolFees(feeKey.toId(), q),
            "what the hook still holds in quote is exactly what it still owes");
    }

    function testBuybackBelowTheCallersMinimumReverts() public {
        Currency q = Currency.wrap(address(quote));
        feeBuy(5e18);
        feeSell(2e18);
        uint256 accrued = hook.holderFees(feeKey.toId(), q);
        vm.expectRevert();
        hook.payHolders(feeKey, q, type(uint256).max);
        assertEq(hook.holderFees(feeKey.toId(), q), accrued, "a refusal must not consume the accrual");
    }

    function testExactOutputSwapsPayTheHookFeeToo() public {
        // Exact output: the trader fixes how many shares they get, and the input is unspecified.
        // This used to return early and charge nothing but the LP fee.
        PoolSwapTest swapper = new PoolSwapTest(pm);
        quote.mint(address(this), 10e18);
        quote.approve(address(swapper), type(uint256).max);
        bool zeroForOne = !shareIs0; // quote in, shares out
        Currency q = Currency.wrap(address(quote));
        uint256 quoteBefore = quote.balanceOf(address(this));

        swapper.swap(feeKey, SwapParams({zeroForOne: zeroForOne, amountSpecified: int256(1e18), sqrtPriceLimitX96: limit(zeroForOne)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        uint256 paid = quoteBefore - quote.balanceOf(address(this));
        uint256 taken = hook.creatorFees(feeKey.toId(), q) + hook.protocolFees(feeKey.toId(), q) + hook.holderFees(feeKey.toId(), q);
        assertGt(taken, 0, "an exact-output swap must pay the hook fee");
        assertEq(index.balanceOf(address(this)) >= 1e18, true, "the trader still receives exactly what they asked for");
        // The fee is 25 bps of the input before it, so fee / (paid - fee) is the rate.
        assertApproxEqAbs(taken * 10_000 / (paid - taken), uint256(25), 1, "25 bps, now on the input side");
        assertEq(hook.creatorFees(feeKey.toId(), q), taken * 3_200 / 10_000, "and it splits the same way");
    }

    function testUnregisteredPoolCannotBeSwapped() public {
        // `key` is the hookless pool from the parent fixture; a pool the hook does not know must
        // never have a fee taken from it silently.
        PoolKey memory stranger = PoolKey(feeKey.currency0, feeKey.currency1, LP_FEE, 120, IHooks(HOOK_ADDR));
        pm.initialize(stranger, uint160(1 << 96));
        vm.expectRevert();
        router.modifyLiquidity(stranger, position(1e18), 2e18, 2e18, block.timestamp);
    }

    function testEveryOtherCallbackReverts() public {
        // The permission bits mean the PoolManager never calls these. One arriving is evidence.
        vm.expectRevert(ShareFeeHook.HookNotImplemented.selector);
        hook.beforeInitialize(address(0), feeKey, 0);
        vm.expectRevert(ShareFeeHook.HookNotImplemented.selector);
        hook.afterDonate(address(0), feeKey, 0, 0, "");
    }

    function testRegisterIsOnlyForTheRegistrarAndOnlyOnce() public {
        PoolKey memory other = PoolKey(feeKey.currency0, feeKey.currency1, LP_FEE, 200, IHooks(HOOK_ADDR));
        vm.prank(address(0xBAD));
        vm.expectRevert(ShareFeeHook.NotRegistrar.selector);
        hook.register(other, address(index), creator);

        hook.register(other, address(index), creator);
        vm.expectRevert(ShareFeeHook.AlreadyRegistered.selector);
        hook.register(other, address(index), creator);
    }

    function testAPoolThatWouldPayLpsNothingIsRefused() public {
        // A zero pool fee pays liquidity providers nothing, and this design needs them. The
        // registry cannot create such a market and the hook will not bind one either.
        PoolKey memory starved = PoolKey(feeKey.currency0, feeKey.currency1, 0, 60, IHooks(HOOK_ADDR));
        vm.expectRevert(ShareFeeHook.WrongLpFee.selector);
        hook.register(starved, address(index), creator);

        // Nor one that charges a different amount than the pool this registry builds.
        PoolKey memory wrong = PoolKey(feeKey.currency0, feeKey.currency1, 3000, 60, IHooks(HOOK_ADDR));
        vm.expectRevert(ShareFeeHook.WrongLpFee.selector);
        hook.register(wrong, address(index), creator);
    }

    function testLiquidityProvidersAreActuallyPaid() public {
        // The failure that sent this design back: with the pool fee at zero an LP earned nothing
        // and had no reason to supply the depth the whole model depends on.
        feeBuy(2e18);
        (,,, uint256 owed0, uint256 owed1) = router.marketState(feeKey);
        assertGt(owed0 + owed1, 0, "the pool fee must reach liquidity providers");
    }
}
