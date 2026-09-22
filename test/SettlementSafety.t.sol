// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MonthlyMandateFixture} from "./MonthlyMandate.t.sol";
import {Folio} from "folio/Folio.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBidderCallee} from "folio/interfaces/IBidderCallee.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFolio} from "folio/interfaces/IFolio.sol";

contract AdversarialBidder is IBidderCallee {
    Folio immutable index;
    bool public mintBlocked;
    bool public redeemBlocked;
    bool public recursiveBidBlocked;
    uint256 private auction;
    IERC20 private sell;
    IERC20 private buy;
    bool private underpay;

    constructor(Folio index_) {index=index_;}

    function fill(uint256 auction_, IERC20 sell_, IERC20 buy_, bool underpay_) external {
        auction=auction_;sell=sell_;buy=buy_;underpay=underpay_;
        index.bid(auction,sell,buy,10e18,11e6,true,"");
    }

    function bidCallback(address buyToken, uint256 amount, bytes calldata) external {
        require(msg.sender==address(index));
        try index.mint(1e18,address(this),0) {} catch (bytes memory reason) {mintBlocked=bytes4(reason)==bytes4(keccak256("ReentrancyGuardReentrantCall()"));}
        address[] memory assets=new address[](0);
        uint256[] memory minimums=new uint256[](0);
        try index.redeem(1e18,address(this),assets,minimums) {} catch (bytes memory reason) {redeemBlocked=bytes4(reason)==bytes4(keccak256("ReentrancyGuardReentrantCall()"));}
        try index.bid(auction,sell,buy,1e18,2e6,true,"") {} catch (bytes memory reason) {recursiveBidBlocked=bytes4(reason)==bytes4(keccak256("ReentrancyGuardReentrantCall()"));}
        IERC20(buyToken).transfer(address(index),underpay?amount-1:amount);
    }
}

