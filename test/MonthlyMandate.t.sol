// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IndexFixture} from "./IndexLifecycle.t.sol";
import {Folio} from "folio/Folio.sol";
import {IFolio} from "folio/interfaces/IFolio.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MonthlyMandate} from "../src/MonthlyMandate.sol";
import {ManagedIndexFactory} from "../src/ManagedIndexFactory.sol";
import {FixedFeeRegistry} from "../src/FixedFeeRegistry.sol";

abstract contract MonthlyMandateFixture is IndexFixture {
    MonthlyMandate internal mandate;
    ManagedIndexFactory internal managedFactory;
    address internal reviewer = address(0xB0B);
    address internal guardian = address(0xCAFE);

    function setUp() public virtual override {
        super.setUp();
        managedFactory = new ManagedIndexFactory(address(new Folio()), address(new FixedFeeRegistry(address(0xFEE), 0.2e18, 0)), seed().assets);
        a.approve(address(managedFactory), type(uint256).max);
        b.approve(address(managedFactory), type(uint256).max);
        MonthlyMandate.TokenRule[] memory rules = new MonthlyMandate.TokenRule[](2);
        rules[0] = MonthlyMandate.TokenRule(address(a), 0, 2e27, 100e18);
        rules[1] = MonthlyMandate.TokenRule(address(b), 0, 2e15, 100e6);
        (index, mandate) = managedFactory.createManaged(seed(), MonthlyMandate.Config({
            proposer: address(this), reviewer: reviewer, guardian: guardian,
            notice: 1 hours, interval: 30 days, auctionLength: 300,
            maxPriceSpreadBps: 100, methodologyHash: keccak256("test methodology")
        }), rules);
    }

    function proposal() internal view returns (IFolio.TokenRebalanceParams[] memory t) {
        t = new IFolio.TokenRebalanceParams[](2);
        t[0] = IFolio.TokenRebalanceParams(address(a), IFolio.WeightRange(0.9e27, 0.9e27, 0.9e27),
            IFolio.PriceRange(1e27, 1.001e27), 100e18, true);
        t[1] = IFolio.TokenRebalanceParams(address(b), IFolio.WeightRange(1.1e15, 1.1e15, 1.1e15),
            IFolio.PriceRange(1e39, 1.001e39), 100e6, true);
    }

    function ready() internal returns (IFolio.TokenRebalanceParams[] memory t) {
        t = proposal();
        mandate.queue(t, block.timestamp + 2 hours);
        vm.warp(block.timestamp + 1 hours);
        bytes32 hash = mandate.pending();
        vm.prank(reviewer);
        mandate.approve(hash, block.timestamp + 60);
    }

}

