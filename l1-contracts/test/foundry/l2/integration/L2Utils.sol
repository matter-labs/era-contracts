// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, Test, stdStorage, stdToml} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {L2_ASSET_ROUTER_ADDR, L2_ASSET_TRACKER_ADDR, L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_FORCE_DEPLOYER_ADDR, L2_INTEROP_CENTER_ADDR, L2_INTEROP_HANDLER_ADDR, L2_INTEROP_ROOT_STORAGE, L2_MESSAGE_VERIFICATION, L2_MESSAGE_ROOT_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IContractDeployer, L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";

import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {Bridgehub, IBridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {ChainAssetHandler} from "contracts/bridgehub/ChainAssetHandler.sol";
import {MessageRoot} from "contracts/bridgehub/MessageRoot.sol";
import {L2MessageVerification} from "contracts/interop/L2MessageVerification.sol";
import {DummyL2InteropRootStorage} from "contracts/dev-contracts/test/DummyL2InteropRootStorage.sol";
import {IInteropCenter, InteropCenter} from "contracts/interop/InteropCenter.sol";
import {IInteropHandler, InteropHandler} from "contracts/interop/InteropHandler.sol";
// import {InteropAccount} from "contracts/interop/InteropAccount.sol";

import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {SystemContractsCaller} from "contracts/common/l2-helpers/SystemContractsCaller.sol";
import {DeployFailed} from "contracts/common/L1ContractErrors.sol";
import {L2_INTEROP_ACCOUNT_ADDR, L2_STANDARD_TRIGGER_ACCOUNT_ADDR} from "../../l1/integration/l2-tests-abstract/Utils.sol";
import {SystemContractsArgs} from "../../l1/integration/l2-tests-abstract/_SharedL2ContractDeployer.sol";
import {ContractsBytecodesLib} from "deploy-scripts/ContractsBytecodesLib.sol";
import {Utils} from "deploy-scripts/Utils.sol";

library L2Utils {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    /// rich account on era_test_node
    address internal constant RANDOM_ADDRESS = address(0xBC989fDe9e54cAd2aB4392Af6dF60f04873A033A);
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
        if (_args.broadcast) {
            // we will broadcast from this address, it needs funds.
            _args.aliasedOwner = RANDOM_ADDRESS;
        }
        forceDeployMessageRoot(_args);
        forceDeployBridgehub(_args);
        forceDeployChainAssetHandler(_args);
        forceDeployAssetRouter(_args);
        forceDeployNativeTokenVault(_args);
        forceDeployL2MessageVerification(_args);
        forceDeployL2InteropRootStorage(_args);
        forceDeployInteropCenter(_args);
        forceDeployInteropHandler(_args);
    }

    function forceDeployMessageRoot(SystemContractsArgs memory _args) internal {
        prankOrBroadcast(_args.broadcast, RANDOM_ADDRESS);
        new MessageRoot(IBridgehub(L2_BRIDGEHUB_ADDR), L1_CHAIN_ID, 1);
        forceDeployWithConstructor(
            "MessageRoot",
            L2_MESSAGE_ROOT_ADDR,
            abi.encode(L2_BRIDGEHUB_ADDR, L1_CHAIN_ID),
            _args.broadcast
        );
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
            L2_CHAIN_ASSET_HANDLER_ADDR,
            L2_INTEROP_CENTER_ADDR,
            address(0x000000000000000000000000000000000002000a)
        );
    }

    function forceDeployChainAssetHandler(SystemContractsArgs memory _args) internal {
        new ChainAssetHandler(
            _args.l1ChainId,
            _args.aliasedOwner,
            IBridgehub(L2_BRIDGEHUB_ADDR),
            L2_ASSET_ROUTER_ADDR,
            L2_ASSET_TRACKER_ADDR,
            IMessageRoot(L2_MESSAGE_ROOT_ADDR),
            address(0)
        );
        forceDeployWithConstructor(
            "ChainAssetHandler",
            L2_CHAIN_ASSET_HANDLER_ADDR,
            abi.encode(
                _args.l1ChainId,
                _args.aliasedOwner,
                L2_BRIDGEHUB_ADDR,
                L2_ASSET_ROUTER_ADDR,
                L2_ASSET_TRACKER_ADDR,
                L2_MESSAGE_ROOT_ADDR,
                address(0)
            ),
            _args.broadcast
        );
    }

    function forceDeployL2MessageVerification(SystemContractsArgs memory _args) internal {
        prankOrBroadcast(_args.broadcast, RANDOM_ADDRESS);
        new L2MessageVerification();
        forceDeployWithConstructor(
            "L2MessageVerification",
            address(L2_MESSAGE_VERIFICATION),
            abi.encode(),
            _args.broadcast
        );
    }

    function forceDeployL2InteropRootStorage(SystemContractsArgs memory _args) internal {
        prankOrBroadcast(_args.broadcast, RANDOM_ADDRESS);
        new DummyL2InteropRootStorage();
        forceDeployWithConstructor(
            "DummyL2InteropRootStorage",
            address(L2_INTEROP_ROOT_STORAGE),
            abi.encode(),
            _args.broadcast
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
        interopCenter.setAddresses(L2_ASSET_ROUTER_ADDR, L2_ASSET_TRACKER_ADDR);
    }

    function forceDeployInteropHandler(SystemContractsArgs memory _args) internal {
        prankOrBroadcast(_args.broadcast, RANDOM_ADDRESS);
        new InteropHandler();
        forceDeployWithConstructor("InteropHandler", L2_INTEROP_HANDLER_ADDR, abi.encode(), _args.broadcast);
        InteropHandler interopHandler = InteropHandler(L2_INTEROP_HANDLER_ADDR);
    }

    /// @notice Deploys the L2AssetRouter contract.
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
        bytes memory bytecode = Utils.readZKFoundryBytecodeL1(string.concat(_contractName, ".sol"), _contractName);

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

        prankOrBroadcast(_broadcast, L2_FORCE_DEPLOYER_ADDR);
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

    // function getCreationCode(string memory _contractName) internal view returns (bytes memory) {
    //     if (keccak256(abi.encode(_contractName)) == keccak256(abi.encode("L2StandardTriggerAccount"))) {
    //         return
    //             abi.encodePacked(
    //                 readZKFoundryBytecodeSystemContracts(string.concat(_contractName, ".sol"), _contractName)
    //             );
    //     } else if (keccak256(abi.encode(_contractName)) == keccak256(abi.encode("InteropAccount"))) {
    //         return
    //             abi.encodePacked(
    //                 readZKFoundryBytecodeSystemContracts(string.concat(_contractName, ".sol"), _contractName)
    //             );
    //     }
    //     bytes memory bytecode = readZKFoundryBytecodeL1(string.concat(_contractName, ".sol"), _contractName);
    //     return bytecode;
    // }

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
