// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {GatewayPreparationForTests} from "./_GatewayPreparationForTests.sol";

import "@openzeppelin/contracts-v4/utils/Strings.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1ChainAssetHandlerDev} from "contracts/dev-contracts/L1ChainAssetHandlerDev.sol";

contract GatewayDeployer is L1ContractDeployer {
    GatewayPreparationForTests gatewayScript;

    /// @dev Chain migrations are explicitly disabled in the production contracts for the v32
    /// release (see `CHAIN_MIGRATIONS_ENABLED` in `Config.sol`), in which all chains settle on L1.
    /// The gateway tests exercise the migration machinery, which is intentionally preserved for
    /// future releases, so they upgrade the chain asset handler proxy to the Dev variant that
    /// re-enables migrations. Only the implementation is swapped: all proxy state (owner,
    /// messageRoot, assetRouter) and the immutables' values stay identical to production.
    function _enableChainMigrationsForTesting() internal {
        address cahProxy = ecosystemAddresses.bridgehub.proxies.chainAssetHandler;
        L1ChainAssetHandlerDev devImpl = new L1ChainAssetHandlerDev(
            Ownable(cahProxy).owner(),
            ecosystemAddresses.bridgehub.proxies.bridgehub
        );
        ProxyAdmin proxyAdmin = ProxyAdmin(ecosystemAddresses.shared.transparentProxyAdmin);
        vm.prank(proxyAdmin.owner());
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(payable(cahProxy)), address(devImpl));
    }

    function _initializeGatewayScript() internal {
        vm.setEnv("CTM_CONFIG", "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-ctm.toml");
        vm.setEnv("CTM_OUTPUT", "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-ctm.toml");
        vm.setEnv("L1_CONFIG", "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-l1.toml");
        vm.setEnv("L1_OUTPUT", "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-l1.toml");
        vm.setEnv(
            "ZK_CHAIN_CONFIG",
            "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-zk-chain-10.toml"
        );
        vm.setEnv(
            "GATEWAY_AS_CHAIN_CONFIG",
            "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-zk-chain-506.toml"
        );
        vm.setEnv(
            "GATEWAY_AS_CHAIN_OUTPUT",
            "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-zk-chain-506.toml"
        );

        gatewayScript = new GatewayPreparationForTests();
        gatewayScript.run();

        _enableChainMigrationsForTesting();
    }
}
