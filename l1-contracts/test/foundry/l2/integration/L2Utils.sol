// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import "forge-std/console.sol";

import {L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_BRIDGEHUB_ADDR, L2_MESSAGE_ROOT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IContractDeployer, L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";

import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {Bridgehub, IBridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {MessageRoot} from "contracts/bridgehub/MessageRoot.sol";

import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {SystemContractsCaller} from "contracts/common/libraries/SystemContractsCaller.sol";
import {DeployFailed} from "contracts/common/L1ContractErrors.sol";
import {SystemContractsArgs} from "../../l1/integration/l2-tests-in-l1-context/_SharedL2ContractDeployer.sol";

library L2Utils {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    address internal constant L2_FORCE_DEPLOYER_ADDR = address(0x8007);

    string internal constant L2_ASSET_ROUTER_PATH = "./zkout/L2AssetRouter.sol/L2AssetRouter.json";
    string internal constant L2_NATIVE_TOKEN_VAULT_PATH = "./zkout/L2NativeTokenVault.sol/L2NativeTokenVault.json";
    string internal constant BRIDGEHUB_PATH = "./zkout/Bridgehub.sol/Bridgehub.json";

    function readFoundryBytecode(string memory artifactPath) internal view returns (bytes memory) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, artifactPath);
        string memory json = vm.readFile(path);
        bytes memory bytecode = vm.parseJsonBytes(json, ".bytecode.object");
        return bytecode;
    }

    function readZKFoundryBytecodeL1(
        string memory fileName,
        string memory contractName
    ) internal view returns (bytes memory) {
        string memory path = string.concat("/../l1-contracts/zkout/", fileName, "/", contractName, ".json");
        bytes memory bytecode = readFoundryBytecode(path);
        return bytecode;
    }

    function readZKFoundryBytecodeSystemContracts(
        string memory fileName,
        string memory contractName
    ) internal view returns (bytes memory) {
        string memory path = string.concat("/../system-contracts/zkout/", fileName, "/", contractName, ".json");
        bytes memory bytecode = readFoundryBytecode(path);
        return bytecode;
    }

    /// @notice Returns the bytecode of a given system contract.
    function readSystemContractsBytecode(string memory _filename) internal view returns (bytes memory) {
        return readZKFoundryBytecodeSystemContracts(string.concat(_filename, ".sol"), _filename);
    }

    /**
     * @dev Initializes the system contracts.
     * @dev It is a hack needed to make the tests be able to call system contracts directly.
     */
    function initSystemContracts(SystemContractsArgs memory _args) internal {
        bytes memory contractDeployerBytecode = readSystemContractsBytecode("ContractDeployer");
        vm.etch(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, contractDeployerBytecode);
        forceDeploySystemContracts(_args);
    }

    function forceDeploySystemContracts(SystemContractsArgs memory _args) internal {
        forceDeployMessageRoot();
        forceDeployBridgehub(
            _args.l1ChainId,
            _args.eraChainId,
            _args.aliasedOwner,
            _args.l1AssetRouter,
            _args.legacySharedBridge,
            _args.l1CtmDeployer
        );
        forceDeployAssetRouter(
            _args.l1ChainId,
            _args.eraChainId,
            _args.aliasedOwner,
            _args.l1AssetRouter,
            _args.legacySharedBridge
        );
        forceDeployNativeTokenVault(
            _args.l1ChainId,
            _args.aliasedOwner,
            _args.l2TokenProxyBytecodeHash,
            _args.legacySharedBridge,
            _args.l2TokenBeacon,
            _args.contractsDeployedAlready
        );
    }

    function forceDeployMessageRoot() internal {
        new MessageRoot(IBridgehub(L2_BRIDGEHUB_ADDR));
        forceDeployWithConstructor("MessageRoot", L2_MESSAGE_ROOT_ADDR, abi.encode(L2_BRIDGEHUB_ADDR));
    }

    function forceDeployBridgehub(
        uint256 _l1ChainId,
        uint256 _eraChainId,
        address _aliasedOwner,
        address _l1AssetRouter,
        address _legacySharedBridge,
        address _l1CtmDeployer
    ) internal {
        new Bridgehub(_l1ChainId, _aliasedOwner, 100);
        forceDeployWithConstructor("Bridgehub", L2_BRIDGEHUB_ADDR, abi.encode(_l1ChainId, _aliasedOwner, 100));
        Bridgehub bridgehub = Bridgehub(L2_BRIDGEHUB_ADDR);
        vm.prank(_aliasedOwner);
        bridgehub.setAddresses(
            L2_ASSET_ROUTER_ADDR,
            ICTMDeploymentTracker(_l1CtmDeployer),
            IMessageRoot(L2_MESSAGE_ROOT_ADDR)
        );
    }

    /// @notice Deploys the L2AssetRouter contract.
    /// @param _l1ChainId The chain ID of the L1 chain.
    /// @param _eraChainId The chain ID of the era chain.
    /// @param _l1AssetRouter The address of the L1 asset router.
    /// @param _legacySharedBridge The address of the legacy shared bridge.
    function forceDeployAssetRouter(
        uint256 _l1ChainId,
        uint256 _eraChainId,
        address _aliasedOwner,
        address _l1AssetRouter,
        address _legacySharedBridge
    ) internal {
        // to ensure that the bytecode is known
        bytes32 ethAssetId = DataEncoding.encodeNTVAssetId(_l1ChainId, ETH_TOKEN_ADDRESS);
        {
            new L2AssetRouter(_l1ChainId, _eraChainId, _l1AssetRouter, _legacySharedBridge, ethAssetId, _aliasedOwner);
        }
        forceDeployWithConstructor(
            "L2AssetRouter",
            L2_ASSET_ROUTER_ADDR,
            abi.encode(_l1ChainId, _eraChainId, _l1AssetRouter, _legacySharedBridge, ethAssetId, _aliasedOwner)
        );
    }

    /// @notice Deploys the L2NativeTokenVault contract.
    /// @param _l1ChainId The chain ID of the L1 chain.
    /// @param _aliasedOwner The address of the aliased owner.
    /// @param _l2TokenProxyBytecodeHash The hash of the L2 token proxy bytecode.
    /// @param _legacySharedBridge The address of the legacy shared bridge.
    /// @param _l2TokenBeacon The address of the L2 token beacon.
    /// @param _contractsDeployedAlready Whether the contracts are deployed already.
    function forceDeployNativeTokenVault(
        uint256 _l1ChainId,
        address _aliasedOwner,
        bytes32 _l2TokenProxyBytecodeHash,
        address _legacySharedBridge,
        address _l2TokenBeacon,
        bool _contractsDeployedAlready
    ) internal {
        // to ensure that the bytecode is known
        bytes32 ethAssetId = DataEncoding.encodeNTVAssetId(_l1ChainId, ETH_TOKEN_ADDRESS);
        {
            new L2NativeTokenVault({
                _l1ChainId: _l1ChainId,
                _aliasedOwner: _aliasedOwner,
                _l2TokenProxyBytecodeHash: _l2TokenProxyBytecodeHash,
                _legacySharedBridge: _legacySharedBridge,
                _bridgedTokenBeacon: _l2TokenBeacon,
                _contractsDeployedAlready: _contractsDeployedAlready,
                _wethToken: address(0),
                _baseTokenAssetId: ethAssetId
            });
        }
        forceDeployWithConstructor(
            "L2NativeTokenVault",
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encode(
                _l1ChainId,
                _aliasedOwner,
                _l2TokenProxyBytecodeHash,
                _legacySharedBridge,
                _l2TokenBeacon,
                _contractsDeployedAlready,
                address(0),
                ethAssetId
            )
        );
    }

    function forceDeployWithConstructor(
        string memory _contractName,
        address _address,
        bytes memory _constructorArgs
    ) public {
        bytes memory bytecode = readZKFoundryBytecodeL1(string.concat(_contractName, ".sol"), _contractName);

        bytes32 bytecodehash = L2ContractHelper.hashL2Bytecode(bytecode);

        IContractDeployer.ForceDeployment[] memory deployments = new IContractDeployer.ForceDeployment[](1);
        deployments[0] = IContractDeployer.ForceDeployment({
            bytecodeHash: bytecodehash,
            newAddress: _address,
            callConstructor: true,
            value: 0,
            input: _constructorArgs
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
