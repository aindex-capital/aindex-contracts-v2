// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Folio} from "folio/Folio.sol";
import {IndexFactory} from "../src/IndexFactory.sol";
import {FixedFeeRegistry, MintSplit} from "../src/FixedFeeRegistry.sol";
import {IndexMarketRegistry} from "../src/IndexMarketRegistry.sol";
import {ShareMarketRouter} from "../src/ShareMarketRouter.sol";
import {ShareFeeHook} from "../src/ShareFeeHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/**
 * Deploy the index contracts to Robinhood Chain.
 *
 * Simulate first, always. Without `--broadcast` nothing is sent:
 *
 *     AINDEX_PROTOCOL_RECIPIENT=0x... \
 *     AINDEX_QUOTES=0x5fc5360d0400a0fd4f2af552add042d716f1d168 \
 *     forge script script/Deploy.s.sol --rpc-url $RPC --account <keystore> --sender <address>
 *
 * Add `--broadcast` to send it. The key is read by Foundry from its encrypted keystore and never
 * by this script.
 *
 * What it does, in order, and why the order matters:
 *
 *   1. Folio implementation, fee registry, factory. Admission is open: any token contract can go
 *      in a basket, so there is no list to supply and nobody holds a power over one.
 *   2. The fee hook, by CREATE2 at an address carrying its permission bits. The hook names the
 *      registry as its registrar and the registry names the hook, so the registry's address is
 *      predicted from the nonce and the registry must be the very next CREATE. Nothing may be
 *      sent between the two.
 *   3. Registry, router, and `wireMarket`. After this the deploying account holds no role on any
 *      of these contracts: the factory's `deployer` can only call `wireMarket`, once, and it has.
 *
 * The protocol recipient is the one lasting address. It receives the protocol's mint and trade
 * fees and is immutable in both the fee registry and the hook.
 *
 * The addresses are written to `deployments/4663.json`, which is what the application's manifest
 * is built from (`aindex/deploy/manifest.mjs`).
 */
contract Deploy is Script {
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    bytes32 internal constant POOL_MANAGER_RUNTIME =
        0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant HOOK_FLAGS = 0x0044; // afterSwap | afterSwapReturnDelta
    uint160 internal constant ALL_HOOK_MASK = 0x3fff;

    struct Deployed {
        address implementation;
        address feeRegistry;
        address factory;
        address feeHook;
        address registry;
        address router;
        uint256 startBlock;
    }

    function run() external returns (Deployed memory d) {
        require(block.chainid == 4663, "not Robinhood Chain");
        require(POOL_MANAGER.codehash == POOL_MANAGER_RUNTIME, "PoolManager runtime differs from recorded evidence");
        require(CREATE2_DEPLOYER.code.length != 0, "CREATE2 deployer missing");

        address protocol = vm.envAddress("AINDEX_PROTOCOL_RECIPIENT");
        require(protocol != address(0), "protocol recipient");
        address[] memory quotes = vm.envAddress("AINDEX_QUOTES", ",");
        require(quotes.length != 0, "empty quote list");
        for (uint256 i; i < quotes.length; ++i) require(quotes[i].code.length != 0, "quote has no code");
        d.startBlock = block.number;

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        // 1. Engine and factory.
        d.implementation = address(new Folio());
        d.feeRegistry = address(new FixedFeeRegistry(protocol, MintSplit.PROTOCOL_PORTION_FOR_35BPS, 0));
        IndexFactory factory = new IndexFactory(d.implementation, d.feeRegistry);
        d.factory = address(factory);

        // 2. Hook and registry, back to back. The hook's CREATE2 is one transaction from this
        //    account, so the registry is the CREATE at the nonce after it.
        address registryAddress = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        bytes memory hookArgs = abi.encode(IPoolManager(POOL_MANAGER), registryAddress, protocol);
        bytes32 salt = _mineHookSalt(keccak256(abi.encodePacked(type(ShareFeeHook).creationCode, hookArgs)));
        ShareFeeHook hook = new ShareFeeHook{salt: salt}(IPoolManager(POOL_MANAGER), registryAddress, protocol);
        IndexMarketRegistry registry =
            new IndexMarketRegistry(factory, IPoolManager(POOL_MANAGER), hook, quotes);
        require(address(registry) == registryAddress, "registry did not land where the hook expects");
        d.feeHook = address(hook);
        d.registry = address(registry);

        // 3. Router, then wire the factory to the market it launches into.
        d.router = address(new ShareMarketRouter(IPoolManager(POOL_MANAGER), address(hook), address(factory)));
        factory.wireMarket(registry, ShareMarketRouter(d.router));
        vm.stopBroadcast();

        _check(d, protocol, quotes);
        _record(d, protocol, quotes, deployer);
    }

    function _mineHookSalt(bytes32 initCodeHash) internal pure returns (bytes32) {
        for (uint256 i; i < 1_000_000; ++i) {
            address candidate = vm.computeCreate2Address(bytes32(i), initCodeHash, CREATE2_DEPLOYER);
            if (uint160(candidate) & ALL_HOOK_MASK == HOOK_FLAGS) return bytes32(i);
        }
        revert("no hook salt found, which at 1 in 16384 should not happen");
    }

    /// Read everything back from the contracts rather than trusting what was sent.
    function _check(Deployed memory d, address protocol, address[] memory quotes) internal view {
        IndexFactory factory = IndexFactory(d.factory);
        require(factory.marketWired(), "market not wired");
        require(address(factory.marketRegistry()) == d.registry && address(factory.marketRouter()) == d.router, "wiring");
        ShareFeeHook hook = ShareFeeHook(d.feeHook);
        require(hook.registrar() == d.registry && hook.protocolRecipient() == protocol, "hook identity");
        require(address(hook.poolManager()) == POOL_MANAGER, "hook manager");
        IndexMarketRegistry registry = IndexMarketRegistry(d.registry);
        require(address(registry.feeHook()) == d.feeHook && registry.lpFee() == hook.LP_FEE_BPS(), "registry fee");
        for (uint256 i; i < quotes.length; ++i) require(registry.quoteAllowed(quotes[i]), "quote not allowed");
        ShareMarketRouter router = ShareMarketRouter(d.router);
        require(router.feeHook() == d.feeHook && router.launcher() == d.factory, "router identity");
        require(FixedFeeRegistry(d.feeRegistry).recipient() == protocol, "fee recipient");
    }

    function _record(Deployed memory d, address protocol, address[] memory quotes, address deployer) internal {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "startBlock", d.startBlock);
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "protocolRecipient", protocol);
        vm.serializeAddress(k, "poolManager", POOL_MANAGER);
        vm.serializeAddress(k, "implementation", d.implementation);
        vm.serializeAddress(k, "feeRegistry", d.feeRegistry);
        vm.serializeAddress(k, "factory", d.factory);
        vm.serializeAddress(k, "feeHook", d.feeHook);
        vm.serializeAddress(k, "marketRegistry", d.registry);
        vm.serializeAddress(k, "router", d.router);
        string memory json = vm.serializeAddress(k, "quotes", quotes);
        string memory path = vm.envOr("AINDEX_DEPLOYMENT_OUT", string("deployments/4663.json"));
        vm.writeJson(json, path);
        console.log("factory       ", d.factory);
        console.log("marketRegistry", d.registry);
        console.log("router        ", d.router);
        console.log("feeHook       ", d.feeHook);
        console.log("written to    ", path);
    }
}
