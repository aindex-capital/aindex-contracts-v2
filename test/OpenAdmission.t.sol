// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Folio} from "folio/Folio.sol";
import {IFolio} from "folio/interfaces/IFolio.sol";
import {IndexFixture, TestAsset} from "./IndexLifecycle.t.sol";
import {IndexFactoryBase} from "../src/IndexFactoryBase.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {MonthlyMandate} from "../src/MonthlyMandate.sol";
import {FixedFeeRegistry} from "../src/FixedFeeRegistry.sol";

/// Takes 1% of every transfer, which a basket cannot hold: its balances would drift from its books.
contract TaxedAsset is ERC20 {
    constructor() ERC20("Taxed", "TAX") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) return super._update(from, to, value);
        uint256 tax = value / 100;
        super._update(from, address(0xdead), tax);
        super._update(from, to, value - tax);
    }
}

/**
 * Admission is open: any token contract can go in a basket, with nothing to admit first and no
 * one who could. What is still refused is what the chain can see at launch.
 */
contract OpenAdmissionTest is IndexFixture {
    IndexFactory internal open;

    function setUp() public override {
        super.setUp();
        open = new IndexFactory(address(new Folio()), address(new FixedFeeRegistry(address(0xFEE), 0.2e18, 0)));
    }

    function launch(address[] memory assets, uint256[] memory amounts) internal returns (Folio index) {
        MonthlyMandate.TokenRule[] memory rules = new MonthlyMandate.TokenRule[](assets.length);
        for (uint256 i; i < assets.length; ++i) rules[i] = MonthlyMandate.TokenRule(assets[i], 0, 1e36, amounts[i]);
        (index,) = open.createManaged(IFolio.FolioBasicDetails("Open", "OPN", assets, amounts, 100e18),
            MonthlyMandate.Config(address(this), address(0xB0B), address(0xCAFE), 1 hours, 30 days, 300, 100, keccak256("open")),
            rules);
    }

    function testAnyTokenWithCodeCanBeHeldWithoutBeingAdmitted() public {
        TestAsset fresh = new TestAsset("Launched a second ago", 18);
        fresh.mint(address(this), 10e18);
        fresh.approve(address(open), 10e18);
        b.approve(address(open), 10e6);
        address[] memory assets = new address[](2);
        assets[0] = address(fresh); assets[1] = address(b);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10e18; amounts[1] = 10e6;
        Folio index = launch(assets, amounts);
        assertEq(fresh.balanceOf(address(index)), 10e18);
        assertEq(index.balanceOf(address(this)), 100e18);
    }

    function testAnAddressWithNoCodeIsRefused() public {
        a.approve(address(open), 10e18);
        address[] memory assets = new address[](2);
        assets[0] = address(a); assets[1] = address(0xBEEF);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10e18; amounts[1] = 1;
        vm.expectRevert(IndexFactoryBase.InvalidConfiguration.selector);
        launch(assets, amounts);
    }

    function testATokenThatTaxesTransfersIsRefusedAtLaunch() public {
        TaxedAsset taxed = new TaxedAsset();
        taxed.mint(address(this), 10e18);
        taxed.approve(address(open), 10e18);
        a.approve(address(open), 10e18);
        address[] memory assets = new address[](2);
        assets[0] = address(a); assets[1] = address(taxed);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10e18; amounts[1] = 10e18;
        vm.expectRevert(abi.encodeWithSelector(IndexFactoryBase.UnsupportedTransfer.selector, address(taxed)));
        launch(assets, amounts);
    }
}
