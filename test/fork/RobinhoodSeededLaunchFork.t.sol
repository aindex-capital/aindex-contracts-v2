// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SeededLaunchBase} from "../SeededLaunch.t.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// The production launch path against the live PoolManager, with real WETH and USDG in the
/// basket and USDG as the quote. Balances come from cheatcodes, never from issuer authority.
contract RobinhoodSeededLaunchForkTest is SeededLaunchBase {
    address private constant LIVE_MANAGER = address(bytes20(hex"8366a39cc670b4001a1121b8f6a443a643e40951"));
    bytes32 private constant OBSERVED_RUNTIME = hex"bd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626";
    address private constant WETH = address(bytes20(hex"0bd7d308f8e1639fab988df18a8011f41eacad73"));
    address private constant USDG = address(bytes20(hex"5fc5360d0400a0fd4f2af552add042d716f1d168"));

    function setUp() public override {
        string memory rpc = vm.envOr("AINDEX_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {vm.skip(true);return;}
        uint256 forkBlock = vm.envOr("AINDEX_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        assertEq(block.chainid, 4663, "Wrong target chain");
        assertEq(LIVE_MANAGER.codehash, OBSERVED_RUNTIME, "PoolManager identity differs from recorded evidence");
        emit log_named_uint("Target fork block", block.number);
        super.setUp();
    }

    function poolManagerFixture() internal pure override returns (IPoolManager) {
        return IPoolManager(LIVE_MANAGER);
    }

    function assetFixture() internal override {
        assets.push(WETH);
        assets.push(USDG);
        amounts.push(1e18);
        amounts.push(1_000e6);
        quote = USDG;
    }

    function fund(address token, address to, uint256 amount) internal override {
        deal(token, to, IERC20Like(token).balanceOf(to) + amount);
    }
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}
