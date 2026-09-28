// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {refPrices} from "./FreshPrices.sol";
import {TestAsset} from "./IndexLifecycle.t.sol";
import {Test} from "forge-std/Test.sol";
import {Folio} from "folio/Folio.sol";
import {IFolio} from "folio/interfaces/IFolio.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {IndexFactoryBase} from "../src/IndexFactoryBase.sol";
import {MonthlyMandate} from "../src/MonthlyMandate.sol";
import {FixedFeeRegistry} from "../src/FixedFeeRegistry.sol";

/// Synthetic capacity evidence, not production token compatibility or transaction gas limits.
contract BasketCapacityTest is Test {
    IndexFactory internal factory;
    IFolio.FolioBasicDetails internal seed;
    MonthlyMandate.TokenRule[] internal rules;
    MonthlyMandate.Config internal config;
    address internal reviewer = address(0xB0B);
    address internal alice = address(0xA11CE);
    address internal extraAsset;

    function setUp() public {
        seed.name = "Sixteen asset capacity";
        seed.symbol = "CAP16";
        seed.initialShares = 1_000e18;
        // Any token can be held, so the limit that binds is the sixteen-asset basket.
        address[] memory admitted = new address[](17);
        for (uint256 i; i < 17; ++i) {
            uint8 decimals = i % 2 == 0 ? 18 : 6;
            TestAsset token = new TestAsset("Capacity asset", decimals);
            admitted[i] = address(token);
            token.mint(address(this), 10_000 * 10 ** decimals);
            if (i < 16) {
                seed.assets.push(address(token));
                seed.amounts.push(1_000 * 10 ** decimals);
                rules.push(MonthlyMandate.TokenRule(address(token), 0, 2 * 10 ** (9 + decimals), 100 * 10 ** decimals));
            }
        }
        factory = new IndexFactory(address(new Folio()), address(new FixedFeeRegistry(address(0xFEE), 0.2e18, 0)));
        extraAsset = admitted[16];
        for (uint256 i; i < admitted.length; ++i) IERC20(admitted[i]).approve(address(factory), type(uint256).max);
        config = MonthlyMandate.Config(address(this), reviewer, address(0xCAFE), 1 hours, 30 days, 300, 100, keccak256("capacity fixture"));
    }

    function testSixteenAssetLifecycleAndExecutionGas() public {
        uint256 start = gasleft();
        (Folio index, MonthlyMandate mandate) = factory.createManaged(seed, config, rules);
        emit log_named_uint("16 assets createManaged execution gas", start - gasleft());
        assertEq(mandate.ruleCount(), 16);
        assertEq(index.getRoleMemberCount(bytes32(0)), 1);
        assertEq(index.getRoleMember(bytes32(0), 0), address(mandate));
        (address[] memory assets, uint256[] memory needed) = index.toAssets(10e18, Math.Rounding.Ceil);
        for (uint256 i; i < 16; ++i) {
            assertEq(IERC20(assets[i]).balanceOf(address(index)), seed.amounts[i]);
            TestAsset(assets[i]).mint(alice, needed[i]);
            vm.prank(alice);
            IERC20(assets[i]).approve(address(index), needed[i]);
        }
        /*
         * Read the fee BEFORE the prank. `vm.prank` is consumed by the next call of any kind, and
         * `index.mintFee()` inside the argument list is a call, so computing it inline silently
         * spent the prank and the mint arrived from this contract with no allowance.
         */
        uint256 netOut = 10e18 - (10e18 * index.mintFee() + 1e18 - 1) / 1e18;
        vm.prank(alice);
        start = gasleft();
        index.mint(10e18, alice, netOut);
        emit log_named_uint("16 assets mint execution gas", start - gasleft());
        assertEq(index.balanceOf(alice), netOut);
        IFolio.TokenRebalanceParams[] memory proposal = new IFolio.TokenRebalanceParams[](16);
        for (uint256 i; i < 16; ++i) {
            uint256 unit = 10 ** TestAsset(assets[i]).decimals();
            uint256 weight = (i % 2 == 0 ? 9 : 11) * unit * 1e8;
            uint256 price = 1e45 / unit;
            proposal[i] = IFolio.TokenRebalanceParams(assets[i], IFolio.WeightRange(weight, weight, weight), IFolio.PriceRange(price, price * 1001 / 1000), 100 * unit, true);
        }
        start = gasleft();
        mandate.queue(proposal, block.timestamp + 2 hours);
        emit log_named_uint("16 assets queue execution gas", start - gasleft());
        vm.warp(block.timestamp + 1 hours);
        bytes32 commitment = mandate.pending();
        vm.prank(reviewer);
        mandate.approve(proposal, refPrices(proposal), block.timestamp + 60);
        start = gasleft();
        uint256 auction = mandate.execute(proposal);
        emit log_named_uint("16 assets execute execution gas", start - gasleft());
        vm.warp(block.timestamp + 31);
        TestAsset(assets[1]).mint(alice, 51e6);
        vm.startPrank(alice);
        IERC20(assets[1]).approve(address(index), 51e6);
        start = gasleft();
        index.bid(auction, IERC20(assets[0]), IERC20(assets[1]), 50e18, 51e6, false, "");
        emit log_named_uint("16 assets bid execution gas", start - gasleft());
        assertEq(IERC20(assets[0]).balanceOf(address(index)), seed.amounts[0] + needed[0] - 50e18);
        (, uint256[] memory outputs) = index.toAssets(index.balanceOf(alice), Math.Rounding.Floor);
        uint256[] memory beforeBalances = new uint256[](16);
        for (uint256 i; i < 16; ++i) beforeBalances[i] = IERC20(assets[i]).balanceOf(alice);
        uint256 shares = index.balanceOf(alice);
        start = gasleft();
        index.redeem(shares, alice, assets, outputs);
        emit log_named_uint("16 assets redeem execution gas", start - gasleft());
        vm.stopPrank();
        assertEq(index.balanceOf(alice), 0);
        for (uint256 i; i < 16; ++i) assertEq(IERC20(assets[i]).balanceOf(alice) - beforeBalances[i], outputs[i]);
    }

    function testSeventeenthAssetRejectedWithoutSpendingSeed() public {
        seed.assets.push(extraAsset);
        seed.amounts.push(seed.amounts[0]);
        rules.push(MonthlyMandate.TokenRule(extraAsset, 0, 2e27, 100e18));
        uint256 beforeBalance = IERC20(seed.assets[0]).balanceOf(address(this));
        vm.expectRevert(IndexFactoryBase.InvalidConfiguration.selector);
        factory.createManaged(seed, config, rules);
        assertEq(IERC20(seed.assets[0]).balanceOf(address(this)), beforeBalance);
    }
}
