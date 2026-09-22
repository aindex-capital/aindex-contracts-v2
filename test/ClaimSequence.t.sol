// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {MonthlyMandateFixture} from "./MonthlyMandate.t.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// Mixed operations on the managed factory with exact-transfer, mixed-decimal assets.
contract ClaimSequenceTest is MonthlyMandateFixture {
    address private bob = address(0xB0B02);
    function testFuzzMixedClaimsConserveBackingAndEffectiveSupply(uint256 entropy) public {
        // Exclude the separate prototype seeded by the inherited fixture.
        uint256 outsideA = a.totalSupply() - trackedA();
        uint256 outsideB = b.totalSupply() - trackedB();
        for (uint256 step; step < 32; ++step) {
            entropy = uint256(keccak256(abi.encode(entropy, step)));
            address actor = entropy & 1 == 0 ? alice : bob;
            uint256 choice = (entropy >> 1) % 6;
            if (choice == 0) {
                uint256 gross = 2 + (entropy >> 8) % 100e18;
                (, uint256[] memory required) = index.toAssets(gross, Math.Rounding.Ceil);
                a.mint(actor, required[0]); b.mint(actor, required[1]);
                vm.startPrank(actor);
                a.approve(address(index), required[0]); b.approve(address(index), required[1]);
                uint256 beforeShares = index.balanceOf(actor);
                uint256 net = gross - (gross * index.mintFee() + 1e18 - 1) / 1e18;
                index.mint(gross, actor, net);
                assertEq(index.balanceOf(actor) - beforeShares, net);
                vm.stopPrank();
            } else if (choice == 1) {
                uint256 owned = index.balanceOf(actor);
                if (owned > 0) {
                    uint256 shares = 1 + (entropy >> 8) % owned;
                    (address[] memory assets, uint256[] memory out) = index.toAssets(shares, Math.Rounding.Floor);
                    uint256 beforeA = a.balanceOf(actor); uint256 beforeB = b.balanceOf(actor);
                    vm.prank(actor); index.redeem(shares, actor, assets, out);
                    assertEq(a.balanceOf(actor) - beforeA, out[0]);
                    assertEq(b.balanceOf(actor) - beforeB, out[1]);
                    assertEq(index.balanceOf(actor), owned - shares);
                }
            } else if (choice == 2) {
                uint256 owned = index.balanceOf(actor);
                if (owned > 0) {
                    uint256 shares = 1 + (entropy >> 8) % owned;
                    vm.prank(actor); index.transfer(actor == alice ? bob : alice, shares);
                }
            } else if (choice == 3) {
                uint256 supply = index.totalSupply();
                a.mint(address(index), (entropy >> 8) % 1e18);
                b.mint(address(index), (entropy >> 64) % 1e6);
                assertEq(index.totalSupply(), supply, "donations cannot issue claims");
            } else {
                uint256 backingA = a.balanceOf(address(index));
                uint256 backingB = b.balanceOf(address(index));
                vm.warp(block.timestamp + 1 + (entropy >> 8) % 7 days);
                if (choice == 4) index.poke(); else index.distributeFees();
                assertEq(a.balanceOf(address(index)), backingA, "fees cannot remove backing");
                assertEq(b.balanceOf(address(index)), backingB, "fees cannot remove backing");
            }
            assertEq(trackedA() + outsideA, a.totalSupply(), "asset A conservation");
            assertEq(trackedB() + outsideB, b.totalSupply(), "asset B conservation");
            uint256 claims = index.balanceOf(address(this)) + index.balanceOf(alice)
                + index.balanceOf(bob) + index.balanceOf(address(0xFEE));
            assertEq(index.totalSupply(), claims + index.getPendingFeeShares(), "effective supply accounts for fee claims once");
            assertEq(index.balanceOf(address(managedFactory)), 0);
            assertEq(a.balanceOf(address(managedFactory)), 0);
            assertEq(b.balanceOf(address(managedFactory)), 0);
        }
    }
    function trackedA() private view returns (uint256) {
        return a.balanceOf(address(this)) + a.balanceOf(alice) + a.balanceOf(bob) + a.balanceOf(address(index));
    }
    function trackedB() private view returns (uint256) {
        return b.balanceOf(address(this)) + b.balanceOf(alice) + b.balanceOf(bob) + b.balanceOf(address(index));
    }
}
