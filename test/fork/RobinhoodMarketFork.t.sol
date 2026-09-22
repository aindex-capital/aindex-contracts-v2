// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ShareMarketTest} from "../ShareMarket.t.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// Existing target-chain venue, disposable local shares/backing/quote. This does not
/// establish compatibility of real catalog tokens or third-party routing/discovery.
contract RobinhoodMarketForkTest is ShareMarketTest {
    address private constant LIVE_MANAGER = address(bytes20(hex"8366a39cc670b4001a1121b8f6a443a643e40951"));
    bytes32 private constant OBSERVED_RUNTIME = hex"bd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626";

    function setUp() public override {
        string memory rpc = vm.envOr("AINDEX_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {vm.skip(true);return;}
        uint256 forkBlock = vm.envOr("AINDEX_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        assertEq(block.chainid, 4663, "Wrong target chain");
        assertEq(LIVE_MANAGER.codehash, OBSERVED_RUNTIME, "PoolManager identity differs from recorded evidence");
        emit log_named_uint("Target fork block", block.number);
        emit log_named_bytes32("Existing PoolManager runtime hash", LIVE_MANAGER.codehash);
        super.setUp();
    }

    function poolManagerFixture() internal pure override returns (IPoolManager) {
        return IPoolManager(LIVE_MANAGER);
    }
}