contract MonthlyMandateTest is MonthlyMandateFixture {
    function testAtomicLaunchRemovesAllBypassRoles() public view {
        assertTrue(mandate.activated());
        assertEq(index.getRoleMemberCount(bytes32(0)), 1);
        assertEq(index.getRoleMember(bytes32(0), 0), address(mandate));
        assertFalse(index.hasRole(bytes32(0), address(this)));
        assertFalse(index.hasRole(bytes32(0), address(managedFactory)));
        assertEq(managedFactory.mandateOf(address(index)), address(mandate));
        assertEq(index.balanceOf(address(this)), 1_000e18);
    }

    function testRebalanceFillAndProportionalRedemption() public {
        IFolio.TokenRebalanceParams[] memory t = ready();
        uint256 auctionId = mandate.execute(t);
        vm.warp(block.timestamp + 31);
        b.mint(alice, 100e6);
        vm.startPrank(alice);
        b.approve(address(index), 100e6);
        index.bid(auctionId, IERC20(address(a)), IERC20(address(b)), 50e18, 51e6, false, "");
        vm.stopPrank();
        assertEq(a.balanceOf(address(index)), 950e18);
        assertGt(b.balanceOf(address(index)), 1_049e6);
        (address[] memory assets, uint256[] memory amounts) = index.toAssets(100e18, Math.Rounding.Floor);
        uint256 beforeA = a.balanceOf(address(this));
        index.redeem(100e18, address(this), assets, amounts);
        assertEq(a.balanceOf(address(this)) - beforeA, amounts[0]);
        assertLt(amounts[0], 100e18);
        assertGt(amounts[1], 100e6);
    }

    function testNoticeIndependentApprovalAndReplay() public {
        IFolio.TokenRebalanceParams[] memory t = proposal();
        mandate.queue(t, block.timestamp + 2 hours);
        vm.expectRevert(MonthlyMandate.TooEarly.selector);
        mandate.execute(t);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(MonthlyMandate.ApprovalExpired.selector);
        mandate.execute(t);
        bytes32 hash = mandate.pending();
        vm.expectRevert(MonthlyMandate.Unauthorized.selector);
        mandate.approve(hash, block.timestamp + 60);
        vm.prank(reviewer);
        mandate.approve(hash, block.timestamp + 60);
        mandate.execute(t);
        vm.expectRevert(MonthlyMandate.WrongState.selector);
        mandate.execute(t);
    }

    function testCannotOpenAdditionalAuctionOrBypassMonthlyLimit() public {
        IFolio.TokenRebalanceParams[] memory t = ready();
        mandate.execute(t);
        vm.warp(block.timestamp + 1 hours);
        uint256 nonce = index.getRebalanceNonce();
        vm.expectRevert();
        index.openAuctionUnrestricted(nonce);
        t = ready();
        vm.expectRevert(MonthlyMandate.TooEarly.selector);
        mandate.execute(t);
    }

    function testChangedPayloadAndExpiredApprovalFail() public {
        IFolio.TokenRebalanceParams[] memory t = ready();
        t[0].maxAuctionSize--;
        vm.expectRevert(MonthlyMandate.WrongState.selector);
        mandate.execute(t);
        t[0].maxAuctionSize++;
        vm.warp(block.timestamp + 61);
        vm.expectRevert(MonthlyMandate.ApprovalExpired.selector);
        mandate.execute(t);
    }

    function testOversizedTradeAndUnknownAssetRejected() public {
        IFolio.TokenRebalanceParams[] memory t = proposal();
        t[0].maxAuctionSize++;
        vm.expectRevert(MonthlyMandate.InvalidProposal.selector);
        mandate.queue(t, block.timestamp + 2 hours);
        t = proposal();
        t[0].token = address(0xBAD);
        vm.expectRevert(MonthlyMandate.InvalidProposal.selector);
        mandate.queue(t, block.timestamp + 2 hours);
    }

    function testGuardianClosesActiveAuctionWithoutRestoringBudget() public {
        uint256 auctionId = mandate.execute(ready());
        uint256 next = mandate.nextExecutionAt();
        vm.prank(guardian);
        mandate.cancel();
        vm.warp(block.timestamp + 31);
        vm.expectRevert();
        index.getBid(auctionId, IERC20(address(a)), IERC20(address(b)), 1e18);
        assertEq(mandate.nextExecutionAt(), next);
    }

    function testCreatorCannotChangeFeesOrGrantItselfManagement() public {
        vm.expectRevert();
        index.setMintFee(0.05e18);
        vm.expectRevert();
        index.grantRole(keccak256("REBALANCE_MANAGER"), address(this));
    }

    function testMintAndRedeemDuringAuctionUseCurrentBacking() public {
        uint256 auctionId = mandate.execute(ready());
        vm.warp(block.timestamp + 31);
        (address[] memory assets, uint256[] memory amounts) = index.toAssets(50e18, Math.Rounding.Ceil);
        a.mint(alice, amounts[0]);
        b.mint(alice, amounts[1] + 100e6);
        vm.startPrank(alice);
        a.approve(address(index), type(uint256).max);
        b.approve(address(index), type(uint256).max);
        index.mint(50e18, alice, 49e18);
        index.bid(auctionId, IERC20(address(a)), IERC20(address(b)), 20e18, 21e6, false, "");
        uint256 shares = index.balanceOf(alice);
        (assets, amounts) = index.toAssets(shares, Math.Rounding.Floor);
        uint256 beforeA = a.balanceOf(alice);
        index.redeem(shares, alice, assets, amounts);
        assertEq(a.balanceOf(alice) - beforeA, amounts[0]);
        vm.stopPrank();
    }

    function testAggregateFillsCannotExceedAuctionBudget() public {
        uint256 auctionId = mandate.execute(ready());
        vm.warp(block.timestamp + 31);
        b.mint(alice, 300e6);
        vm.startPrank(alice);
        b.approve(address(index), type(uint256).max);
        index.bid(auctionId, IERC20(address(a)), IERC20(address(b)), 60e18, 61e6, false, "");
        vm.expectRevert();
        index.bid(auctionId, IERC20(address(a)), IERC20(address(b)), 41e18, 42e6, false, "");
        vm.stopPrank();
        assertEq(a.balanceOf(address(index)), 940e18);
    }

    function testExpiredProposalCanBeClearedWithoutReviewer() public {
        mandate.queue(proposal(), block.timestamp + 2 hours);
        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(alice);
        mandate.clearExpired();
        assertEq(mandate.pending(), bytes32(0));
        mandate.queue(proposal(), block.timestamp + 2 hours);
        assertEq(mandate.proposalNonce(), 2);
    }
}
