// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IndexFixture} from "./IndexLifecycle.t.sol";
import {MintSplit} from "../src/FixedFeeRegistry.sol";

/// @notice What the protocol and the creator actually earn on a mint.
contract MintFeeTest is IndexFixture {
    /// @dev Pinned rather than assumed. A mint fee that silently reads zero costs the protocol
    ///      every mint and looks exactly like one that is working.
    function testMintChargesOneHundredAndThirtyFiveBasisPoints() public view {
        assertEq(index.mintFee(), 0.0135e18, "1.35% total on a mint");
        assertEq(MintSplit.PROTOCOL_PORTION_FOR_35BPS, 259_259_259_259_259_259);

        // 135 bps split 35/135 leaves the protocol 35 and the creator 100, to the wei.
        uint256 shares = 1_000e18;
        uint256 total = shares * index.mintFee() / 1e18;
        uint256 protocol = total * MintSplit.PROTOCOL_PORTION_FOR_35BPS / 1e18;
        assertApproxEqAbs(total * 10_000 / shares, uint256(135), 1, "135 bps in total");
        assertApproxEqAbs(protocol * 10_000 / shares, uint256(35), 1, "35 bps to the protocol");
        assertApproxEqAbs((total - protocol) * 10_000 / shares, uint256(100), 1, "100 bps to the creator");
    }

    /// @dev The fee is the tracking band, so it is worth pinning what band we chose.
    function testMintFeeIsTheTrackingBand() public view {
        // A share can trade this far above NAV before minting to sell into it pays.
        assertLe(index.mintFee(), 0.02e18, "a wider band than 2% would be a different product");
    }
}
