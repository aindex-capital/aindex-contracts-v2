// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IndexFixture} from "./IndexLifecycle.t.sol";
import {Folio} from "folio/Folio.sol";
import {IFolio} from "folio/interfaces/IFolio.sol";
import {MonthlyMandate} from "../src/MonthlyMandate.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {FixedFeeRegistry} from "../src/FixedFeeRegistry.sol";

/**
 * A creator running an index alone: one wallet holds every role.
 *
 * What stands in for an independent reviewer is time. A self-reviewed rebalance must be announced
 * at least a day ahead, so holders can see it and redeem, for free, before it executes.
 */
contract SoloMandateTest is IndexFixture {
    IndexFactory internal soloFactory;

    function setUp() public override {
        super.setUp();
        soloFactory = new IndexFactory(address(new Folio()), address(new FixedFeeRegistry(address(0xFEE), 0.2e18, 0)));
        a.approve(address(soloFactory), type(uint256).max);
        b.approve(address(soloFactory), type(uint256).max);
    }

    function soloConfig(uint256 notice) internal view returns (MonthlyMandate.Config memory) {
        return MonthlyMandate.Config({proposer: address(this), reviewer: address(this), guardian: address(this),
            notice: notice, interval: 30 days, auctionLength: 300, maxPriceSpreadBps: 100, methodologyHash: keccak256("solo")});
    }

    function rules() internal view returns (MonthlyMandate.TokenRule[] memory r) {
        r = new MonthlyMandate.TokenRule[](2);
        r[0] = MonthlyMandate.TokenRule(address(a), 0, 2e27, 100e18);
        r[1] = MonthlyMandate.TokenRule(address(b), 0, 2e15, 100e6);
    }

    function proposal() internal view returns (IFolio.TokenRebalanceParams[] memory t) {
        t = new IFolio.TokenRebalanceParams[](2);
        t[0] = IFolio.TokenRebalanceParams(address(a), IFolio.WeightRange(0.9e27, 0.9e27, 0.9e27),
            IFolio.PriceRange(1e27, 1.001e27), 100e18, true);
        t[1] = IFolio.TokenRebalanceParams(address(b), IFolio.WeightRange(1.1e15, 1.1e15, 1.1e15),
            IFolio.PriceRange(1e39, 1.001e39), 100e6, true);
    }

    function testOneWalletCanRunAnIndexAloneWithADayOfNotice() public {
        (Folio soloIndex, MonthlyMandate m) = soloFactory.createManaged(seed(), soloConfig(24 hours), rules());
        assertTrue(m.activated());
        IFolio.TokenRebalanceParams[] memory t = proposal();
        m.queue(t, block.timestamp + 26 hours);
        bytes32 hash = m.pending();

        // Announced, but holders get their day before anything can happen.
        // Not even the approval can be given before the notice has run.
        vm.warp(block.timestamp + 23 hours);
        vm.expectRevert(MonthlyMandate.WrongState.selector);
        m.approve(hash, block.timestamp + 60);

        vm.warp(block.timestamp + 1 hours);
        m.approve(hash, block.timestamp + 60);
        m.execute(t);
        assertEq(soloIndex.getRebalanceNonce(), 1, "the creator ran a rebalance end to end on their own");
    }

    function testSelfReviewNeedsAtLeastADayOfNotice() public {
        vm.expectRevert(MonthlyMandate.InvalidPolicy.selector);
        soloFactory.createManaged(seed(), soloConfig(23 hours), rules());
        soloFactory.createManaged(seed(), soloConfig(24 hours), rules());
    }

    function testAnIndependentReviewerKeepsTheShortNotice() public {
        MonthlyMandate.Config memory cfg = soloConfig(1 hours);
        cfg.reviewer = address(0xB0B);
        (, MonthlyMandate m) = soloFactory.createManaged(seed(), cfg, rules());
        assertTrue(m.activated(), "creator proposes and guards, someone else approves prices");
    }

    function testASoloCreatorCanCancelAndNobodyCanTakeTheRolesOver() public {
        (, MonthlyMandate m) = soloFactory.createManaged(seed(), soloConfig(24 hours), rules());
        m.queue(proposal(), block.timestamp + 26 hours);
        m.cancel();
        assertEq(m.pending(), bytes32(0));

        // Recovery needs two other holders to agree. With one wallet in every role there are none,
        // so nobody, including a stranger, can start replacing a role.
        vm.expectRevert(MonthlyMandate.Unauthorized.selector);
        m.requestRoleChange(0, address(0xBEEF));
        vm.prank(address(0xBAD));
        vm.expectRevert(MonthlyMandate.Unauthorized.selector);
        m.requestRoleChange(1, address(0xBEEF));
    }
}
