// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {refPrices} from "./FreshPrices.sol";
import {IndexFixture, TestAsset} from "./IndexLifecycle.t.sol";
import {Folio} from "folio/Folio.sol";
import {IFolio} from "folio/interfaces/IFolio.sol";
import {MonthlyMandate} from "../src/MonthlyMandate.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {FixedFeeRegistry} from "../src/FixedFeeRegistry.sol";

/**
 * Growing what an index may hold: announce, wait, add. And shrinking it: sell out, then retire.
 */
contract TokenUniverseTest is IndexFixture {
    IndexFactory internal f;
    Folio internal idx;
    MonthlyMandate internal m;
    TestAsset internal c;
    address internal reviewerWallet = address(0xB0B);
    address internal guardianWallet = address(0xCAFE);

    function setUp() public override {
        super.setUp();
        f = new IndexFactory(address(new Folio()), address(new FixedFeeRegistry(address(0xFEE), 0.2e18, 0)));
        a.approve(address(f), type(uint256).max);
        b.approve(address(f), type(uint256).max);
        (idx, m) = f.createManaged(seed(), MonthlyMandate.Config({proposer: address(this), reviewer: reviewerWallet,
            guardian: guardianWallet, notice: 1 hours, interval: 30 days, auctionLength: 300, maxPriceSpreadBps: 100,
            methodologyHash: keccak256("universe")}), launchRules());
        c = new TestAsset("Next month's token", 18);
    }

    function launchRules() internal view returns (MonthlyMandate.TokenRule[] memory r) {
        r = new MonthlyMandate.TokenRule[](2);
        r[0] = MonthlyMandate.TokenRule(address(a), 0, 2e27, 100e18);
        r[1] = MonthlyMandate.TokenRule(address(b), 0, 2e15, 100e6);
    }

    function cRule() internal view returns (MonthlyMandate.TokenRule memory) {
        return MonthlyMandate.TokenRule(address(c), 0, 2e27, 100e18);
    }

    function testATokenIsAnnouncedWaitsAWeekThenJoins() public {
        assertEq(m.additionDelay(), 7 days, "at least a week, even with a one-hour rebalance notice");
        m.announceToken(cRule());
        assertEq(m.pendingTokens().length, 1);
        vm.expectRevert(MonthlyMandate.TooEarly.selector);
        m.addToken(address(c));
        vm.warp(block.timestamp + 7 days);
        m.addToken(address(c));
        assertEq(m.ruleCount(), 3);
        (address added,,,) = m.rules(2);
        assertEq(added, address(c));
        assertEq(m.pendingTokens().length, 0);
    }

    function testAnAddedTokenCanBeBoughtInTheNextRebalance() public {
        m.announceToken(cRule());
        vm.warp(block.timestamp + 7 days);
        m.addToken(address(c));
        IFolio.TokenRebalanceParams[] memory t = new IFolio.TokenRebalanceParams[](3);
        t[0] = IFolio.TokenRebalanceParams(address(a), IFolio.WeightRange(0.9e27, 0.9e27, 0.9e27), IFolio.PriceRange(1e27, 1.001e27), 100e18, true);
        t[1] = IFolio.TokenRebalanceParams(address(b), IFolio.WeightRange(1e15, 1e15, 1e15), IFolio.PriceRange(1e39, 1.001e39), 100e6, true);
        t[2] = IFolio.TokenRebalanceParams(address(c), IFolio.WeightRange(0.1e27, 0.1e27, 0.1e27), IFolio.PriceRange(1e27, 1.001e27), 100e18, true);
        m.queue(t, block.timestamp + 2 hours);
        vm.warp(block.timestamp + 1 hours);
        bytes32 hash = m.pending();
        vm.prank(reviewerWallet);
        m.approve(t, refPrices(t), block.timestamp + 60);
        m.execute(t);
        (address[] memory basket,) = idx.totalAssets();
        bool present;
        for (uint256 i; i < basket.length; ++i) if (basket[i] == address(c)) present = true;
        assertTrue(present, "the rebalance brought the new token into the basket");
    }

    function testALongerIndexNoticeMakesTheWaitLonger() public {
        (, MonthlyMandate slow) = f.createManaged(seed(), MonthlyMandate.Config({proposer: address(this), reviewer: address(this),
            guardian: address(this), notice: 10 days, interval: 30 days, auctionLength: 300, maxPriceSpreadBps: 100,
            methodologyHash: keccak256("slow")}), launchRules());
        assertEq(slow.additionDelay(), 10 days);
    }

    function testOnlyTheProposerGrowsTheUniverseAndAnyRoleCanCancel() public {
        vm.prank(reviewerWallet);
        vm.expectRevert(MonthlyMandate.Unauthorized.selector);
        m.announceToken(cRule());
        m.announceToken(cRule());

        vm.prank(address(0xBAD));
        vm.expectRevert(MonthlyMandate.Unauthorized.selector);
        m.cancelToken(address(c));
        vm.prank(guardianWallet);
        m.cancelToken(address(c));
        assertEq(m.pendingTokens().length, 0);

        m.announceToken(cRule());
        vm.warp(block.timestamp + 7 days);
        vm.prank(reviewerWallet);
        vm.expectRevert(MonthlyMandate.Unauthorized.selector);
        m.addToken(address(c));
    }

    function testAnAnnouncementMustBeANewSafeRule() public {
        MonthlyMandate.TokenRule memory r = cRule();
        r.token = address(a);
        vm.expectRevert(MonthlyMandate.InvalidPolicy.selector);
        m.announceToken(r);                                   // already in the universe
        r = cRule(); r.token = address(idx);
        vm.expectRevert(MonthlyMandate.InvalidPolicy.selector);
        m.announceToken(r);                                   // the index itself
        r = cRule(); r.minWeight = 1;
        vm.expectRevert(MonthlyMandate.InvalidPolicy.selector);
        m.announceToken(r);                                   // adding must never force a purchase
        r = cRule(); r.maxTradeAmount = 0;
        vm.expectRevert(MonthlyMandate.InvalidPolicy.selector);
        m.announceToken(r);
        m.announceToken(cRule());
        vm.expectRevert(MonthlyMandate.InvalidPolicy.selector);
        m.announceToken(cRule());                             // already announced
    }

    function testTheUniverseStopsAtSixteen() public {
        for (uint256 i; i < 14; ++i) {
            TestAsset t = new TestAsset("filler", 18);
            m.announceToken(MonthlyMandate.TokenRule(address(t), 0, 1e27, 1e18));
        }
        vm.expectRevert(MonthlyMandate.InvalidPolicy.selector);
        m.announceToken(cRule());
    }

    function testNothingJoinsWhileARebalanceIsPending() public {
        m.announceToken(cRule());
        vm.warp(block.timestamp + 7 days);
        IFolio.TokenRebalanceParams[] memory t = new IFolio.TokenRebalanceParams[](2);
        t[0] = IFolio.TokenRebalanceParams(address(a), IFolio.WeightRange(1e27, 1e27, 1e27), IFolio.PriceRange(1e27, 1.001e27), 100e18, true);
        t[1] = IFolio.TokenRebalanceParams(address(b), IFolio.WeightRange(1e15, 1e15, 1e15), IFolio.PriceRange(1e39, 1.001e39), 100e6, true);
        m.queue(t, block.timestamp + 2 hours);
        vm.expectRevert(MonthlyMandate.WrongState.selector);
        m.addToken(address(c));
    }

    function testRetiringFreesASlotOnlyForATokenNoLongerHeld() public {
        vm.expectRevert(MonthlyMandate.InvalidPolicy.selector);
        m.retireToken(address(a));                            // the universe never drops below two
        m.announceToken(cRule());
        vm.warp(block.timestamp + 7 days);
        m.addToken(address(c));
        vm.expectRevert(MonthlyMandate.WrongState.selector);
        m.retireToken(address(a));                            // still held
        m.retireToken(address(c));                            // never bought, so not held
        assertEq(m.ruleCount(), 2);
    }
}
