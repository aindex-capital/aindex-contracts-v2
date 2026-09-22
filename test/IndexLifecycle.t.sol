// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Folio} from "folio/Folio.sol";
import {IFolio} from "folio/interfaces/IFolio.sol";
import {IndexFactoryBase} from "../src/IndexFactoryBase.sol";

contract TestAsset is ERC20 {
    uint8 private immutable precision;
    constructor(string memory label, uint8 decimals_) ERC20(label, label) { precision = decimals_; }
    function decimals() public view override returns (uint8) { return precision; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// Explicit test fixture: production registry ownership and fees are not decided here.
contract TestFeeRegistry {
    function getFeeDetails(address) external pure returns (address, uint256, uint256, uint256) {
        return (address(0xFEE), uint256(1e18) / 3, 1e18, 0);
    }
}

abstract contract IndexFixture is Test {
    Folio internal index;
    IndexFactoryBase internal factory;
    TestAsset internal a;
    TestAsset internal b;
    address internal alice = address(0xA11CE);

    function setUp() public virtual {
        a = new TestAsset("Asset A", 18);
        b = new TestAsset("Asset B", 6);
        factory = new IndexFactoryBase(address(new Folio()), address(new TestFeeRegistry()));
        a.mint(address(this), 10_000e18);
        b.mint(address(this), 10_000e6);
        a.approve(address(factory), type(uint256).max);
        b.approve(address(factory), type(uint256).max);
        index = factory.create(seed());
    }

    function seed() internal view returns (IFolio.FolioBasicDetails memory s) {
        s.name = "AINDEX prototype";
        s.symbol = "AIP";
        s.assets = new address[](2);
        s.amounts = new uint256[](2);
        s.assets[0] = address(a); s.assets[1] = address(b);
        s.amounts[0] = 1_000e18; s.amounts[1] = 1_000e6;
        s.initialShares = 1_000e18;
    }
}

contract IndexLifecycleTest is IndexFixture {
    function testReviewedMintAllowancesBoundSpendAfterBackingDonation() public {
        (address[] memory assets, uint256[] memory amounts) = index.toAssets(10e18, Math.Rounding.Ceil);
        for (uint256 i; i < assets.length; ++i) IERC20(assets[i]).approve(address(index), amounts[i]);
        a.transfer(address(index), 100e18);
        uint256 beforeA = a.balanceOf(address(this));
        uint256 beforeB = b.balanceOf(address(this));
        uint256 beforeShares = index.balanceOf(address(this));
        vm.expectRevert();
        index.mint(10e18, address(this), 9e18);
        assertEq(a.balanceOf(address(this)), beforeA);
        assertEq(b.balanceOf(address(this)), beforeB);
        assertEq(index.balanceOf(address(this)), beforeShares);
    }

    function testSeedFullyBackedAndFactoryHasNoAuthority() public view {
        assertEq(index.totalSupply(), 1_000e18);
        assertEq(index.balanceOf(address(this)), 1_000e18);
        assertEq(a.balanceOf(address(index)), 1_000e18);
        assertEq(b.balanceOf(address(index)), 1_000e6);
        assertTrue(index.hasRole(bytes32(0), address(this)));
        assertFalse(index.hasRole(bytes32(0), address(factory)));
        assertEq(a.balanceOf(address(factory)), 0);
        assertEq(index.version(), "6.0.0");
    }

    function testTransferAndRedeemWithoutManager() public {
        index.transfer(alice, 100e18);
        (address[] memory assets, uint256[] memory amounts) = index.toAssets(100e18, Math.Rounding.Floor);
        vm.prank(alice);
        index.redeem(100e18, alice, assets, amounts);
        assertEq(a.balanceOf(alice), 100e18);
        assertEq(b.balanceOf(alice), 100e6);
        assertEq(index.totalSupply(), 900e18);
    }

    function testFuzzMintRedeemCannotExtractExistingBacking(uint256 grossShares) public {
        grossShares = bound(grossShares, 2, 5_000e18);
        (, uint256[] memory needed) = index.toAssets(grossShares, Math.Rounding.Ceil);
        a.mint(alice, needed[0]); b.mint(alice, needed[1]);
        vm.startPrank(alice);
        a.approve(address(index), needed[0]); b.approve(address(index), needed[1]);
        // Read from the index: the mint fee is 135 bps now, not Folio's 3 bps minimum.
        uint256 fee = (grossShares * index.mintFee() + 1e18 - 1) / 1e18;
        index.mint(grossShares, alice, grossShares - fee);
        assertEq(index.balanceOf(alice), grossShares - fee, "upstream mint floor must be included");
        (address[] memory assets, uint256[] memory returned) = index.toAssets(index.balanceOf(alice), Math.Rounding.Floor);
        index.redeem(index.balanceOf(alice), alice, assets, returned);
        vm.stopPrank();
        assertLe(a.balanceOf(alice), needed[0]);
        assertLe(b.balanceOf(alice), needed[1]);
        assertGe(a.balanceOf(address(index)), 1_000e18);
        assertGe(b.balanceOf(address(index)), 1_000e6);
    }

    function testDonationChangesClaimInsteadOfStayingAtInceptionUnits() public {
        a.transfer(address(index), 1_000e18);
        (, uint256[] memory amounts) = index.toAssets(100e18, Math.Rounding.Floor);
        assertEq(amounts[0], 200e18);
        assertEq(amounts[1], 100e6);
    }

    function testManagementFeeDilutesClaimsWithoutTakingBasketAssets() public {
        vm.warp(block.timestamp + 30 days);
        index.poke();
        assertGt(index.totalSupply(), 1_000e18);
        assertEq(a.balanceOf(address(index)), 1_000e18);
        assertEq(b.balanceOf(address(index)), 1_000e6);
        (, uint256[] memory amounts) = index.toAssets(100e18, Math.Rounding.Floor);
        assertLt(amounts[0], 100e18);
        index.distributeFees();
        assertGt(index.balanceOf(address(0xFEE)), 0);
    }

    function testCannotInitializeTwice() public {
        vm.expectRevert();
        index.initialize(seed(), emptyDetails(), IFolio.FolioRegistryIndex(address(1), address(0)),
            IFolio.FolioFlags(false, IFolio.RebalanceControl(false, IFolio.PriceControl.NONE), true), alice);
    }

    function emptyDetails() internal pure returns (IFolio.FolioAdditionalDetails memory d) { return d; }

    function testDuplicateAssetRevertsAndReturnsAllSeedCapital() public {
        IFolio.FolioBasicDetails memory s = seed();
        s.assets[1] = s.assets[0];
        uint256 beforeBalance = a.balanceOf(address(this));
        vm.expectRevert(IndexFactoryBase.InvalidConfiguration.selector);
        factory.create(s);
        assertEq(a.balanceOf(address(this)), beforeBalance);
    }

    function testUnauthorizedManagementRejected() public {
        TestAsset other = new TestAsset("X", 18);
        vm.prank(alice);
        vm.expectRevert();
        index.addToBasket(IERC20(address(other)));
    }
}
