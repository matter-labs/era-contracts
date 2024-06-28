// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
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
import {DeployL1Utils} from "./_DeployL1.s.sol";

contract DeployL1Script is Script, Ownable2StepUpgradeable {
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
        DeployL1Utils._initializeConfig();
    }

    function instantiateCreate2Factory() internal {
        DeployL1Utils._instantiateCreate2Factory();
    }

    function deployIfNeededMulticall3() internal {
        DeployL1Utils._deployIfNeededMulticall3();
    }

    function deployVerifier() internal {
        DeployL1Utils._deployVerifier();
    }

    function deployDefaultUpgrade() internal {
        DeployL1Utils._deployDefaultUpgrade();
    }

    function deployGenesisUpgrade() internal {
        DeployL1Utils._deployGenesisUpgrade();
    }

    function deployValidatorTimelock() internal {
        DeployL1Utils._deployValidatorTimelock();
    }

    function deployGovernance() internal {
        DeployL1Utils._deployGovernance();
    }

    function deployTransparentProxyAdmin() internal {
        vm.startBroadcast(msg.sender);
        DeployL1Utils._deployTransparentProxyAdmin();
        vm.stopBroadcast();
    }

    function deployBridgehubContract() internal {
        DeployL1Utils._deployBridgehubContract();
    }

    function deployBlobVersionedHashRetriever() internal {
        DeployL1Utils._deployBlobVersionedHashRetriever();
    }

    function deployStateTransitionManagerContract() internal {
        deployStateTransitionDiamondFacets();
        deployStateTransitionManagerImplementation();
        deployStateTransitionManagerProxy();
        registerStateTransitionManager();
    }

    function deployStateTransitionDiamondFacets() internal {
        DeployL1Utils._deployStateTransitionDiamondFacets();
    }

    function deployStateTransitionManagerImplementation() internal {
        DeployL1Utils._deployStateTransitionManagerImplementation();
    }

    function deployStateTransitionManagerProxy() public returns (address) {
        address contractAddress = DeployL1Utils._deployStateTransitionManagerProxy();
        return contractAddress;
    }

    function registerStateTransitionManager() internal {
        vm.broadcast(msg.sender);
        DeployL1Utils._registerStateTransitionManager();
        console.log("StateTransitionManager registered");
    }

    function setStateTransitionManagerInValidatorTimelock() internal {
        vm.broadcast(msg.sender);
        DeployL1Utils._setStateTransitionManagerInValidatorTimelock();
        console.log("StateTransitionManager set in ValidatorTimelock");
    }

    function deployDiamondProxy() internal {
        DeployL1Utils._deployDiamondProxy();
    }

    function deploySharedBridgeContracts() internal {
        deploySharedBridgeImplementation();
        deploySharedBridgeProxy();
        registerSharedBridge();
    }

    function deploySharedBridgeImplementation() internal {
        DeployL1Utils._deploySharedBridgeImplementation();
    }

    function deploySharedBridgeProxy() internal {
        DeployL1Utils._deploySharedBridgeProxy();
    }

    function registerSharedBridge() internal {
        vm.startBroadcast(msg.sender);
        DeployL1Utils._registerSharedBridge();
        vm.stopBroadcast();
    }

    function deployErc20BridgeImplementation() internal {
        DeployL1Utils._deployErc20BridgeImplementation();
    }

    function deployErc20BridgeProxy() internal {
        DeployL1Utils._deployErc20BridgeProxy();
    }

    function updateSharedBridge() internal {
        vm.broadcast(msg.sender);
        DeployL1Utils._updateSharedBridge();
    }

    function updateOwners() internal {
        vm.startBroadcast(msg.sender);
        DeployL1Utils._updateOwners();
        vm.stopBroadcast();
        console.log("Owners updated");
    }

    function saveOutput() internal {
        DeployL1Utils._saveOutput();
    }

    function deployViaCreate2(bytes memory _bytecode) internal returns (address) {
        address contractAddress = DeployL1Utils._deployViaCreate21(_bytecode);

        if (contractAddress == vm.addr(1)) {
            vm.broadcast();
            contractAddress = DeployL1Utils._deployViaCreate22(_bytecode);
            return contractAddress;
        }

        return contractAddress;
    }
}
