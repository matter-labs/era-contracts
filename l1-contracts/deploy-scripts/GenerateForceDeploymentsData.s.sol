pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Utils} from "./Utils.sol";
import {L2_BRIDGEHUB_ADDR, L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDRESS} from "contracts/common/L2ContractAddresses.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {ForceDeployment} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";

contract GenerateForceDeploymentsData is Script {
    using stdToml for string;

    Config internal config;
    ContractsBytecodes internal contracts;

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        address l1AssetRouterProxy;
        address governance;
        uint256 chainId;
        uint256 eraChainId;
        bytes forceDeploymentsData;
        address l2LegacySharedBridge;
        address l2TokenBeacon;
        bool contractsDeployedAlready;
    }

    struct ContractsBytecodes {
        bytes bridgehubBytecode;
        bytes l2AssetRouterBytecode;
        bytes l2NtvBytecode;
        bytes l2StandardErc20FactoryBytecode;
        bytes l2TokenProxyBytecode;
        bytes l2StandardErc20Bytecode;
    }

    function run() public {
        initializeConfig();
        loadContracts();

        genesisForceDeploymentsData();

        saveOutput();
    }

    function loadContracts() internal {
        //HACK: Meanwhile we are not integrated foundry zksync we use contracts that has been built using hardhat
        contracts.l2StandardErc20FactoryBytecode = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol/UpgradeableBeacon.json"
        );
        contracts.l2TokenProxyBytecode = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol/BeaconProxy.json"
        );
        contracts.l2StandardErc20Bytecode = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/contracts/bridge/BridgedStandardERC20.sol/BridgedStandardERC20.json"
        );

        contracts.l2AssetRouterBytecode = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/contracts/bridge/L2AssetRouter.sol/L2AssetRouter.json"
        );
        contracts.bridgehubBytecode = Utils.readHardhatBytecode(
            "/../l1-contracts/artifacts-zk/contracts/bridgehub/Bridgehub.sol/Bridgehub.json"
        );
        contracts.l2NtvBytecode = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/contracts/bridge/L2NativeTokenVault.sol/L2NativeTokenVault.json"
        );
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, vm.envString("FORCE_DEPLOYMENTS_CONFIG"));
        string memory toml = vm.readFile(path);
        config.governance = toml.readAddress("$.governance");
        config.l1AssetRouterProxy = toml.readAddress("$.l1_shared_bridge");
        config.chainId = toml.readUint("$.chain_id");
        config.eraChainId = toml.readUint("$.era_chain_id");
        config.l2LegacySharedBridge = toml.readAddress("$.l2_legacy_shared_bridge");
        config.l2TokenBeacon = toml.readAddress("$.l2_token_beacon");
        config.contractsDeployedAlready = toml.readBool("$.l2_contracts_deployed_already");
    }

    function saveOutput() internal {
        string memory toml = vm.serializeBytes("root", "force_deployments_data", config.forceDeploymentsData);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-force-deployments-data.toml");
        vm.writeToml(toml, path);
    }

    function genesisForceDeploymentsData() internal {
        address aliasedGovernance = AddressAliasHelper.applyL1ToL2Alias(config.governance);
        ForceDeployment[] memory forceDeployments = new ForceDeployment[](3);

        forceDeployments[0] = ForceDeployment({
            bytecodeHash: keccak256(contracts.bridgehubBytecode),
            newAddress: L2_BRIDGEHUB_ADDR,
            callConstructor: true,
            value: 0,
            input: abi.encode(config.chainId, aliasedGovernance)
        });

        forceDeployments[1] = ForceDeployment({
            bytecodeHash: keccak256(contracts.l2AssetRouterBytecode),
            newAddress: L2_ASSET_ROUTER_ADDR,
            callConstructor: true,
            value: 0,
            // solhint-disable-next-line func-named-parameters
            input: abi.encode(config.chainId, config.eraChainId, config.l1AssetRouterProxy, address(1))
        });

        forceDeployments[2] = ForceDeployment({
            bytecodeHash: keccak256(contracts.l2NtvBytecode),
            newAddress: L2_NATIVE_TOKEN_VAULT_ADDRESS,
            callConstructor: true,
            value: 0,
            // solhint-disable-next-line func-named-parameters
            input: abi.encode(
                config.chainId,
                aliasedGovernance,
                keccak256(contracts.l2TokenProxyBytecode),
                config.l2LegacySharedBridge,
                config.l2TokenBeacon,
                config.contractsDeployedAlready
            )
        });
        config.forceDeploymentsData = abi.encode(forceDeployments);
    }
}
