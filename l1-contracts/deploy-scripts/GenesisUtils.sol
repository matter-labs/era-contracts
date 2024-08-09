
import {Vm} from "forge-std/Vm.sol";

import { Utils } from "./Utils.sol";

import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";

import { IL2ContractDeployer } from "contracts/common/interfaces/IL2ContractDeployer.sol";
import { AddressAliasHelper } from "contracts/vendor/AddressAliasHelper.sol";


address constant L2_BRIDGEHUB_ADDRESS = 0x0000000000000000000000000000000000010002;
address constant L2_ASSET_ROUTER_ADDRESS = 0x0000000000000000000000000000000000010003;
address constant L2_NATIVE_TOKEN_VAULT_ADDRESS = 0x0000000000000000000000000000000000010004;

library GenesisUtils {

    struct Bytecodes {
        bytes l2Bridgehub;
        bytes l2AssetRouter;
        bytes l2NativeTokenVault;
    }

    function readBytecodes() internal view returns (Bytecodes memory bytecodes) {
        bytecodes.l2Bridgehub = Utils.readHardhatBytecode(
            "/artifacts-zk/contracts/bridgehub/Bridgehub.sol/Bridgehub.json"
        );
        bytecodes.l2AssetRouter = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/contracts/bridge/L2AssetRouter.sol/L2AssetRouter.json"
        );
        bytecodes.l2NativeTokenVault = Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/contracts/bridge/L2NativeTokenVault.sol/L2NativeTokenVault.json"
        );
    }

    function genesisForceDeployments(
        uint256 eraChainId,
        address sharedBridgeProxy,
        uint256 l1ChainId,
        address governance,
        address legacyBridge,
        bytes32 l2TokenProxyBytecodeHash
    ) internal view returns (IL2ContractDeployer.ForceDeployment[] memory) {
        Bytecodes memory bytecodes = readBytecodes();

        IL2ContractDeployer.ForceDeployment[] memory deployments = new IL2ContractDeployer.ForceDeployment[](3);

        // Bridgehub deployment
        deployments[0] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: L2ContractHelper.hashL2Bytecode(bytecodes.l2Bridgehub),
            newAddress: L2_BRIDGEHUB_ADDRESS,
            callConstructor: true,
            value: 0,
            input: abi.encode(l1ChainId, AddressAliasHelper.applyL1ToL2Alias(governance))
        });

        // Asset router deployment
        deployments[1] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: L2ContractHelper.hashL2Bytecode(bytecodes.l2AssetRouter),
            newAddress: L2_ASSET_ROUTER_ADDRESS,
            callConstructor: true,
            value: 0,
            input: abi.encode(eraChainId, l1ChainId, sharedBridgeProxy, legacyBridge)
        });

        // native token vault deployment
        deployments[2] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: L2ContractHelper.hashL2Bytecode(bytecodes.l2NativeTokenVault),
            newAddress: L2_NATIVE_TOKEN_VAULT_ADDRESS,
            callConstructor: true,
            value: 0,
            input: abi.encode(l2TokenProxyBytecodeHash, governance, false)
        });

        return deployments;
    }

    function getL2TokenProxyBytecodeHash() internal view returns (bytes32) {
        return L2ContractHelper.hashL2Bytecode(
            Utils.readHardhatBytecode(
            "/../l2-contracts/artifacts-zk/@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol/BeaconProxy.json"
            )
        );
    }

    function getGenesisTransactionData(
        uint256 eraChainId,
        address sharedBridgeProxy,
        uint256 l1ChainId,
        address governance,
        address legacyBridge,
        bytes32 l2TokenProxyBytecodeHash
    ) internal view returns (bytes memory) {
        return abi.encode(
            genesisForceDeployments(
                eraChainId,
                sharedBridgeProxy,
                l1ChainId,
                governance,
                legacyBridge,
                l2TokenProxyBytecodeHash
            )
        );
    }

    function getGenesisTransactionFactoryDeps() internal view returns (bytes[] memory) {
        bytes[] memory result = new bytes[](3);

        Bytecodes memory bytecodes = readBytecodes();

        result[0] = bytecodes.l2Bridgehub;
        result[1] = bytecodes.l2AssetRouter;
        result[2] = bytecodes.l2NativeTokenVault;

        return result;
    }

}
