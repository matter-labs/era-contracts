// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, Test, stdStorage, stdToml} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_MESSAGE_ROOT_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IContractDeployer, L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";

import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {L2Bridgehub} from "contracts/bridgehub/L2Bridgehub.sol";
import {IL2Bridgehub} from "contracts/bridgehub/IL2Bridgehub.sol";
import {L2MessageRoot} from "contracts/bridgehub/L2MessageRoot.sol";

import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {SystemContractsCaller} from "contracts/common/l2-helpers/SystemContractsCaller.sol";
import {DeployFailed} from "contracts/common/L1ContractErrors.sol";
import {SystemContractsArgs} from "../../l1/integration/l2-tests-abstract/_SharedL2ContractDeployer.sol";
import {ContractsBytecodesLib} from "deploy-scripts/ContractsBytecodesLib.sol";
import {Utils} from "deploy-scripts/Utils.sol";
import {L2ChainAssetHandler} from "contracts/bridgehub/L2ChainAssetHandler.sol";

library L2Utils {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    address internal constant L2_FORCE_DEPLOYER_ADDR = address(0x8007);
    uint256 internal constant L1_CHAIN_ID = 1;

    /**
     * @dev Initializes the system contracts.
     * @dev It is a hack needed to make the tests be able to call system contracts directly.
     */
    function initSystemContracts(SystemContractsArgs memory _args) internal {
        bytes memory contractDeployerBytecode = Utils.readSystemContractsBytecode("ContractDeployer");
        vm.etch(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, contractDeployerBytecode);
        forceDeploySystemContracts(_args);
    }

    function forceDeploySystemContracts(SystemContractsArgs memory _args) internal {
        forceDeployMessageRoot(_args);
        forceDeployBridgehub(_args);
        forceDeployChainAssetHandler(_args);
        forceDeployAssetRouter(_args);
        forceDeployNativeTokenVault(_args);
    }

    function forceDeployMessageRoot(SystemContractsArgs memory _args) internal {
        new L2MessageRoot();
        forceDeployWithoutConstructor("L2MessageRoot", L2_MESSAGE_ROOT_ADDR);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2MessageRoot(L2_MESSAGE_ROOT_ADDR).initL2(_args.l1ChainId);
    }

    function forceDeployBridgehub(SystemContractsArgs memory _args) internal {
        new L2Bridgehub();
        forceDeployWithoutConstructor("L2Bridgehub", L2_BRIDGEHUB_ADDR);
        L2Bridgehub bridgehub = L2Bridgehub(L2_BRIDGEHUB_ADDR);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        bridgehub.initL2(_args.l1ChainId, _args.aliasedOwner, 100);
        vm.prank(_args.aliasedOwner);
        bridgehub.setAddresses(
            L2_ASSET_ROUTER_ADDR,
            ICTMDeploymentTracker(_args.l1CtmDeployer),
            IMessageRoot(L2_MESSAGE_ROOT_ADDR),
            L2_CHAIN_ASSET_HANDLER_ADDR
        );
    }

    function forceDeployChainAssetHandler(SystemContractsArgs memory _args) internal {
        new L2ChainAssetHandler();
        forceDeployWithoutConstructor("L2ChainAssetHandler", L2_CHAIN_ASSET_HANDLER_ADDR);
        L2ChainAssetHandler chainAssetHandler = L2ChainAssetHandler(L2_CHAIN_ASSET_HANDLER_ADDR);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        chainAssetHandler.initL2(
            _args.l1ChainId,
            _args.aliasedOwner,
            L2_BRIDGEHUB_ADDR,
            L2_ASSET_ROUTER_ADDR,
            L2_MESSAGE_ROOT_ADDR
        );
    }

    /// @notice Deploys the L2AssetRouter contract.
    function forceDeployAssetRouter(SystemContractsArgs memory _args) internal {
        // to ensure that the bytecode is known
        bytes32 ethAssetId = DataEncoding.encodeNTVAssetId(_args.l1ChainId, ETH_TOKEN_ADDRESS);
        {
            new L2AssetRouter();
        }
        forceDeployWithoutConstructor("L2AssetRouter", L2_ASSET_ROUTER_ADDR);
        L2AssetRouter assetRouter = L2AssetRouter(L2_ASSET_ROUTER_ADDR);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        assetRouter.initL2(
            _args.l1ChainId,
            _args.eraChainId,
            _args.l1AssetRouter,
            _args.legacySharedBridge,
            ethAssetId,
            _args.aliasedOwner
        );
    }

    /// @notice Deploys the L2NativeTokenVault contract.
    function forceDeployNativeTokenVault(SystemContractsArgs memory _args) internal {
        // to ensure that the bytecode is known
        bytes32 ethAssetId = DataEncoding.encodeNTVAssetId(_args.l1ChainId, ETH_TOKEN_ADDRESS);
        {
            new L2NativeTokenVault();
        }
        forceDeployWithoutConstructor("L2NativeTokenVault", L2_NATIVE_TOKEN_VAULT_ADDR);
        L2NativeTokenVault nativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        nativeTokenVault.initL2(
            _args.l1ChainId,
            _args.aliasedOwner,
            _args.l2TokenProxyBytecodeHash,
            _args.legacySharedBridge,
            _args.l2TokenBeacon,
            address(0),
            ethAssetId
        );
    }

    function forceDeployWithoutConstructor(string memory _contractName, address _address) public {
        bytes memory bytecode = Utils.readZKFoundryBytecodeL1(string.concat(_contractName, ".sol"), _contractName);

        bytes32 bytecodehash = L2ContractHelper.hashL2Bytecode(bytecode);

        IContractDeployer.ForceDeployment[] memory deployments = new IContractDeployer.ForceDeployment[](1);
        deployments[0] = IContractDeployer.ForceDeployment({
            bytecodeHash: bytecodehash,
            newAddress: _address,
            callConstructor: false,
            value: 0,
            input: ""
        });

        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        IContractDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR).forceDeployOnAddresses(deployments);
    }

    function deployViaCreat2L2(
        bytes memory creationCode,
        bytes memory constructorargs,
        bytes32 create2salt
    ) internal returns (address) {
        bytes memory bytecode = abi.encodePacked(creationCode, constructorargs);
        address contractAddress;
        assembly {
            contractAddress := create2(0, add(bytecode, 0x20), mload(bytecode), create2salt)
        }
        uint32 size;
        assembly {
            size := extcodesize(contractAddress)
        }
        if (size == 0) {
            revert DeployFailed();
        }
        return contractAddress;
    }
}
