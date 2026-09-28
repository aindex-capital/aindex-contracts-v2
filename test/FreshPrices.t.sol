// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {refPrices} from "./FreshPrices.sol";
import {MonthlyMandateFixture} from "./MonthlyMandate.t.sol";
import {IFolio} from "folio/interfaces/IFolio.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MonthlyMandate} from "../src/MonthlyMandate.sol";

/// v3: the auction runs on prices the reviewer supplies at approval, not on the queued reference.
/// The fixture's index holds a (18 decimals, reference 1e27) and b (6 decimals, reference 1e39), with
/// a 1% band. The proposal sells a for b.
contract FreshPricesTest is MonthlyMandateFixture {
    function queued() internal returns (IFolio.TokenRebalanceParams[] memory t) {
        t = proposal();
        mandate.queue(t, block.timestamp + 2 hours);
        vm.warp(block.timestamp + 1 hours);
    }

    function band(uint256 low, uint256 bps) internal pure returns (IFolio.PriceRange memory) {
        return IFolio.PriceRange(low, low + low * bps / 10_000);
    }

    function approveWith(IFolio.TokenRebalanceParams[] memory t, IFolio.PriceRange[] memory p) internal {
        vm.prank(reviewer);
        mandate.approve(t, p, block.timestamp + 60);
    }

    function testAuctionOpensOnTheFreshBands() public {
        IFolio.TokenRebalanceParams[] memory t = queued();
        IFolio.PriceRange[] memory p = refPrices(t);
        p[0] = band(1.1e27, 50);
        approveWith(t, p);
        assertEq(mandate.approvedHash(), mandate.pending());
        uint256 id = mandate.execute(t);
        IFolio.PriceRange memory got = index.getAuctionPrice(id, address(a));
        assertEq(got.low, p[0].low);
        assertEq(got.high, p[0].high);
        got = index.getAuctionPrice(id, address(b));
        assertEq(got.low, t[1].price.low);
        // Spent: nothing of the approval survives the execution.
        assertEq(mandate.approvedHash(), bytes32(0));
        assertEq(mandate.approvedPrices().length, 0);
        assertEq(mandate.approvedUntil(), 0);
    }

    /// The case that made v3: a rose 10% after the proposal was queued. On the queued prices the
    /// first bidder would buy the index's a 10% under the market; on fresh prices it pays the market.
    function testAMoveAfterQueueNoLongerGoesToTheFirstBidder() public {
        IFolio.TokenRebalanceParams[] memory t = queued();
        uint256 snap = vm.snapshotState();

        approveWith(t, refPrices(t));
        uint256 id = mandate.execute(t);
        vm.warp(block.timestamp + 31);
        (, uint256 stalePay,) = index.getBid(id, IERC20(address(a)), IERC20(address(b)), 10e18);

        vm.revertToState(snap);
        IFolio.PriceRange[] memory p = refPrices(t);
        p[0] = band(1.1e27, 10);
        approveWith(t, p);
        id = mandate.execute(t);
        vm.warp(block.timestamp + 31);
        (, uint256 freshPay,) = index.getBid(id, IERC20(address(a)), IERC20(address(b)), 10e18);

        // The bidder now pays about 10% more b for the same a.
        assertGe(freshPay * 10_000, stalePay * 10_900);
    }

    function testApproveRefusesAnythingButTheQueuedProposalFromTheReviewer() public {
        mandate.queue(proposal(), block.timestamp + 2 hours);
        IFolio.TokenRebalanceParams[] memory t = proposal();
        vm.prank(reviewer);
        vm.expectRevert(MonthlyMandate.WrongState.selector);
        mandate.approve(t, refPrices(t), block.timestamp + 60);
        vm.warp(block.timestamp + 1 hours);

        vm.expectRevert(MonthlyMandate.Unauthorized.selector);
        mandate.approve(t, refPrices(t), block.timestamp + 60);

        IFolio.TokenRebalanceParams[] memory other = proposal();
        other[0].maxAuctionSize--;
        vm.prank(reviewer);
        vm.expectRevert(MonthlyMandate.WrongState.selector);
        mandate.approve(other, refPrices(other), block.timestamp + 60);

        IFolio.PriceRange[] memory short_ = new IFolio.PriceRange[](1);
        short_[0] = t[0].price;
        vm.prank(reviewer);
        vm.expectRevert(MonthlyMandate.InvalidProposal.selector);
        mandate.approve(t, short_, block.timestamp + 60);

        vm.prank(reviewer);
        vm.expectRevert(MonthlyMandate.InvalidProposal.selector);
        mandate.approve(t, refPrices(t), block.timestamp + 5 minutes + 1);
    }

    function testFreshBandsObeyWidthAndStayNearTheReference() public {
        IFolio.TokenRebalanceParams[] memory t = queued();
        IFolio.PriceRange[][] memory bad = new IFolio.PriceRange[][](6);
        for (uint256 i; i < bad.length; ++i) bad[i] = refPrices(t);
        bad[0][0] = band(1e27, 101);                          // wider than the 1% band
        bad[1][0] = IFolio.PriceRange(0.849e27, 0.85e27);     // more than 15% under the reference low
        bad[2][0] = IFolio.PriceRange(1.15e27, 1.1512e27);    // more than 15% over the reference high
        bad[3][0] = IFolio.PriceRange(0, 1);                  // zero
        bad[4][0] = IFolio.PriceRange(1e27, 1e27);            // empty band
        bad[5][1] = IFolio.PriceRange(0.8e39, 0.801e39);      // the second token too
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(reviewer);
            vm.expectRevert(MonthlyMandate.InvalidProposal.selector);
            mandate.approve(t, bad[i], block.timestamp + 60);
        }
        // The edges themselves are allowed.
        IFolio.PriceRange[] memory edge = refPrices(t);
        edge[0] = IFolio.PriceRange(0.85e27, 0.85e27 + 0.85e27 / 100);
        edge[1] = IFolio.PriceRange(1.14e39, 1.15115e39);
        approveWith(t, edge);
        mandate.execute(t);
    }

    function testReapprovalReplacesThePrices() public {
        IFolio.TokenRebalanceParams[] memory t = queued();
        IFolio.PriceRange[] memory p = refPrices(t);
        p[0] = band(1.05e27, 50);
        approveWith(t, p);
        p[0] = band(0.95e27, 50);
        approveWith(t, p);
        uint256 id = mandate.execute(t);
        assertEq(index.getAuctionPrice(id, address(a)).low, 0.95e27);
    }

    function testExecuteNeedsACurrentApproval() public {
        IFolio.TokenRebalanceParams[] memory t = queued();
        vm.expectRevert(MonthlyMandate.ApprovalExpired.selector);
        mandate.execute(t);
        approveWith(t, refPrices(t));
        vm.warp(block.timestamp + 61);
        vm.expectRevert(MonthlyMandate.ApprovalExpired.selector);
        mandate.execute(t);
    }

    /// An approval belongs to one proposal: cancelling and queueing again never inherits it.
    function testCancelClearsTheApprovalForTheNextProposal() public {
        IFolio.TokenRebalanceParams[] memory t = queued();
        approveWith(t, refPrices(t));
        vm.prank(guardian);
        mandate.cancel();
        assertEq(mandate.approvedHash(), bytes32(0));
        assertEq(mandate.approvedPrices().length, 0);
        assertEq(mandate.approvedUntil(), 0);
        t = queued();
        vm.expectRevert(MonthlyMandate.ApprovalExpired.selector);
        mandate.execute(t);
    }

    function testExpiredProposalLeavesNoApproval() public {
        IFolio.TokenRebalanceParams[] memory t = queued();
        approveWith(t, refPrices(t));
        vm.warp(block.timestamp + 1 hours + 1);
        mandate.clearExpired();
        assertEq(mandate.approvedHash(), bytes32(0));
        assertEq(mandate.approvedPrices().length, 0);
    }

    function testFuzzAnyBandInsideTheRulesOpensOnExactlyThosePrices(uint256 low, uint256 bps) public {
        IFolio.TokenRebalanceParams[] memory t = queued();
        bps = bound(bps, 1, 100);
        uint256 maxHigh = t[0].price.high * 11_500 / 10_000;
        low = bound(low, 0.85e27, maxHigh * 10_000 / (10_000 + bps));
        IFolio.PriceRange[] memory p = refPrices(t);
        p[0] = band(low, bps);
        approveWith(t, p);
        uint256 id = mandate.execute(t);
        IFolio.PriceRange memory got = index.getAuctionPrice(id, address(a));
        assertEq(got.low, p[0].low);
        assertEq(got.high, p[0].high);
    }

    function testFuzzAnyBandOutsideTheGuardIsRefused(uint256 low) public {
        IFolio.TokenRebalanceParams[] memory t = queued();
        low = bound(low, 1, 0.85e27 - 1);
        IFolio.PriceRange[] memory p = refPrices(t);
        p[0] = band(low, 50);
        vm.prank(reviewer);
        vm.expectRevert(MonthlyMandate.InvalidProposal.selector);
        mandate.approve(t, p, block.timestamp + 60);
    }
}
