// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Utils} from "./Utils.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";
import {Verifier} from "contracts/state-transition/Verifier.sol";
import {TestnetVerifier} from "contracts/state-transition/TestnetVerifier.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {GenesisUpgrade} from "contracts/upgrades/GenesisUpgrade.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {StateTransitionManager} from "contracts/state-transition/StateTransitionManager.sol";
import {StateTransitionManagerInitializeData, ChainCreationParams} from "contracts/state-transition/IStateTransitionManager.sol";
import {IStateTransitionManager} from "contracts/state-transition/IStateTransitionManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {_DeployL1Script} from "./_DeployL1.s.sol";

contract DeployL1Script is _DeployL1Script {
    using stdToml for string;

    function run() public {
        console.log("Deploying L1 contracts");

        initializeConfig();

        instantiateCreate2Factory();
        deployIfNeededMulticall3();

        deployVerifier();

        deployDefaultUpgrade();
        deployGenesisUpgrade();
        deployValidatorTimelock();

        deployGovernance();
        deployTransparentProxyAdmin();
        deployBridgehubContract();
        deployBlobVersionedHashRetriever();
        deployStateTransitionManagerContract();
        setStateTransitionManagerInValidatorTimelock();

        deployDiamondProxy();

        deploySharedBridgeContracts();
        deployErc20BridgeImplementation();
        deployErc20BridgeProxy();
        updateSharedBridge();

        updateOwners();

        saveOutput();
    }

    function initializeConfig() internal {
        _initializeConfig();
    }

    function instantiateCreate2Factory() internal {
        _instantiateCreate2Factory();
    }

    function deployIfNeededMulticall3() internal {
        // Multicall3 is already deployed on public networks
        _deployIfNeededMulticall3();
    }

    function deployVerifier() internal {
        _deployVerifier();
    }

    function deployDefaultUpgrade() internal {
        _deployDefaultUpgrade();
    }

    function deployGenesisUpgrade() internal {
        _deployGenesisUpgrade();
    }

    function deployValidatorTimelock() internal {
        _deployValidatorTimelock();
    }

    function deployGovernance() internal {
        _deployGovernance();
    }

    function deployTransparentProxyAdmin() internal {
        vm.startBroadcast(msg.sender);
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        proxyAdmin.transferOwnership(addresses.governance);
        vm.stopBroadcast();
        console.log("Transparent Proxy Admin deployed at:", address(proxyAdmin));
        addresses.transparentProxyAdmin = address(proxyAdmin);
    }

    function deployBridgehubContract() internal {
        _deployBridgehubContract();
    }

    function deployBlobVersionedHashRetriever() internal {
        // solc contracts/state-transition/utils/blobVersionedHashRetriever.yul --strict-assembly --bin
        _deployBlobVersionedHashRetriever();
    }

    function deployStateTransitionManagerContract() internal {
        deployStateTransitionDiamondFacets();
        deployStateTransitionManagerImplementation();
        deployStateTransitionManagerProxy();
        registerStateTransitionManager();
    }

    function deployStateTransitionDiamondFacets() internal {
        _deployStateTransitionDiamondFacets();
    }

    function deployStateTransitionManagerImplementation() internal {
        _deployStateTransitionManagerImplementation();
    }

    function deployStateTransitionManagerProxy() internal {
        _deployStateTransitionManagerProxy();
    }

    function registerStateTransitionManager() internal {
        Bridgehub bridgehub = Bridgehub(addresses.bridgehub.bridgehubProxy);
        vm.broadcast(msg.sender);
        bridgehub.addStateTransitionManager(addresses.stateTransition.stateTransitionProxy);
        console.log("StateTransitionManager registered");
    }

    function setStateTransitionManagerInValidatorTimelock() internal {
        ValidatorTimelock validatorTimelock = ValidatorTimelock(addresses.validatorTimelock);
        vm.broadcast(msg.sender);
        validatorTimelock.setStateTransitionManager(
            IStateTransitionManager(addresses.stateTransition.stateTransitionProxy)
        );
        console.log("StateTransitionManager set in ValidatorTimelock");
    }

    function deployDiamondProxy() internal {
        _deployDiamondProxy();
    }

    function deploySharedBridgeContracts() internal {
        deploySharedBridgeImplementation();
        deploySharedBridgeProxy();
        registerSharedBridge();
    }

    function deploySharedBridgeImplementation() internal {
        _deploySharedBridgeImplementation();
    }

    function deploySharedBridgeProxy() internal {
        _deploySharedBridgeProxy();
    }

    function registerSharedBridge() internal {
        Bridgehub bridgehub = Bridgehub(addresses.bridgehub.bridgehubProxy);
        vm.startBroadcast(msg.sender);
        bridgehub.addToken(ADDRESS_ONE);
        bridgehub.setSharedBridge(addresses.bridges.sharedBridgeProxy);
        vm.stopBroadcast();
        console.log("SharedBridge registered");
    }

    function deployErc20BridgeImplementation() internal {
        _deployErc20BridgeImplementation();
    }

    function deployErc20BridgeProxy() internal {
        _deployErc20BridgeProxy();
    }

    function updateSharedBridge() internal {
        L1SharedBridge sharedBridge = L1SharedBridge(addresses.bridges.sharedBridgeProxy);
        vm.broadcast(msg.sender);
        sharedBridge.setL1Erc20Bridge(addresses.bridges.erc20BridgeProxy);
        console.log("SharedBridge updated with ERC20Bridge address");
    }

    function updateOwners() internal {
        vm.startBroadcast(msg.sender);

        ValidatorTimelock validatorTimelock = ValidatorTimelock(addresses.validatorTimelock);
        validatorTimelock.transferOwnership(config.ownerAddress);

        Bridgehub bridgehub = Bridgehub(addresses.bridgehub.bridgehubProxy);
        bridgehub.transferOwnership(addresses.governance);

        L1SharedBridge sharedBridge = L1SharedBridge(addresses.bridges.sharedBridgeProxy);
        sharedBridge.transferOwnership(addresses.governance);

        vm.stopBroadcast();

        console.log("Owners updated");
    }

    function saveOutput() internal {
        _saveOutput();
    }

    function deployViaCreate2(bytes memory _bytecode) internal returns (address) {
        return _deployViaCreate2(_bytecode);
    }
}