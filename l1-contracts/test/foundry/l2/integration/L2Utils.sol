// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import "forge-std/console.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_BRIDGEHUB_ADDR, L2_MESSAGE_ROOT_ADDR, L2_INTEROP_CENTER_ADDR, L2_INTEROP_HANDLER_ADDR, L2_INTEROP_ACCOUNT_ADDR, L2_FORCE_DEPLOYER_ADDR} from "../../../../contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IContractDeployer, L2ContractHelper} from "../../../../contracts/common/l2-helpers/L2ContractHelper.sol";

import {L2AssetRouter} from "../../../../contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2NativeTokenVault} from "../../../../contracts/bridge/ntv/L2NativeTokenVault.sol";
import {L2SharedBridgeLegacy} from "../../../../contracts/bridge/L2SharedBridgeLegacy.sol";
import {IMessageRoot} from "../../../../contracts/bridgehub/IMessageRoot.sol";
import {ICTMDeploymentTracker} from "../../../../contracts/bridgehub/ICTMDeploymentTracker.sol";
import {Bridgehub, IBridgehub} from "../../../../contracts/bridgehub/Bridgehub.sol";
import {InteropCenter, IInteropCenter} from "../../../../contracts/bridgehub/InteropCenter.sol";
import {InteropHandler, IInteropHandler} from "../../../../contracts/bridgehub/InteropHandler.sol";
import {InteropAccount} from "../../../../contracts/bridgehub/InteropAccount.sol";
import {MessageRoot} from "../../../../contracts/bridgehub/MessageRoot.sol";

import {ETH_TOKEN_ADDRESS} from "../../../../contracts/common/Config.sol";

import {DataEncoding} from "../../../../contracts/common/libraries/DataEncoding.sol";
import {BridgedStandardERC20} from "../../../../contracts/bridge/BridgedStandardERC20.sol";

import {SystemContractsCaller} from "../../../../contracts/common/l2-helpers/SystemContractsCaller.sol";
import {DeployFailed} from "../../../../contracts/common/L1ContractErrors.sol";
import {SystemContractsArgs} from "../../l1/integration/l2-tests-abstract/_SharedL2ContractDeployer.sol";

