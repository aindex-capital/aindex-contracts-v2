// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {TestAsset} from "./IndexLifecycle.t.sol";
import {AixDistributor} from "../src/AixDistributor.sol";

/// Four-leaf trees built the way OpenZeppelin's StandardMerkleTree hashes them: double-hashed
/// abi.encode(address, uint256) leaves and sorted pairs.
contract AixDistributorTest is Test {
    TestAsset internal shares;
    AixDistributor internal d;
    address internal poster = address(0x9A7);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA201);
    address internal dave = address(0xDA7E);

    function setUp() public {
        shares = new TestAsset("AINDEX Strategy", 18);
        d = new AixDistributor(shares, poster);
    }

    function leaf(address account, uint256 cumulative) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, cumulative))));
    }

    /// Root of four leaves and the proof for each: [sibling, other pair's hash].
    function tree(address[4] memory who, uint256[4] memory amt) internal pure returns (bytes32 r, bytes32[][] memory proofs) {
        bytes32[4] memory l;
        for (uint256 i; i < 4; i++) l[i] = leaf(who[i], amt[i]);
        bytes32 left = Hashes.commutativeKeccak256(l[0], l[1]);
        bytes32 right = Hashes.commutativeKeccak256(l[2], l[3]);
        r = Hashes.commutativeKeccak256(left, right);
        proofs = new bytes32[][](4);
        for (uint256 i; i < 4; i++) {
            proofs[i] = new bytes32[](2);
            proofs[i][0] = l[i ^ 1];
            proofs[i][1] = i < 2 ? right : left;
        }
    }

    function fund(uint256 amount) internal {
        shares.mint(address(d), amount);
    }

    function post(bytes32 r, uint256 total) internal {
        vm.prank(poster);
        d.setRoot(r, total, "ipfs://day");
    }

    function everyone() internal view returns (address[4] memory) {
        return [alice, bob, carol, dave];
    }

    function test_happyPath() public {
        fund(100e18);
        (bytes32 r, bytes32[][] memory p) = tree(everyone(), [uint256(40e18), 30e18, 20e18, 10e18]);
        vm.expectEmit(true, true, false, true);
        emit AixDistributor.RootPosted(1, r, 100e18, "ipfs://day");
        post(r, 100e18);

        vm.expectEmit(true, true, false, true);
        emit AixDistributor.Claimed(alice, alice, 40e18, 40e18);
        vm.prank(alice);
        assertEq(d.claim(alice, 40e18, p[0]), 40e18);
        assertEq(shares.balanceOf(alice), 40e18);
        assertEq(d.claimed(alice), 40e18);
        assertEq(d.claimedTotal(), 40e18);

        vm.expectRevert(AixDistributor.NothingToClaim.selector);
        d.claim(alice, 40e18, p[0]);

        d.claim(dave, 10e18, p[3]);
        assertEq(shares.balanceOf(dave), 10e18);
        assertEq(shares.balanceOf(address(d)), 50e18);
    }

    function test_cumulativeAcrossDays() public {
        fund(100e18);
        (bytes32 r1, bytes32[][] memory p1) = tree(everyone(), [uint256(40e18), 30e18, 20e18, 10e18]);
        post(r1, 100e18);
        d.claim(alice, 40e18, p1[0]);
        d.claim(bob, 30e18, p1[1]);

        // Day 2: 60 more. Alice's total rises to 70, bob's to 45, carol never claimed day 1.
        fund(60e18);
        (bytes32 r2, bytes32[][] memory p2) = tree(everyone(), [uint256(70e18), 45e18, 30e18, 15e18]);
        post(r2, 160e18);
        assertEq(d.epoch(), 2);

        // Day 1's proof no longer works.
        vm.expectRevert(AixDistributor.InvalidProof.selector);
        d.claim(carol, 20e18, p1[2]);

        assertEq(d.claim(alice, 70e18, p2[0]), 30e18);
        assertEq(d.claim(bob, 45e18, p2[1]), 15e18);
        assertEq(d.claim(carol, 30e18, p2[2]), 30e18);
        assertEq(d.claim(dave, 15e18, p2[3]), 15e18);
        assertEq(shares.balanceOf(alice), 70e18);
        assertEq(d.claimedTotal(), 160e18);
        assertEq(shares.balanceOf(address(d)), 0);
    }

    function test_cannotOverAllocate() public {
        fund(100e18);
        (bytes32 r, bytes32[][] memory p) = tree(everyone(), [uint256(40e18), 30e18, 20e18, 10e18]);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(AixDistributor.OverAllocated.selector, 100e18 + 1, 100e18));
        d.setRoot(r, 100e18 + 1, "");

        // Claimed shares still count: after 40 is paid out, 100 is still the ceiling, not 60.
        post(r, 100e18);
        d.claim(alice, 40e18, p[0]);
        fund(10e18);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(AixDistributor.OverAllocated.selector, 111e18, 110e18));
        d.setRoot(r, 111e18, "");
        post(r, 110e18);

        // A root can never declare less than has already been paid.
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(AixDistributor.BelowClaimed.selector, 39e18, 40e18));
        d.setRoot(r, 39e18, "");
    }

    function test_claimsCappedByDeclaredTotal() public {
        // A tree whose leaves sum to more than the declared total cannot pay out past that total.
        fund(100e18);
        (bytes32 r, bytes32[][] memory p) = tree(everyone(), [uint256(60e18), 60e18, 0, 0]);
        post(r, 100e18);
        d.claim(alice, 60e18, p[0]);
        vm.expectRevert(AixDistributor.ExceedsAllocation.selector);
        d.claim(bob, 60e18, p[1]);
    }

    function test_wrongProof() public {
        fund(100e18);
        (bytes32 r, bytes32[][] memory p) = tree(everyone(), [uint256(40e18), 30e18, 20e18, 10e18]);
        post(r, 100e18);
        vm.expectRevert(AixDistributor.InvalidProof.selector);
        d.claim(alice, 41e18, p[0]);
        vm.expectRevert(AixDistributor.InvalidProof.selector);
        d.claim(alice, 40e18, p[1]);
        vm.expectRevert(AixDistributor.InvalidProof.selector);
        d.claim(bob, 40e18, p[0]);
        vm.expectRevert(AixDistributor.InvalidProof.selector);
        d.claim(alice, 40e18, new bytes32[](0));
    }

    function test_claimForSomeoneElsePaysThem() public {
        fund(100e18);
        (bytes32 r, bytes32[][] memory p) = tree(everyone(), [uint256(40e18), 30e18, 20e18, 10e18]);
        post(r, 100e18);
        address stranger = address(0x5712);
        vm.expectEmit(true, true, false, true);
        emit AixDistributor.Claimed(bob, stranger, 30e18, 30e18);
        vm.prank(stranger);
        d.claim(bob, 30e18, p[1]);
        assertEq(shares.balanceOf(bob), 30e18);
        assertEq(shares.balanceOf(stranger), 0);
    }

    function test_onlyPoster() public {
        fund(100e18);
        vm.expectRevert(AixDistributor.NotPoster.selector);
        d.setRoot(bytes32(uint256(1)), 1, "");
        vm.prank(alice);
        vm.expectRevert(AixDistributor.NotPoster.selector);
        d.setRoot(bytes32(uint256(1)), 1, "");
        assertEq(d.root(), bytes32(0));
    }

    /// A three-leaf tree built by the OpenZeppelin merkle-tree package (StandardMerkleTree.of, as the payout script
    /// builds it), so the contract and the script agree on leaves, pair order and odd-sized trees.
    function test_openZeppelinMerkleTreeVector() public {
        fund(90e18);
        post(0xbce09fd293d0a9e17126e0d3956995972697e29f48bbd98f84b501cd413d027c, 90e18);
        bytes32[] memory pa = new bytes32[](2);
        pa[0] = 0x2cf9cbd250495168d360ab56958f54c2eee5e0097598425f2cce48d28005d2e9;
        pa[1] = 0xdbc8d68761290d62b47df89d2e20deb2baa558d31a6ac6ef8ce6d5ff4eaa1b47;
        bytes32[] memory pc = new bytes32[](1);
        pc[0] = 0x0d5418a65a9c5b31f09b6ca0834e0f5296523421326d28c5aa2e7e3374a68bfe;
        assertEq(d.claim(alice, 40e18, pa), 40e18);
        assertEq(d.claim(carol, 20e18, pc), 20e18);
    }

    function test_claimManyPaysEveryAccountAndSkipsThePaid() public {
        fund(100e18);
        (bytes32 r, bytes32[][] memory p) = tree(everyone(), [uint256(40e18), 30e18, 20e18, 10e18]);
        post(r, 100e18);
        // Bob claims on his own first; the push must not revert on him.
        d.claim(bob, 30e18, p[1]);

        address[] memory who = new address[](4);
        uint256[] memory amt = new uint256[](4);
        (who[0], who[1], who[2], who[3]) = (alice, bob, carol, dave);
        (amt[0], amt[1], amt[2], amt[3]) = (40e18, 30e18, 20e18, 10e18);
        vm.prank(poster);
        assertEq(d.claimMany(who, amt, p), 70e18);
        assertEq(shares.balanceOf(alice), 40e18);
        assertEq(shares.balanceOf(bob), 30e18);
        assertEq(shares.balanceOf(carol), 20e18);
        assertEq(shares.balanceOf(dave), 10e18);
        assertEq(d.claimedTotal(), 100e18);

        // Run again: everyone is paid, so it pays nothing and does not revert.
        assertEq(d.claimMany(who, amt, p), 0);
    }

    function test_claimManyRevertsOnABadProof() public {
        fund(100e18);
        (bytes32 r, bytes32[][] memory p) = tree(everyone(), [uint256(40e18), 30e18, 20e18, 10e18]);
        post(r, 100e18);
        address[] memory who = new address[](2);
        uint256[] memory amt = new uint256[](2);
        bytes32[][] memory proofs = new bytes32[][](2);
        (who[0], who[1]) = (alice, bob);
        (amt[0], amt[1]) = (40e18, 31e18);
        (proofs[0], proofs[1]) = (p[0], p[1]);
        vm.expectRevert(AixDistributor.InvalidProof.selector);
        d.claimMany(who, amt, proofs);
        assertEq(shares.balanceOf(alice), 0, "the whole batch reverts");

        vm.expectRevert(AixDistributor.LengthMismatch.selector);
        d.claimMany(who, new uint256[](1), proofs);
    }

    /// Expiry: the next root lowers an account's total to what it was paid, and its unclaimed share
    /// goes to someone else. Nothing in the contract changes for that.
    function test_aRootMayRecycleAnUnclaimedAmount() public {
        fund(100e18);
        (bytes32 r1, bytes32[][] memory p1) = tree(everyone(), [uint256(40e18), 30e18, 20e18, 10e18]);
        post(r1, 100e18);
        d.claim(alice, 40e18, p1[0]);
        d.claim(bob, 30e18, p1[1]);
        d.claim(carol, 20e18, p1[2]);
        // Dave never claims his 10; it expires and goes to alice. Dave's total drops to what he was paid (0).
        (bytes32 r2, bytes32[][] memory p2) = tree(everyone(), [uint256(50e18), 30e18, 20e18, 0]);
        post(r2, 100e18);
        vm.expectRevert(AixDistributor.NothingToClaim.selector);
        d.claim(dave, 0, p2[3]);
        vm.expectRevert(AixDistributor.InvalidProof.selector);
        d.claim(dave, 10e18, p1[3]);
        assertEq(d.claim(alice, 50e18, p2[0]), 10e18);
        assertEq(shares.balanceOf(address(d)), 0);
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(AixDistributor.ZeroAddress.selector);
        new AixDistributor(shares, address(0));
    }
}
