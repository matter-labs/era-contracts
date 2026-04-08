// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Facets, Verifiers, StateTransitionDeployedAddresses} from "contracts/common/StateTransitionTypes.sol";

import {DAContracts} from "contracts/common/StateTransitionTypes.sol";
import {
    DeployedContracts,
    GatewayProxyAdminDeployerResult,
    GatewayValidatorTimelockDeployerResult,
    GatewayCTMFinalResult
} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployer.sol";

/// @notice Struct to hold all deployer results for testing
struct AllDeployerResults {
    DAContracts daResult;
    GatewayProxyAdminDeployerResult proxyAdminResult;
    GatewayValidatorTimelockDeployerResult validatorTimelockResult;
    Verifiers verifiersResult;
    GatewayCTMFinalResult ctmResult;
}

/// @notice Library for comparing DeployedContracts structs in tests
library DeployedContractsComparator {
    function compareDeployedContracts(DeployedContracts memory a, DeployedContracts memory b) internal pure {
        require(a.multicall3 == b.multicall3, "multicall3 differs");
        compareStateTransitionDeployedAddresses(a.stateTransition, b.stateTransition);
        compareDAContracts(a.daContracts, b.daContracts);
        compareBytes(a.diamondCutData, b.diamondCutData, "diamondCutData");
    }

    function compareStateTransitionDeployedAddresses(
        StateTransitionDeployedAddresses memory a,
        StateTransitionDeployedAddresses memory b
    ) internal pure {
        require(a.verifiers.verifier == b.verifiers.verifier, "verifier differs");
        require(a.verifiers.verifierFflonk == b.verifiers.verifierFflonk, "verifierFflonk differs");
        require(a.verifiers.verifierPlonk == b.verifiers.verifierPlonk, "verifierPlonk differs");
        compareFacets(a.facets, b.facets);
        require(a.genesisUpgrade == b.genesisUpgrade, "genesisUpgrade differs");
        require(
            a.implementations.validatorTimelock == b.implementations.validatorTimelock,
            "validatorTimelockImplementation differs"
        );
        require(a.proxies.validatorTimelock == b.proxies.validatorTimelock, "validatorTimelockProxy differs");
        require(a.chainTypeManagerProxyAdmin == b.chainTypeManagerProxyAdmin, "chainTypeManagerProxyAdmin differs");
        require(
            a.implementations.serverNotifier == b.implementations.serverNotifier,
            "serverNotifierImplementation differs"
        );
        require(a.proxies.serverNotifier == b.proxies.serverNotifier, "serverNotifier proxy differs");
        require(a.proxies.chainTypeManager == b.proxies.chainTypeManager, "chainTypeManagerProxy differs");
        require(
            a.implementations.chainTypeManager == b.implementations.chainTypeManager,
            "chainTypeManagerImplementation differs"
        );
    }

    function compareDAContracts(DAContracts memory a, DAContracts memory b) internal pure {
        require(a.rollupDAManager == b.rollupDAManager, "rollupDAManager differs");
        require(a.rollupSLDAValidator == b.rollupSLDAValidator, "rollupSLDAValidator differs");
        require(a.validiumDAValidator == b.validiumDAValidator, "validiumDAValidator differs");
    }

    function compareFacets(Facets memory a, Facets memory b) internal pure {
        require(a.adminFacet == b.adminFacet, "adminFacet differs");
        require(a.mailboxFacet == b.mailboxFacet, "mailboxFacet differs");
        require(a.executorFacet == b.executorFacet, "executorFacet differs");
        require(a.gettersFacet == b.gettersFacet, "gettersFacet differs");
        require(a.migratorFacet == b.migratorFacet, "migratorFacet differs");
        require(a.committerFacet == b.committerFacet, "committerFacet differs");
        require(a.diamondInit == b.diamondInit, "diamondInit differs");
    }

    function compareBytes(bytes memory a, bytes memory b, string memory fieldName) internal pure {
        require(keccak256(a) == keccak256(b), string(abi.encodePacked(fieldName, " differs")));
    }
}

/// @notice Library with utility functions for GatewayCTMDeployer tests
library GatewayCTMDeployerTestUtils {
    /// @notice Assembles actual deployed contracts from deployer results
    /// @param results The results from all deployers
    /// @param calculatedContracts The pre-calculated contract addresses (used for direct deployments)
    /// @return contracts The assembled DeployedContracts struct
    function assembleActualContracts(
        AllDeployerResults memory results,
        DeployedContracts memory calculatedContracts
    ) internal pure returns (DeployedContracts memory contracts) {
        // From DA deployer
        contracts.daContracts.rollupDAManager = results.daResult.rollupDAManager;
        contracts.daContracts.validiumDAValidator = results.daResult.validiumDAValidator;
        contracts.daContracts.rollupSLDAValidator = results.daResult.rollupSLDAValidator;

        // From ProxyAdmin deployer
        contracts.stateTransition.chainTypeManagerProxyAdmin = results.proxyAdminResult.chainTypeManagerProxyAdmin;

        // From ValidatorTimelock deployer
        contracts.stateTransition.implementations.validatorTimelock = results
            .validatorTimelockResult
            .validatorTimelockImplementation;
        contracts.stateTransition.proxies.validatorTimelock = results.validatorTimelockResult.validatorTimelockProxy;

        // From Verifiers deployer
        contracts.stateTransition.verifiers = results.verifiersResult;

        // From CTM deployer
        contracts.stateTransition.implementations.serverNotifier = results.ctmResult.serverNotifierImplementation;
        contracts.stateTransition.proxies.serverNotifier = results.ctmResult.serverNotifierProxy;
        contracts.stateTransition.implementations.chainTypeManager = results.ctmResult.chainTypeManagerImplementation;
        contracts.stateTransition.proxies.chainTypeManager = results.ctmResult.chainTypeManagerProxy;
        contracts.diamondCutData = results.ctmResult.diamondCutData;

        // Direct deployments - use calculated addresses since they're deployed directly in scripts
        contracts.stateTransition.facets = calculatedContracts.stateTransition.facets;
        contracts.stateTransition.genesisUpgrade = calculatedContracts.stateTransition.genesisUpgrade;
        contracts.multicall3 = calculatedContracts.multicall3;
    }
}
