// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Folio} from "folio/Folio.sol";
import {IndexFixture} from "./IndexLifecycle.t.sol";
import {IndexFactoryBase} from "../src/IndexFactoryBase.sol";
import {FixedFeeRegistry, MintSplit} from "../src/FixedFeeRegistry.sol";

/// @notice What the protocol, the creator and holders actually earn on a mint.
/// @dev    Uses the production registry rather than the fixture's, because the split is the thing
///         under test and the fixture's one-third portion is not the one we deploy.
contract MintFeeTest is IndexFixture {
    function setUp() public override {
        super.setUp();
        factory = new IndexFactoryBase(address(new Folio()),
            address(new FixedFeeRegistry(address(0xFEE), MintSplit.PROTOCOL_PORTION, 0)));
        a.approve(address(factory), type(uint256).max);
        b.approve(address(factory), type(uint256).max);
        index = factory.create(seed());
    }

    /// @dev Pinned rather than assumed. A mint fee that silently reads zero costs everyone every
    ///      mint and looks exactly like one that is working.
    function testMintSplitsTwentyFifteenFifteen() public {
        assertEq(index.mintFee(), 0.005e18, "0.50% total on a mint");
        assertEq(index.folioFeeForSelf(), 0.5e18, "half of the non-protocol part to holders");

        uint256 shares = 1_000e18;
        mintAs(alice, shares);

        uint256 protocol = index.daoPendingFeeShares();
        uint256 creator = index.feeRecipientsPendingFeeShares();
        uint256 holders = index.folioPendingMintFeeShares();
        assertEq(index.balanceOf(alice) + protocol + creator + holders, shares, "every share accounted for");
        assertApproxEqAbs(protocol * 10_000 / shares, uint256(20), 1, "20 bps to the protocol");
        assertApproxEqAbs(holders * 10_000 / shares, uint256(15), 1, "15 bps to holders");
        assertApproxEqAbs(creator * 10_000 / shares, uint256(15), 1, "15 bps to the creator");
    }

    /// @dev The holders' part is not paid to anybody. Once Folio hands it out, a share that did
    ///      nothing redeems for more of the basket than it did before the mint.
    function testHoldersPartRaisesBacking() public {
        (, uint256[] memory before_) = index.toAssets(100e18, Math.Rounding.Floor);
        mintAs(alice, 1_000e18);
        vm.warp(block.timestamp + 1 days + 10 minutes);
        index.poke();
        index.distributeFees();
        assertEq(index.folioPendingMintFeeShares(), 0, "handed out");
        (, uint256[] memory after_) = index.toAssets(100e18, Math.Rounding.Floor);
        assertGt(after_[0], before_[0], "each share is backed by more");
        assertGt(after_[1], before_[1]);
    }

    /// @dev The fee is the tracking band, so it is worth pinning what band we chose.
    function testMintFeeIsTheTrackingBand() public view {
        // A share can trade this far above NAV, plus the pool fee, before minting to sell into it pays.
        assertLe(index.mintFee(), 0.01e18, "a wider band than 1% would undo the point of lowering it");
    }

    function mintAs(address who, uint256 shares) internal {
        (, uint256[] memory needed) = index.toAssets(shares, Math.Rounding.Ceil);
        a.mint(who, needed[0]);
        b.mint(who, needed[1]);
        vm.startPrank(who);
        IERC20(address(a)).approve(address(index), needed[0]);
        IERC20(address(b)).approve(address(index), needed[1]);
        index.mint(shares, who, 0);
        vm.stopPrank();
    }
}
