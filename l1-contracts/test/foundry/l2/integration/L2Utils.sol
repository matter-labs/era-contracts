// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";

import "forge-std/console.sol";

import {L2_ASSET_ROUTER_ADDR, L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_FORCE_DEPLOYER_ADDR, L2_INTEROP_CENTER_ADDR, L2_INTEROP_HANDLER_ADDR, L2_ASSET_TRACKER_ADDR, GW_ASSET_TRACKER_ADDR, L2_INTEROP_ROOT_STORAGE, L2_MESSAGE_ROOT_ADDR, L2_MESSAGE_VERIFICATION, L2_NATIVE_TOKEN_VAULT_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IContractDeployer, L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";

import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL2SharedBridgeLegacy} from "contracts/bridge/interfaces/IL2SharedBridgeLegacy.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {IMessageRoot} from "contracts/core/message-root/IMessageRoot.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";

import {L2MessageVerification} from "contracts/interop/L2MessageVerification.sol";
import {DummyL2InteropRootStorage} from "contracts/dev-contracts/test/DummyL2InteropRootStorage.sol";
import {InteropCenter} from "contracts/interop/InteropCenter.sol";
import {InteropHandler} from "contracts/interop/InteropHandler.sol";
import {L2AssetTracker} from "contracts/bridge/asset-tracker/L2AssetTracker.sol";
import {GWAssetTracker} from "contracts/bridge/asset-tracker/GWAssetTracker.sol";
// import {InteropAccount} from "contracts/interop/InteropAccount.sol";
import {L2Bridgehub} from "contracts/core/bridgehub/L2Bridgehub.sol";
import {IL2Bridgehub} from "contracts/core/bridgehub/IL2Bridgehub.sol";
import {L2MessageRoot} from "contracts/core/message-root/L2MessageRoot.sol";

import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {DeployFailed} from "contracts/common/L1ContractErrors.sol";

import {SystemContractsArgs} from "../../l1/integration/l2-tests-abstract/_SharedL2ContractDeployer.sol";

import {Utils} from "deploy-scripts/utils/Utils.sol";
import {L2ChainAssetHandler} from "contracts/core/chain-asset-handler/L2ChainAssetHandler.sol";
import {TokenMetadata, TokenBridgingData} from "contracts/common/Messaging.sol";

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
        forceDeployBridgehub(_args);
        forceDeployMessageRoot(_args);
        forceDeployChainAssetHandler(_args);
        forceDeployAssetRouter(_args);
        forceDeployNativeTokenVault(_args);
        forceDeployL2MessageVerification(_args);
        forceDeployL2InteropRootStorage(_args);
        forceDeployInteropCenter(_args);
        forceDeployInteropHandler(_args);
        forceDeployL2AssetTracker(_args);
        forceDeployGWAssetTracker(_args);

        initializeBridgehub(_args);
    }

    function forceDeployMessageRoot(SystemContractsArgs memory _args) internal {
        new L2MessageRoot();
        forceDeployWithoutConstructor("L2MessageRoot", L2_MESSAGE_ROOT_ADDR);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2MessageRoot(L2_MESSAGE_ROOT_ADDR).initL2(_args.l1ChainId, _args.gatewayChainId);
    }

    function forceDeployBridgehub(SystemContractsArgs memory _args) internal {
        new L2Bridgehub();
        forceDeployWithoutConstructor("L2Bridgehub", L2_BRIDGEHUB_ADDR);
        L2Bridgehub bridgehub = L2Bridgehub(L2_BRIDGEHUB_ADDR);
    }

    function initializeBridgehub(SystemContractsArgs memory _args) internal {
        L2Bridgehub bridgehub = L2Bridgehub(L2_BRIDGEHUB_ADDR);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        bridgehub.initL2(_args.l1ChainId, _args.aliasedOwner, 100);
        vm.prank(_args.aliasedOwner);
        bridgehub.setAddresses(
            L2_ASSET_ROUTER_ADDR,
            ICTMDeploymentTracker(_args.l1CtmDeployer),
            IMessageRoot(L2_MESSAGE_ROOT_ADDR),
            L2_CHAIN_ASSET_HANDLER_ADDR,
            address(0)
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

    function forceDeployL2MessageVerification(SystemContractsArgs memory _args) internal {
        new L2MessageVerification();

        forceDeployWithoutConstructor("L2MessageVerification", address(L2_MESSAGE_VERIFICATION));
    }

    function forceDeployL2InteropRootStorage(SystemContractsArgs memory _args) internal {
        new DummyL2InteropRootStorage();

        forceDeployWithoutConstructor("DummyL2InteropRootStorage", address(L2_INTEROP_ROOT_STORAGE));
    }

    function forceDeployInteropCenter(SystemContractsArgs memory _args) internal {
        new InteropCenter();

        forceDeployWithoutConstructor("InteropCenter", L2_INTEROP_CENTER_ADDR);
        InteropCenter interopCenter = InteropCenter(L2_INTEROP_CENTER_ADDR);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        InteropCenter(L2_INTEROP_CENTER_ADDR).initL2(_args.l1ChainId, _args.aliasedOwner);
    }

    function forceDeployInteropHandler(SystemContractsArgs memory _args) internal {
        new InteropHandler();

        forceDeployWithoutConstructor("InteropHandler", L2_INTEROP_HANDLER_ADDR);
        InteropHandler interopHandler = InteropHandler(L2_INTEROP_HANDLER_ADDR);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        interopHandler.initL2(_args.l1ChainId);
    }

    function forceDeployL2AssetTracker(SystemContractsArgs memory _args) internal {
        new L2AssetTracker();

        forceDeployWithoutConstructor("L2AssetTracker", L2_ASSET_TRACKER_ADDR);
    }

    function forceDeployGWAssetTracker(SystemContractsArgs memory _args) internal {
        new GWAssetTracker();

        forceDeployWithoutConstructor("GWAssetTracker", GW_ASSET_TRACKER_ADDR);
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
            IL1AssetRouter(_args.l1AssetRouter),
            IL2SharedBridgeLegacy(_args.legacySharedBridge),
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
            TokenBridgingData({assetId: ethAssetId, originChainId: _args.l1ChainId, originToken: ETH_TOKEN_ADDRESS}),
            TokenMetadata({name: "Ether", symbol: "ETH", decimals: 18})
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
        console.logBytes32(bytecodehash);

        prankOrBroadcast(false, L2_FORCE_DEPLOYER_ADDR);
        IContractDeployer(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR).forceDeployOnAddresses(deployments);

        // In test environment, we need to actually etch the bytecode at the target address
        vm.etch(_address, bytecode);
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
