// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {refPrices} from "./FreshPrices.sol";
import {MonthlyMandateFixture} from "./MonthlyMandate.t.sol";
import {IFolio} from "folio/interfaces/IFolio.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MonthlyMandate} from "../src/MonthlyMandate.sol";

/// v3: the auction runs on bands the mandate builds from prices the reviewer supplies at approval.
/// The fixture's index holds a (18 decimals, reference 1e27) and b (6 decimals, reference 1e39) with a
/// 1% band, so the edge is a third of it, 33 bps. The proposal sells a (target 0.9 per share, holds 1) for b.
contract FreshPricesTest is MonthlyMandateFixture {
    uint256 constant W = 100;
    uint256 constant EDGE = 33;

    function queued() internal returns (IFolio.TokenRebalanceParams[] memory t) {
        t = proposal();
        mandate.queue(t, block.timestamp + 2 hours);
        vm.warp(block.timestamp + 1 hours);
    }

    function points(uint256 pa, uint256 pb) internal pure returns (uint256[] memory p) {
        p = new uint256[](2);
        p[0] = pa;
        p[1] = pb;
    }

    function approveWith(IFolio.TokenRebalanceParams[] memory t, uint256[] memory p) internal {
        vm.prank(reviewer);
        mandate.approve(t, p, block.timestamp + 60);
    }

    function sellBand(uint256 p) internal pure returns (IFolio.PriceRange memory r) {
        r.low = p * (10_000 - EDGE) / 10_000;
        r.high = r.low + r.low * W / 10_000;
    }

    function buyBand(uint256 p) internal pure returns (IFolio.PriceRange memory r) {
        r.high = p * (10_000 + EDGE) / 10_000;
        r.low = Math.mulDiv(r.high, 10_000, 10_000 + W, Math.Rounding.Ceil);
    }

    /// The price the index gets for a in b at the first biddable second, per 10 a.
    function startPay(IFolio.TokenRebalanceParams[] memory t, uint256[] memory p) internal returns (uint256 pay) {
        approveWith(t, p);
        uint256 id = mandate.execute(t);
        vm.warp(block.timestamp + 31);
        (, pay,) = index.getBid(id, IERC20(address(a)), IERC20(address(b)), 10e18);
    }

    function testAuctionOpensOnBandsBuiltFromTheFreshPrices() public {
        IFolio.TokenRebalanceParams[] memory t = queued();
        approveWith(t, points(1.03e27, 1e39));
        assertEq(mandate.approvedHash(), mandate.pending());
        uint256 id = mandate.execute(t);
        IFolio.PriceRange memory got = index.getAuctionPrice(id, address(a));
        IFolio.PriceRange memory want = sellBand(1.03e27);
        assertEq(got.low, want.low);
        assertEq(got.high, want.high);
        got = index.getAuctionPrice(id, address(b));
        want = buyBand(1e39);
        assertEq(got.low, want.low);
        assertEq(got.high, want.high);
        assertEq(mandate.approvedHash(), bytes32(0));
        assertEq(mandate.approvedPrices().length, 0);
        assertEq(mandate.approvedUntil(), 0);
    }

    /// The case that made v3: a rose 4% after the proposal was queued. On the queued prices the first
    /// bidder would take the move from the index; on fresh prices it pays the market.
    function testAMoveAfterQueueNoLongerGoesToTheFirstBidder() public {
        IFolio.TokenRebalanceParams[] memory t = queued();
        uint256 snap = vm.snapshotState();
        uint256 stalePay = startPay(t, refPrices(t));
        vm.revertToState(snap);
        uint256 freshPay = startPay(t, points(1.04e27, 1e39));
        assertGe(freshPay * 10_000, stalePay * 10_390);
    }

    /// The review's attack: sell token down 15%, buy token up 15%. Refused. The most a rogue reviewer
    /// can now move a pair is 5%, and the auction still starts no worse than that for the index.
    function testARogueReviewerCanMoveAPairAtMostFivePercent() public {
        IFolio.TokenRebalanceParams[] memory t = queued();
        vm.prank(reviewer);
        vm.expectRevert(MonthlyMandate.InvalidProposal.selector);
        mandate.approve(t, points(0.85e27, 1.15e39), block.timestamp + 60);
        vm.prank(reviewer);
        vm.expectRevert(MonthlyMandate.InvalidProposal.selector);
        mandate.approve(t, points(0.97e27, 1.03e39), block.timestamp + 60);

        uint256 snap = vm.snapshotState();
        uint256 honest = startPay(t, refPrices(t));
        vm.revertToState(snap);
        uint256 rogue = startPay(t, points(0.9525e27, 1e39));
        assertGe(rogue * 10_000, honest * 9_500);
    }

    function testEveryPriceMovingTogetherIsAllowedUpToFifteenPercent() public {
        IFolio.TokenRebalanceParams[] memory t = queued();
        approveWith(t, points(1.1e27, 1.1e39));
        mandate.execute(t);
        t = proposal();
        vm.warp(block.timestamp + 30 days);
        mandate.queue(t, block.timestamp + 2 hours);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(reviewer);
        vm.expectRevert(MonthlyMandate.InvalidProposal.selector);
        mandate.approve(t, points(1.16e27, 1.16e39), block.timestamp + 60);
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

        uint256[] memory one = new uint256[](1);
        one[0] = 1e27;
        vm.prank(reviewer);
        vm.expectRevert(MonthlyMandate.InvalidProposal.selector);
        mandate.approve(t, one, block.timestamp + 60);

        vm.prank(reviewer);
        vm.expectRevert(MonthlyMandate.InvalidProposal.selector);
        mandate.approve(t, points(0, 1e39), block.timestamp + 60);

        vm.prank(reviewer);
        vm.expectRevert(MonthlyMandate.InvalidProposal.selector);
        mandate.approve(t, refPrices(t), block.timestamp + 5 minutes + 1);
    }

    function testReapprovalReplacesThePrices() public {
        IFolio.TokenRebalanceParams[] memory t = queued();
        approveWith(t, points(1.02e27, 1e39));
        approveWith(t, points(0.98e27, 1e39));
        uint256 id = mandate.execute(t);
        assertEq(index.getAuctionPrice(id, address(a)).low, sellBand(0.98e27).low);
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

    /// For any prices the rules allow, the auction starts no worse than today's pair price for the
    /// index and ends no more than two edges past it.
    function testFuzzAnyAllowedPricesStartInTheIndexsFavourAndEndJustPastIt(uint256 pa, uint256 rel) public {
        IFolio.TokenRebalanceParams[] memory t = queued();
        pa = bound(pa, 0.9e27, 1.1e27);
        rel = bound(rel, 9_600, 10_400);
        uint256 pb = 1e39 * pa / 1e27 * rel / 10_000;
        approveWith(t, points(pa, pb));
        uint256 id = mandate.execute(t);
        IFolio.PriceRange memory sa = index.getAuctionPrice(id, address(a));
        IFolio.PriceRange memory sb = index.getAuctionPrice(id, address(b));
        uint256 fair = Math.mulDiv(pa, 1e27, pb);
        uint256 start = Math.mulDiv(sa.high, 1e27, sb.low);
        uint256 end = Math.mulDiv(sa.low, 1e27, sb.high, Math.Rounding.Ceil);
        assertGe(start, fair);
        assertGe(end * 10_000, fair * (10_000 - 2 * EDGE - 1));
        assertLe(end, fair);
    }

    function testFuzzPricesThatMoveApartMoreThanFivePercentAreRefused(uint256 rel) public {
        IFolio.TokenRebalanceParams[] memory t = queued();
        rel = bound(rel, 10_501, 11_400);
        vm.prank(reviewer);
        vm.expectRevert(MonthlyMandate.InvalidProposal.selector);
        mandate.approve(t, points(1e27, 1e39 * rel / 10_000), block.timestamp + 60);
    }
}
