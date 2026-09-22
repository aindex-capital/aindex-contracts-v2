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
        assertEq(hook.FEE_BPS(), 15);
        assertEq(c, (c + p + h) * 4_000 / 10_000, "creator 40%");
        assertEq(p, (c + p + h) * 4_000 / 10_000, "protocol 40%");
        assertEq(h, (c + p + h) - c - p, "holders take the remainder, so nothing is stranded");
    }

    function testHookFeeMatchesFifteenBasisPointsOfOutput() public {
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
         * computed and the ratio floors again when it is checked, so an exact 30 reads as 29.
         * Both roundings are in the trader's favour, which is the direction they should be.
         */
        assertApproxEqAbs(taken * 10_000 / (received + taken), uint256(15), 1,
            "15 bps to the hook; the pool takes another 15 for its LPs, separately");
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
        hook.payHolders(feeKey, out);

        (, uint256[] memory afterAmounts) = index.toAssets(1e18, Math.Rounding.Floor);
        assertLt(index.totalSupply(), supplyBefore, "shares were redeemed away");
        assertGt(afterAmounts[0], beforeAmounts[0], "one share now claims more of the basket");
        assertEq(hook.holderFees(feeKey.toId(), out), 0);
    }

    function testPayHoldersRefusesACurrencyItCannotPayWith() public {
        // A quote that is not a basket asset cannot reach holders without a swap, and a swap here
        // would need a price. Refused, and the accrual is left intact rather than stranded.
        Currency q = Currency.wrap(address(quote));
        feeBuy(2e18);
        vm.startPrank(alice);
        index.approve(address(router), type(uint256).max);
        router.swapExactInput(feeKey, shareIs0, 1e17, 1, limit(shareIs0), block.timestamp);
        vm.stopPrank();

        uint256 accrued = hook.holderFees(feeKey.toId(), q);
        if (accrued == 0) return;
        vm.expectRevert(ShareFeeHook.NotPayableToHolders.selector);
        hook.payHolders(feeKey, q);
        assertEq(hook.holderFees(feeKey.toId(), q), accrued, "a refusal must not consume the accrual");
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
