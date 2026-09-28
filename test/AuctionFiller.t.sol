// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {refPrices} from "./FreshPrices.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IndexFixture, TestAsset} from "./IndexLifecycle.t.sol";
import {Folio} from "folio/Folio.sol";
import {IFolio} from "folio/interfaces/IFolio.sol";
import {MonthlyMandate} from "../src/MonthlyMandate.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {FixedFeeRegistry} from "../src/FixedFeeRegistry.sol";
import {AuctionFiller} from "../src/AuctionFiller.sol";

/// A router plan reduced to its effect: spend `spend` of `tokenIn` from what the router holds, deliver
/// `amountOut` of `tokenOut` to the caller, and hand back whatever of `tokenIn` is left.
contract PlanRouter {
    function execute(bytes calldata commands, bytes[] calldata, uint256) external payable {
        (address tokenIn, address tokenOut, uint256 spend, uint256 amountOut) = abi.decode(commands, (address, address, uint256, uint256));
        uint256 held = IERC20(tokenIn).balanceOf(address(this));
        require(held >= spend, "router: not enough in");
        TestAsset(tokenOut).mint(msg.sender, amountOut);
        IERC20(tokenIn).transfer(msg.sender, held - spend);
    }
}

/// The filler against a real Folio and a real mandate: a rebalance that sells A and buys B.
contract AuctionFillerTest is IndexFixture {
    IndexFactory internal f;
    Folio internal idx;
    MonthlyMandate internal m;
    TestAsset internal usdg;
    PlanRouter internal router;
    AuctionFiller internal filler;
    address internal reviewer = address(0xB0B);
    address internal keeper = address(0x4EE9);
    uint256 internal auctionId;
    uint256 internal opened;
    uint256 internal closes;

    function setUp() public override {
        super.setUp();
        f = new IndexFactory(address(new Folio()), address(new FixedFeeRegistry(address(0xFEE), 0.2e18, 0)));
        a.approve(address(f), type(uint256).max);
        b.approve(address(f), type(uint256).max);
        MonthlyMandate.TokenRule[] memory r = new MonthlyMandate.TokenRule[](2);
        r[0] = MonthlyMandate.TokenRule(address(a), 0, 2e27, 1_000e18);
        r[1] = MonthlyMandate.TokenRule(address(b), 0, 2e15, 1_000e6);
        (idx, m) = f.createManaged(seed(), MonthlyMandate.Config({proposer: address(this), reviewer: reviewer,
            guardian: address(0xCAFE), notice: 1 hours, interval: 30 days, auctionLength: 300, maxPriceSpreadBps: 100,
            methodologyHash: keccak256("filler")}), r);
        usdg = new TestAsset("USDG", 6);
        router = new PlanRouter();
        filler = new AuctionFiller(address(router), address(f), address(usdg), address(new TestAsset("WETH", 18)));

        // One share holds 1 A and 1 B, both worth $1. Target 0.9 A and 1.1 B: sell 100 A, buy 100 B.
        IFolio.TokenRebalanceParams[] memory t = new IFolio.TokenRebalanceParams[](2);
        t[0] = IFolio.TokenRebalanceParams(address(a), IFolio.WeightRange(0.9e27, 0.9e27, 0.9e27), IFolio.PriceRange(1e27, 1.01e27), 1_000e18, true);
        t[1] = IFolio.TokenRebalanceParams(address(b), IFolio.WeightRange(1.1e15, 1.1e15, 1.1e15), IFolio.PriceRange(1e39, 1.01e39), 1_000e6, true);
        m.queue(t, block.timestamp + 2 hours);
        vm.warp(block.timestamp + 1 hours);
        bytes32 hash = m.pending();                                  // read first: vm.prank is spent by the next call of any kind
        vm.prank(reviewer);
        m.approve(t, refPrices(t), block.timestamp + 60);
        auctionId = m.execute(t);
        // The auction opens after Folio's 30-second warmup and runs its length from there.
        (, uint256 start, uint256 end) = idx.auctions(auctionId);
        assertEq(start, block.timestamp + 30);
        assertEq(end, start + 300);
        opened = start;
        closes = end;
    }

    /// Plans for selling `sold` A into USDG at $1, then buying `owed` B at $1 plus `costBps`.
    function plan(uint256 sold, uint256 owed, uint256 costBps) internal view returns (AuctionFiller.Plan memory p) {
        uint256 proceeds = sold / 1e12;                              // 18-decimal A to 6-decimal USDG at $1
        uint256 spend = owed + owed * costBps / 10_000;
        p.sellToken = address(a);
        p.sellCommands = abi.encode(address(a), address(usdg), sold, proceeds);
        p.sellInputs = new bytes[](0);
        p.buyPay = proceeds;
        p.buyCommands = abi.encode(address(usdg), address(b), spend, owed);
        p.buyInputs = new bytes[](0);
        p.deadline = block.timestamp + 60;
    }

    function testLateInTheAuctionTheFillPaysTheIndexAndTheKeeperKeepsTheMargin() public {
        vm.warp(closes);                                             // the auction's lowest price
        (uint256 sell, uint256 owed,) = idx.getBid(auctionId, IERC20(address(a)), IERC20(address(b)), type(uint256).max);
        assertGt(sell, 0);
        uint256 bBefore = b.balanceOf(address(idx));
        uint256 aBefore = a.balanceOf(address(idx));
        vm.prank(keeper);
        uint256 margin = filler.fill(address(idx), auctionId, address(b), sell, owed, plan(sell, owed, 0), 1);
        assertEq(b.balanceOf(address(idx)), bBefore + owed, "the index received what it was owed");
        assertEq(a.balanceOf(address(idx)), aBefore - sell, "and gave exactly what it sold");
        assertEq(usdg.balanceOf(keeper), margin, "the margin went to the keeper");
        assertGt(margin, 0);
        assertEq(usdg.balanceOf(address(filler)), 0, "the filler keeps nothing");
        assertEq(a.balanceOf(address(filler)) + b.balanceOf(address(filler)), 0);
    }

    function testEarlyInTheAuctionAFillAtMarketLosesSoItReverts() public {
        vm.warp(opened);                                             // the first second: the index's best price
        (uint256 sell, uint256 owed,) = idx.getBid(auctionId, IERC20(address(a)), IERC20(address(b)), type(uint256).max);
        // Buying what the index is owed costs more USDG than the sale raised.
        vm.prank(keeper);
        vm.expectRevert(bytes("router: not enough in"));
        filler.fill(address(idx), auctionId, address(b), sell, owed, plan(sell, owed, 0), 0);
    }

    function testTheKeepersMinimumIsEnforced() public {
        vm.warp(closes);
        (uint256 sell, uint256 owed,) = idx.getBid(auctionId, IERC20(address(a)), IERC20(address(b)), type(uint256).max);
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        uint256 margin = filler.fill(address(idx), auctionId, address(b), sell, owed, plan(sell, owed, 0), 0);
        vm.revertToState(snap);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AuctionFiller.TooLittle.selector, margin, margin + 1));
        filler.fill(address(idx), auctionId, address(b), sell, owed, plan(sell, owed, 0), margin + 1);
    }

    function testOnlyFactoryIndexesAndOnlyTheActiveIndexMayCallBack() public {
        AuctionFiller.Plan memory p = plan(1, 1, 0);
        vm.expectRevert(AuctionFiller.NotAnIndex.selector);
        filler.fill(address(0xBAD), auctionId, address(b), 1, 1, p, 0);
        vm.expectRevert(AuctionFiller.NotActive.selector);
        filler.bidCallback(address(b), 1, abi.encode(p));
        vm.prank(address(idx));
        vm.expectRevert(AuctionFiller.NotActive.selector);
        filler.bidCallback(address(b), 1, abi.encode(p));
    }

    function testAfterTheAuctionEndsNothingFills() public {
        vm.warp(closes + 1);
        vm.prank(keeper);
        vm.expectRevert(IFolio.Folio__AuctionNotOngoing.selector);
        filler.fill(address(idx), auctionId, address(b), 1e18, 1e6, plan(1e18, 1e6, 0), 0);
    }
}
