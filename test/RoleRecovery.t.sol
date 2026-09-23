// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MonthlyMandateFixture} from "./MonthlyMandate.t.sol";
import {MonthlyMandate} from "../src/MonthlyMandate.sol";
import {IFolio} from "folio/interfaces/IFolio.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RoleRecoveryTest is MonthlyMandateFixture {
    address internal replacement = address(0x12345);

    function requestProposer() internal returns (uint256 nonce) {
        vm.prank(reviewer);
        mandate.requestRoleChange(0, replacement);
        return mandate.roleChangeNonce();
    }

    function confirmProposer() internal returns (uint256 nonce) {
        nonce = requestProposer();
        vm.prank(guardian);
        mandate.confirmRoleChange(0, nonce);
    }

    function testRecoveryRequiresOtherTwoHoldersAndReplacementAcceptance() public {
        vm.expectRevert(MonthlyMandate.Unauthorized.selector);
        mandate.requestRoleChange(0, replacement);
        vm.prank(alice);
        vm.expectRevert(MonthlyMandate.Unauthorized.selector);
        mandate.requestRoleChange(0, replacement);
        uint256 nonce = requestProposer();
        vm.prank(reviewer);
        vm.expectRevert(MonthlyMandate.Unauthorized.selector);
        mandate.confirmRoleChange(0, nonce);
        vm.expectRevert(MonthlyMandate.Unauthorized.selector);
        mandate.confirmRoleChange(0, nonce);
        vm.prank(replacement);
        vm.expectRevert(MonthlyMandate.TooEarly.selector);
        mandate.acceptRoleChange(0, nonce);
        vm.prank(guardian);
        mandate.confirmRoleChange(0, nonce);
        vm.prank(replacement);
        vm.expectRevert(MonthlyMandate.TooEarly.selector);
        mandate.acceptRoleChange(0, nonce);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(MonthlyMandate.Unauthorized.selector);
        mandate.acceptRoleChange(0, nonce);
        vm.prank(replacement);
        mandate.acceptRoleChange(0, nonce);
        (address proposer,,,,,,,) = mandate.config();
        assertEq(proposer, replacement);
        assertEq(mandate.authorityVersion(), 2);
    }

    function testChangeInvalidatesApprovedProposalAndOldProposer() public {
        uint256 nonce = confirmProposer();
        vm.warp(block.timestamp + 7 days);
        IFolio.TokenRebalanceParams[] memory tokens = ready();
        bytes32 oldHash = mandate.pending();
        uint256 proposalNonce = mandate.proposalNonce();
        uint256 expiry = mandate.expiresAt();
        vm.prank(replacement);
        mandate.acceptRoleChange(0, nonce);
        assertEq(mandate.pending(), bytes32(0));
        assertEq(mandate.approvedUntil(), 0);
        assertTrue(mandate.proposalHash(tokens, proposalNonce, expiry) != oldHash);
        vm.expectRevert(MonthlyMandate.WrongState.selector);
        mandate.execute(tokens);
        vm.expectRevert(MonthlyMandate.Unauthorized.selector);
        mandate.queue(tokens, block.timestamp + 2 hours);
        vm.prank(replacement);
        mandate.queue(tokens, block.timestamp + 2 hours);
        assertEq(mandate.proposalNonce(), proposalNonce + 1);
    }

    function testRecoveryClosesAuctionWithoutResettingBudgetOrEngineAuthority() public {
        uint256 nonce = confirmProposer();
        vm.warp(block.timestamp + 7 days);
        uint256 auctionId = mandate.execute(ready());
        uint256 next = mandate.nextExecutionAt();
        uint256 mintFee = index.mintFee();
        vm.prank(replacement);
        mandate.acceptRoleChange(0, nonce);
        assertEq(mandate.activeAuctionPlusOne(), 0);
        assertEq(mandate.nextExecutionAt(), next);
        assertEq(index.mintFee(), mintFee);
        assertEq(index.getRoleMemberCount(bytes32(0)), 1);
        assertEq(index.getRoleMember(bytes32(0), 0), address(mandate));
        assertFalse(index.hasRole(bytes32(0), replacement));
        vm.warp(block.timestamp + 31);
        vm.expectRevert();
        index.getBid(auctionId, IERC20(address(a)), IERC20(address(b)), 1e18);
        vm.prank(replacement);
        mandate.queue(proposal(), block.timestamp + 2 hours);
        vm.warp(block.timestamp + 1 hours);
        bytes32 hash = mandate.pending();
        vm.prank(reviewer);
        mandate.approve(hash, block.timestamp + 60);
        vm.expectRevert(MonthlyMandate.TooEarly.selector);
        mandate.execute(proposal());
    }

    function testReplacingRequestCannotReuseConfirmationOrNonce() public {
        uint256 nonce = confirmProposer();
        vm.warp(block.timestamp + 7 days);
        vm.prank(guardian);
        mandate.requestRoleChange(0, replacement);
        uint256 freshNonce = mandate.roleChangeNonce();
        vm.prank(replacement);
        vm.expectRevert(MonthlyMandate.WrongState.selector);
        mandate.acceptRoleChange(0, nonce);
        vm.prank(replacement);
        vm.expectRevert(MonthlyMandate.TooEarly.selector);
        mandate.acceptRoleChange(0, freshNonce);
        vm.prank(reviewer);
        mandate.confirmRoleChange(0, freshNonce);
        vm.prank(replacement);
        vm.expectRevert(MonthlyMandate.TooEarly.selector);
        mandate.acceptRoleChange(0, freshNonce);
    }

    function testSurvivingHolderCanCancelButTargetCannotVetoRecovery() public {
        uint256 nonce = confirmProposer();
        vm.expectRevert(MonthlyMandate.Unauthorized.selector);
        mandate.cancelRoleChange(0, nonce);
        vm.prank(reviewer);
        mandate.cancelRoleChange(0, nonce);
        vm.warp(block.timestamp + 7 days);
        vm.prank(replacement);
        vm.expectRevert(MonthlyMandate.WrongState.selector);
        mandate.acceptRoleChange(0, nonce);
    }

    function testRequestsAndAcceptanceExpire() public {
        uint256 nonce = requestProposer();
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(guardian);
        vm.expectRevert(MonthlyMandate.WrongState.selector);
        mandate.confirmRoleChange(0, nonce);
        nonce = confirmProposer();
        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(replacement);
        vm.expectRevert(MonthlyMandate.WrongState.selector);
        mandate.acceptRoleChange(0, nonce);
    }

    function testAuthorityChangeInvalidatesOtherPreviouslyAuthorizedRequests() public {
        uint256 first = confirmProposer();
        mandate.requestRoleChange(1, address(0x98765));
        uint256 second = mandate.roleChangeNonce();
        vm.prank(guardian);
        mandate.confirmRoleChange(1, second);
        vm.warp(block.timestamp + 7 days);
        vm.prank(replacement);
        mandate.acceptRoleChange(0, first);
        vm.prank(address(0x98765));
        vm.expectRevert(MonthlyMandate.WrongState.selector);
        mandate.acceptRoleChange(1, second);
    }

    function testCannotMergeRolesOrNominateUnusableInternalAddress() public {
        address[6] memory invalid = [address(0), address(this), reviewer, guardian, address(mandate), address(index)];
        for (uint256 i; i < invalid.length; ++i) {
            vm.prank(reviewer);
            vm.expectRevert(MonthlyMandate.InvalidPolicy.selector);
            mandate.requestRoleChange(0, invalid[i]);
        }
        vm.prank(reviewer);
        vm.expectRevert(MonthlyMandate.InvalidPolicy.selector);
        mandate.requestRoleChange(3, replacement);
    }

    function testEachRoleCanRecoverWithTheOtherTwoHolders() public {
        // Sequential replacements also exercise authority-version advancement and new approvers.
        uint256 nonce = confirmProposer();
        vm.warp(block.timestamp + 7 days);
        vm.prank(replacement);
        mandate.acceptRoleChange(0, nonce);
        address newReviewer = address(0x98765);
        vm.prank(replacement);
        mandate.requestRoleChange(1, newReviewer);
        nonce = mandate.roleChangeNonce();
        vm.prank(guardian);
        mandate.confirmRoleChange(1, nonce);
        vm.warp(block.timestamp + 7 days);
        vm.prank(newReviewer);
        mandate.acceptRoleChange(1, nonce);
        vm.prank(reviewer);
        vm.expectRevert(MonthlyMandate.Unauthorized.selector);
        mandate.cancel();
        vm.prank(newReviewer);
        mandate.requestRoleChange(2, alice);
        nonce = mandate.roleChangeNonce();
        vm.prank(replacement);
        mandate.confirmRoleChange(2, nonce);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        mandate.acceptRoleChange(2, nonce);
        (address p, address r, address g,,,,,) = mandate.config();
        assertEq(p, replacement);
        assertEq(r, newReviewer);
        assertEq(g, alice);
        assertEq(mandate.authorityVersion(), 4);
        vm.prank(guardian);
        vm.expectRevert(MonthlyMandate.Unauthorized.selector);
        mandate.cancel();
    }

    function testSharedRolesAreAllowedAndRecoveryHonorsLongerNotice() public {
        MonthlyMandate.Config memory cfg = MonthlyMandate.Config({
            proposer: address(this), reviewer: reviewer, guardian: reviewer,
            notice: 10 days, interval: 30 days, auctionLength: 300,
            maxPriceSpreadBps: 100, methodologyHash: keccak256("recovery notice")
        });
        MonthlyMandate.TokenRule[] memory rules = new MonthlyMandate.TokenRule[](2);
        rules[0] = MonthlyMandate.TokenRule(address(a), 0, 2e27, 100e18);
        rules[1] = MonthlyMandate.TokenRule(address(b), 0, 2e15, 100e6);
        // One wallet reviewing and guarding is allowed; so is the creator guarding its own index.
        new MonthlyMandate(index, cfg, rules);
        cfg.guardian = address(this);
        new MonthlyMandate(index, cfg, rules);
        cfg.guardian = guardian;
        MonthlyMandate longer = new MonthlyMandate(index, cfg, rules);
        assertEq(longer.roleChangeDelay(), 10 days);
        assertEq(mandate.roleChangeDelay(), 7 days);
    }
}
