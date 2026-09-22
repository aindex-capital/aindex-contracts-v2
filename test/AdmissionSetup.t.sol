// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MonthlyMandateFixture} from "./MonthlyMandate.t.sol";
import {Folio} from "folio/Folio.sol";
import {MonthlyMandate} from "../src/MonthlyMandate.sol";
import {ManagedIndexFactory} from "../src/ManagedIndexFactory.sol";
import {IndexFactoryBase} from "../src/IndexFactoryBase.sol";
import {FixedFeeRegistry} from "../src/FixedFeeRegistry.sol";

contract AdmissionSetupTest is MonthlyMandateFixture {
    ManagedIndexFactory internal staged;
    function setUp() public override {
        super.setUp();
        staged = new ManagedIndexFactory(address(new Folio()), address(new FixedFeeRegistry(address(0xFEE), 0.2e18, 0)), new address[](0));
    }
    function testBatchedSetupRequiresOwnerAndExactFreezeThenRemovesSetupAuthority() public {
        assertEq(staged.admissionOwner(), address(this));
        vm.prank(alice);
        vm.expectRevert(ManagedIndexFactory.AdmissionUnauthorized.selector);
        staged.admitAssets(seed().assets);
        staged.admitAssets(seed().assets);
        bytes32 expected = keccak256(abi.encodePacked(keccak256(abi.encodePacked(bytes32(0), address(a))), address(b)));
        assertEq(staged.admissionCommitment(), expected);
        vm.expectRevert(IndexFactoryBase.InvalidConfiguration.selector);
        staged.freezeAdmission(1, expected);
        vm.expectRevert(IndexFactoryBase.InvalidConfiguration.selector);
        staged.freezeAdmission(2, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(ManagedIndexFactory.AdmissionUnauthorized.selector);
        staged.freezeAdmission(2, expected);
        staged.freezeAdmission(2, expected);
        assertTrue(staged.admissionFrozen());
        assertEq(staged.admissionOwner(), address(0));
        vm.expectRevert(ManagedIndexFactory.AdmissionUnauthorized.selector);
        staged.admitAssets(seed().assets);
        vm.expectRevert(ManagedIndexFactory.AdmissionUnauthorized.selector);
        staged.freezeAdmission(2, expected);
    }
    function testCreationBeforeFreezeCannotSpendSeedAndCreationAfterFreezeWorks() public {
        a.approve(address(staged), type(uint256).max);
        b.approve(address(staged), type(uint256).max);
        MonthlyMandate.TokenRule[] memory rules = new MonthlyMandate.TokenRule[](2);
        rules[0] = MonthlyMandate.TokenRule(address(a), 0, 2e27, 100e18);
        rules[1] = MonthlyMandate.TokenRule(address(b), 0, 2e15, 100e6);
        MonthlyMandate.Config memory cfg = MonthlyMandate.Config(address(this), reviewer, guardian, 1 hours, 30 days, 300, 100, keccak256("setup"));
        staged.admitAssets(seed().assets);
        uint256 balance = a.balanceOf(address(this));
        vm.expectRevert(ManagedIndexFactory.AdmissionNotFrozen.selector);
        staged.createManaged(seed(), cfg, rules);
        assertEq(a.balanceOf(address(this)), balance);
        staged.freezeAdmission(2, staged.admissionCommitment());
        (Folio created, MonthlyMandate policy) = staged.createManaged(seed(), cfg, rules);
        assertEq(created.getRoleMemberCount(bytes32(0)), 1);
        assertEq(created.getRoleMember(bytes32(0), 0), address(policy));
        assertEq(a.balanceOf(address(created)), 1000e18);
    }
    function testInvalidBatchRollsBackAllAdmissionWrites() public {
        address[] memory assets = seed().assets;
        assets[1] = assets[0];
        vm.expectRevert(IndexFactoryBase.InvalidConfiguration.selector);
        staged.admitAssets(assets);
        assertEq(staged.admittedAssetCount(), 0);
        assertFalse(staged.assetAllowed(address(a)));
        assertEq(staged.admissionCommitment(), bytes32(0));
        assets[1] = alice;
        vm.expectRevert(IndexFactoryBase.InvalidConfiguration.selector);
        staged.admitAssets(assets);
        assertFalse(staged.assetAllowed(address(a)));
        vm.expectRevert(IndexFactoryBase.InvalidConfiguration.selector);
        staged.admitAssets(new address[](129));
        vm.expectRevert(IndexFactoryBase.InvalidConfiguration.selector);
        staged.admitAssets(new address[](0));
        vm.expectRevert(IndexFactoryBase.InvalidConfiguration.selector);
        staged.freezeAdmission(0, bytes32(0));
    }
    function testAtomicConstructorCatalogCannotBeExpandedByItsDeployer() public {
        assertTrue(managedFactory.admissionFrozen());
        assertEq(managedFactory.admissionOwner(), address(0));
        assertEq(managedFactory.admittedAssetCount(), 2);
        vm.expectRevert(ManagedIndexFactory.AdmissionUnauthorized.selector);
        managedFactory.admitAssets(seed().assets);
    }
    function test2545AssetCatalogUsesBoundedBatchesAndOneImmutableCommitment() public {
        bytes32 expected;
        uint256 largest;
        for (uint256 offset; offset < 2545; offset += 128) {
            uint256 count = 2545 - offset < 128 ? 2545 - offset : 128;
            address[] memory assets = new address[](count);
            for (uint256 i; i < count; ++i) {
                assets[i] = address(uint160(0x100000 + offset + i));
                vm.etch(assets[i], hex"00"); // Code-presence fixture, not token compatibility evidence.
                expected = keccak256(abi.encodePacked(expected, assets[i]));
            }
            uint256 start = gasleft();
            staged.admitAssets(assets);
            uint256 used = start - gasleft();
            if (used > largest) largest = used;
        }
        assertEq(staged.admittedAssetCount(), 2545);
        assertEq(staged.admissionCommitment(), expected);
        staged.freezeAdmission(2545, expected);
        assertTrue(staged.assetAllowed(address(uint160(0x100000 + 2544))));
        emit log_named_uint("Largest synthetic admission batch execution gas", largest);
    }
}