library L2Utils {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    /// rich account on era_test_node
    address internal constant RANDOM_ADDRESS = address(0xBC989fDe9e54cAd2aB4392Af6dF60f04873A033A);

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
        if (_args.broadcast) {
            // we will broadcast from this address, it needs funds.
            _args.aliasedOwner = RANDOM_ADDRESS;
        }
        forceDeployMessageRoot(_args);
        forceDeployBridgehub(_args);
        forceDeployAssetRouter(_args);
        forceDeployNativeTokenVault(_args);
        forceDeployInteropCenter(_args);
        forceDeployInteropAccount(_args);
        forceDeployInteropHandler(_args);
    }

    function forceDeployMessageRoot(SystemContractsArgs memory _args) internal {
        prankOrBroadcast(_args.broadcast, RANDOM_ADDRESS);
        new MessageRoot(IBridgehub(L2_BRIDGEHUB_ADDR));
        forceDeployWithConstructor("MessageRoot", L2_MESSAGE_ROOT_ADDR, abi.encode(L2_BRIDGEHUB_ADDR), _args.broadcast);
    }

    function forceDeployBridgehub(SystemContractsArgs memory _args) internal {
        prankOrBroadcast(_args.broadcast, RANDOM_ADDRESS);
        new Bridgehub(_args.l1ChainId, _args.aliasedOwner, 100);
        forceDeployWithConstructor(
            "Bridgehub",
            L2_BRIDGEHUB_ADDR,
            abi.encode(_args.l1ChainId, _args.aliasedOwner, 100),
            _args.broadcast
        );
        Bridgehub bridgehub = Bridgehub(L2_BRIDGEHUB_ADDR);
        prankOrBroadcast(_args.broadcast, _args.aliasedOwner);

        bridgehub.setAddresses(
            L2_ASSET_ROUTER_ADDR,
            ICTMDeploymentTracker(_args.l1CtmDeployer),
            IMessageRoot(L2_MESSAGE_ROOT_ADDR),
            L2_INTEROP_CENTER_ADDR
        );
    }

    function forceDeployInteropCenter(SystemContractsArgs memory _args) internal {
        prankOrBroadcast(_args.broadcast, RANDOM_ADDRESS);
        new InteropCenter(IBridgehub(L2_BRIDGEHUB_ADDR), _args.l1ChainId, _args.aliasedOwner);
        forceDeployWithConstructor(
            "InteropCenter",
            L2_INTEROP_CENTER_ADDR,
            abi.encode(L2_BRIDGEHUB_ADDR, _args.l1ChainId, _args.aliasedOwner),
            _args.broadcast
        );
        InteropCenter interopCenter = InteropCenter(L2_INTEROP_CENTER_ADDR);
        prankOrBroadcast(_args.broadcast, _args.aliasedOwner);
        interopCenter.setAddresses(L2_ASSET_ROUTER_ADDR);
    }

    function forceDeployInteropAccount(SystemContractsArgs memory _args) internal {
        prankOrBroadcast(_args.broadcast, RANDOM_ADDRESS);
        new InteropAccount();
        forceDeployWithConstructor("InteropAccount", L2_INTEROP_ACCOUNT_ADDR, abi.encode(), _args.broadcast);
        InteropCenter interopCenter = InteropCenter(L2_INTEROP_CENTER_ADDR);
    }

    function forceDeployInteropHandler(SystemContractsArgs memory _args) internal {
        prankOrBroadcast(_args.broadcast, RANDOM_ADDRESS);
        new InteropHandler();
        forceDeployWithConstructor("InteropHandler", L2_INTEROP_HANDLER_ADDR, abi.encode(), _args.broadcast);
        InteropHandler interopHandler = InteropHandler(L2_INTEROP_HANDLER_ADDR);
        prankOrBroadcast(_args.broadcast, L2_FORCE_DEPLOYER_ADDR);
        interopHandler.setInteropAccountBytecode();
    }

    /// @notice Deploys the L2AssetRouter contract.
    // / @param _l1ChainId The chain ID of the L1 chain.
    // / @param _eraChainId The chain ID of the era chain.
    // / @param _l1AssetRouter The address of the L1 asset router.
    // / @param _legacySharedBridge The address of the legacy shared bridge.
    function forceDeployAssetRouter(SystemContractsArgs memory _args) internal {
        // to ensure that the bytecode is known
        bytes32 ethAssetId = DataEncoding.encodeNTVAssetId(_args.l1ChainId, ETH_TOKEN_ADDRESS);
        {
            prankOrBroadcast(_args.broadcast, RANDOM_ADDRESS);
            new L2AssetRouter(
                _args.l1ChainId,
                _args.eraChainId,
                _args.l1AssetRouter,
                _args.legacySharedBridge,
                ethAssetId,
                _args.aliasedOwner
            );
        }
        forceDeployWithConstructor(
            "L2AssetRouter",
            L2_ASSET_ROUTER_ADDR,
            abi.encode(
                _args.l1ChainId,
                _args.eraChainId,
                _args.l1AssetRouter,
                _args.legacySharedBridge,
                ethAssetId,
                _args.aliasedOwner
            ),
            _args.broadcast
        );
    }

    /// @notice Deploys the L2NativeTokenVault contract.
    // / @param _l1ChainId The chain ID of the L1 chain.
    // / @param _aliasedOwner The address of the aliased owner.
    // / @param _l2TokenProxyBytecodeHash The hash of the L2 token proxy bytecode.
    // / @param _legacySharedBridge The address of the legacy shared bridge.
    // / @param _l2TokenBeacon The address of the L2 token beacon.
    // / @param _contractsDeployedAlready Whether the contracts are deployed already.
    function forceDeployNativeTokenVault(SystemContractsArgs memory _args) internal {
        // to ensure that the bytecode is known
        bytes32 ethAssetId = DataEncoding.encodeNTVAssetId(_args.l1ChainId, ETH_TOKEN_ADDRESS);
        {
            prankOrBroadcast(_args.broadcast, RANDOM_ADDRESS);
            new L2NativeTokenVault({
                _l1ChainId: _args.l1ChainId,
                _aliasedOwner: _args.aliasedOwner,
                _l2TokenProxyBytecodeHash: _args.l2TokenProxyBytecodeHash,
                _legacySharedBridge: _args.legacySharedBridge,
                _bridgedTokenBeacon: _args.l2TokenBeacon,
                _contractsDeployedAlready: _args.contractsDeployedAlready,
                _wethToken: address(0),
                _baseTokenAssetId: ethAssetId
            });
        }
        forceDeployWithConstructor(
            "L2NativeTokenVault",
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encode(
                _args.l1ChainId,
                _args.aliasedOwner,
                _args.l2TokenProxyBytecodeHash,
                _args.legacySharedBridge,
                _args.l2TokenBeacon,
                _args.contractsDeployedAlready,
                address(0),
                ethAssetId
            ),
            _args.broadcast
        );
    }

    function forceDeployWithConstructor(
        string memory _contractName,
        address _address,
        bytes memory _constructorArgs,
        bool _broadcast
    ) public {
        console.log(string.concat("Force deploying ", _contractName, string(abi.encode(_address))));
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
        console.logBytes32(bytecodehash);

        prankOrBroadcast(_broadcast, RANDOM_ADDRESS);
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

    function prankOrBroadcast(bool _broadcast, address _from) public {
        if (_broadcast) {
            if (_from != L2_FORCE_DEPLOYER_ADDR) {
                vm.broadcast(_from);
            } else {
                vm.broadcast();
            }
        } else {
            vm.prank(_from);
        }
    }
}
