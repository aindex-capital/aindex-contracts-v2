// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Folio} from "folio/Folio.sol";
import {IFolio} from "folio/interfaces/IFolio.sol";
import {ManagedIndexFactory} from "../../src/ManagedIndexFactory.sol";
import {MonthlyMandate} from "../../src/MonthlyMandate.sol";
import {FixedFeeRegistry} from "../../src/FixedFeeRegistry.sol";

/// Real token code/state with simulated holder balances. Not a production asset approval.
contract RobinhoodAssetsForkTest is Test {
    address private constant WETH = address(bytes20(hex"0bd7d308f8e1639fab988df18a8011f41eacad73"));
    address private constant USDG = address(bytes20(hex"5fc5360d0400a0fd4f2af552add042d716f1d168"));

    function testRealTokenSeedMintTransferAndProportionalExit() public {
        string memory rpc = vm.envOr("AINDEX_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {vm.skip(true);return;}
        uint256 forkBlock = vm.envOr("AINDEX_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        assertEq(block.chainid, 4663);
        assertEq(IERC20Metadata(WETH).decimals(), 18);
        assertEq(IERC20Metadata(USDG).decimals(), 6);
        emit log_named_uint("Target asset fork block", block.number);
        emit log_named_bytes32("WETH runtime", WETH.codehash);
        emit log_named_bytes32("USDG runtime", USDG.codehash);
        // Cheatcodes provide local balances, never calls to issuer minting authority.
        deal(WETH, address(this), 1000e18);
        deal(USDG, address(this), 1000e6);
        address[] memory assets = new address[](2);
        assets[0] = WETH; assets[1] = USDG;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18; amounts[1] = 100e6;
        ManagedIndexFactory factory = new ManagedIndexFactory(address(new Folio()), address(new FixedFeeRegistry(address(0xFEE), 0.2e18, 0)), new address[](0));
        assertFalse(factory.admissionFrozen());
        factory.admitAssets(assets);
        bytes32 commitment = keccak256(abi.encodePacked(keccak256(abi.encodePacked(bytes32(0), WETH)), USDG));
        assertEq(factory.admissionCommitment(), commitment);
        factory.freezeAdmission(2, commitment);
        assertTrue(factory.admissionFrozen());
        assertEq(factory.admissionOwner(), address(0));
        emit log_named_bytes32("Frozen admission commitment", commitment);
        IERC20(WETH).approve(address(factory), amounts[0]);
        IERC20(USDG).approve(address(factory), amounts[1]);
        MonthlyMandate.TokenRule[] memory rules = new MonthlyMandate.TokenRule[](2);
        rules[0] = MonthlyMandate.TokenRule(WETH, 0, 2e27, 10e18);
        rules[1] = MonthlyMandate.TokenRule(USDG, 0, 2e15, 10e6);
        (Folio index, MonthlyMandate mandate) = factory.createManaged(
            IFolio.FolioBasicDetails("Fork compatibility", "FORK", assets, amounts, 100e18),
            MonthlyMandate.Config(address(this),address(0xB0B),address(0xCAFE),1 hours,30 days,300,100,keccak256("fork fixture")), rules);
        assertTrue(mandate.activated());
        assertEq(IERC20(WETH).balanceOf(address(index)),100e18);
        assertEq(IERC20(USDG).balanceOf(address(index)),100e6);
        IERC20(WETH).approve(address(index),1e18);
        IERC20(USDG).approve(address(index),1e6);
        index.mint(1e18,address(this),0.9997e18);
        assertEq(index.balanceOf(address(this)),100.9997e18);
        address holder = address(0xA11CE);
        index.transfer(holder,1e18);
        (address[] memory outputs,uint256[] memory minimums)=index.toAssets(1e18,Math.Rounding.Floor);
        vm.prank(holder);
        index.redeem(1e18,holder,outputs,minimums);
        assertEq(index.balanceOf(holder),0);
        assertEq(IERC20(WETH).balanceOf(holder),minimums[0]);
        assertEq(IERC20(USDG).balanceOf(holder),minimums[1]);
    }
}