contract SettlementSafetyTest is MonthlyMandateFixture {
    function testOneWeiGrossMintCannotConsumeBackingForZeroNetShares() public {
        a.approve(address(index), type(uint256).max);
        b.approve(address(index), type(uint256).max);
        uint256 beforeA = a.balanceOf(address(this));
        uint256 beforeB = b.balanceOf(address(this));
        uint256 supply = index.totalSupply();
        vm.expectRevert(IFolio.Folio__InsufficientSharesOut.selector);
        index.mint(1, alice, 0);
        assertEq(a.balanceOf(address(this)), beforeA);
        assertEq(b.balanceOf(address(this)), beforeB);
        assertEq(index.totalSupply(), supply);
        assertEq(index.balanceOf(alice), 0);
    }

    function testTinyMixedDecimalRoundTripsCannotExtractBacking() public {
        uint256[7] memory sizes = [uint256(2), 3, 3333, 3334, 1e12 - 1, 1e12, 1e12 + 1];
        for (uint256 i; i < sizes.length; ++i) _roundTripWithoutExtraction(sizes[i]);
    }

    function testNearZeroSupplyRetainsRoundedBackingAndSafeProportionalIssuance() public {
        uint256 shares = index.totalSupply() - 1;
        (address[] memory assets, uint256[] memory amounts) = index.toAssets(shares, Math.Rounding.Floor);
        index.redeem(shares, address(this), assets, amounts);
        assertEq(index.totalSupply(), 1);
        assertEq(index.balanceOf(address(this)), 1);
        assertEq(a.balanceOf(address(index)), 1);
        assertEq(b.balanceOf(address(index)), 1);
        _roundTripWithoutExtraction(2);
        _roundTripWithoutExtraction(1e18);
        assertEq(index.balanceOf(address(this)), 1);
    }

    function _roundTripWithoutExtraction(uint256 grossShares) private {
        uint256 beforeA = a.balanceOf(alice);
        uint256 beforeB = b.balanceOf(alice);
        uint256 backingA = a.balanceOf(address(index));
        uint256 backingB = b.balanceOf(address(index));
        (, uint256[] memory needed) = index.toAssets(grossShares, Math.Rounding.Ceil);
        a.mint(alice, needed[0]);
        b.mint(alice, needed[1]);
        vm.startPrank(alice);
        a.approve(address(index), needed[0]);
        b.approve(address(index), needed[1]);
        /*
         * The mint fee, read from the index rather than assumed.
         *
         * This was `(gross * 3 + 9999) / 10000`, Folio's 3 bps minimum, which was the whole fee
         * while ours was zero. It is 135 bps now and a hardcoded 3 made these tests fail in a way
         * that looked like a backing bug and was a stale constant.
         */
        uint256 netShares = grossShares - (grossShares * index.mintFee() + 1e18 - 1) / 1e18;
        index.mint(grossShares, alice, netShares);
        assertEq(index.balanceOf(alice), netShares);
        (address[] memory assets, uint256[] memory amounts) = index.toAssets(netShares, Math.Rounding.Floor);
        index.redeem(netShares, alice, assets, amounts);
        vm.stopPrank();
        assertEq(index.balanceOf(alice), 0);
        assertLe(a.balanceOf(alice) - beforeA, needed[0]);
        assertLe(b.balanceOf(alice) - beforeB, needed[1]);
        assertGe(a.balanceOf(address(index)), backingA);
        assertGe(b.balanceOf(address(index)), backingB);
    }

    function testMintSecondTransferFailureRollsBackBackingAllowanceSharesAndFees() public {
        for (uint256 mode; mode < 2; ++mode) {
            (address[] memory assets, uint256[] memory needed) = index.toAssets(10e18, Math.Rounding.Ceil);
            assertEq(assets[0], address(a));
            assertEq(assets[1], address(b));
            a.mint(alice, needed[0]);
            b.mint(alice, needed[1]);
            vm.startPrank(alice);
            a.approve(address(index), needed[0]);
            b.approve(address(index), needed[1]);
            vm.stopPrank();
            uint256 backingA = a.balanceOf(address(index));
            uint256 backingB = b.balanceOf(address(index));
            uint256 supply = index.totalSupply();
            uint256 shares = index.balanceOf(alice);
            uint256 pendingFees = index.getPendingFeeShares();
            bytes memory callData = abi.encodeCall(IERC20.transferFrom, (alice, address(index), needed[1]));
            bytes memory failure = mode == 0
                ? abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(b))
                : abi.encodeWithSignature("Error(string)", "issuer paused");
            if (mode == 0) vm.mockCall(address(b), callData, abi.encode(false));
            else vm.mockCallRevert(address(b), callData, failure);
            vm.prank(alice);
            vm.expectRevert(failure);
            index.mint(10e18, alice, 9e18);
            assertEq(a.balanceOf(address(index)), backingA);
            assertEq(b.balanceOf(address(index)), backingB);
            assertEq(a.balanceOf(alice), needed[0]);
            assertEq(b.balanceOf(alice), needed[1]);
            assertEq(a.allowance(alice, address(index)), needed[0]);
            assertEq(index.totalSupply(), supply);
            assertEq(index.balanceOf(alice), shares);
            assertEq(index.getPendingFeeShares(), pendingFees);
            vm.clearMockedCalls();
            vm.prank(alice);
            index.mint(10e18, alice, 9e18);
            assertGt(index.balanceOf(alice), shares);
            assertEq(a.balanceOf(alice), 0);
            assertEq(b.balanceOf(alice), 0);
        }
    }

    function testRedemptionSecondTransferFailureRestoresBurnAndEarlierAssetPayout() public {
        index.transfer(alice, 200e18);
        for (uint256 mode; mode < 2; ++mode) {
            (address[] memory assets, uint256[] memory amounts) = index.toAssets(100e18, Math.Rounding.Floor);
            assertEq(assets[1], address(b));
            uint256 backingA = a.balanceOf(address(index));
            uint256 backingB = b.balanceOf(address(index));
            uint256 aliceA = a.balanceOf(alice);
            uint256 aliceB = b.balanceOf(alice);
            uint256 supply = index.totalSupply();
            uint256 shares = index.balanceOf(alice);
            bytes memory callData = abi.encodeCall(IERC20.transfer, (alice, amounts[1]));
            bytes memory failure = mode == 0
                ? abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(b))
                : abi.encodeWithSignature("Error(string)", "receiver blocked");
            if (mode == 0) vm.mockCall(address(b), callData, abi.encode(false));
            else vm.mockCallRevert(address(b), callData, failure);
            vm.prank(alice);
            vm.expectRevert(failure);
            index.redeem(100e18, alice, assets, amounts);
            assertEq(index.totalSupply(), supply);
            assertEq(index.balanceOf(alice), shares);
            assertEq(a.balanceOf(address(index)), backingA);
            assertEq(b.balanceOf(address(index)), backingB);
            assertEq(a.balanceOf(alice), aliceA);
            assertEq(b.balanceOf(alice), aliceB);
            vm.clearMockedCalls();
            vm.prank(alice);
            index.redeem(100e18, alice, assets, amounts);
            assertEq(index.balanceOf(alice), shares - 100e18);
            assertEq(a.balanceOf(alice), aliceA + amounts[0]);
            assertEq(b.balanceOf(alice), aliceB + amounts[1]);
        }
    }

    function testCallbackCannotReenterClaimsOrSettlementAndMustPayActualConsideration() public {
        uint256 auction=mandate.execute(ready());
        vm.warp(block.timestamp+31);
        AdversarialBidder bidder=new AdversarialBidder(index);
        b.mint(address(bidder),100e6);
        uint256 backingA=a.balanceOf(address(index));
        uint256 backingB=b.balanceOf(address(index));
        bidder.fill(auction,IERC20(address(a)),IERC20(address(b)),false);
        assertTrue(bidder.mintBlocked());
        assertTrue(bidder.redeemBlocked());
        assertTrue(bidder.recursiveBidBlocked());
        assertEq(a.balanceOf(address(index)),backingA-10e18);
        assertGt(b.balanceOf(address(index)),backingB+9e6);
        assertEq(a.balanceOf(address(bidder)),10e18);
    }

    function testUnderpaidCallbackRollsBackEveryAssetMovement() public {
        uint256 auction=mandate.execute(ready());
        vm.warp(block.timestamp+31);
        AdversarialBidder bidder=new AdversarialBidder(index);
        b.mint(address(bidder),100e6);
        uint256 backingA=a.balanceOf(address(index));
        uint256 backingB=b.balanceOf(address(index));
        uint256 supply=index.totalSupply();
        vm.expectRevert();
        bidder.fill(auction,IERC20(address(a)),IERC20(address(b)),true);
        assertEq(a.balanceOf(address(index)),backingA);
        assertEq(b.balanceOf(address(index)),backingB);
        assertEq(index.totalSupply(),supply);
        assertEq(a.balanceOf(address(bidder)),0);
        assertEq(b.balanceOf(address(bidder)),100e6);
    }

    function testFullRedemptionIsTerminalAndNoActorCanRemoveBasketForFreeIssuance() public {
        vm.expectRevert();
        index.removeFromBasket(IERC20(address(a)));
        vm.prank(reviewer);
        vm.expectRevert();
        index.removeFromBasket(IERC20(address(b)));
        (address[] memory assets,uint256[] memory amounts)=index.toAssets(index.totalSupply(),Math.Rounding.Floor);
        index.redeem(index.totalSupply(),address(this),assets,amounts);
        assertEq(index.totalSupply(),0);
        vm.expectRevert();
        index.mint(1e18,alice,0);
        assertEq(index.balanceOf(alice),0);
    }
}
