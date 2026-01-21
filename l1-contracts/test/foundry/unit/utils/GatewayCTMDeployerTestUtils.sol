// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {DAContracts, DeployedContracts, Facets, StateTransitionContracts, DAContracts, GatewayProxyAdminDeployerResult, GatewayValidatorTimelockDeployerResult, Verifiers, GatewayCTMFinalResult} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployer.sol";

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
        compareStateTransitionContracts(a.stateTransition, b.stateTransition);
        compareDAContracts(a.daContracts, b.daContracts);
        compareBytes(a.diamondCutData, b.diamondCutData, "diamondCutData");
    }

    function compareStateTransitionContracts(
        StateTransitionContracts memory a,
        StateTransitionContracts memory b
    ) internal pure {
        require(a.verifier == b.verifier, "verifier differs");
        require(a.verifierFflonk == b.verifierFflonk, "verifierFflonk differs");
        require(a.verifierPlonk == b.verifierPlonk, "verifierPlonk differs");
        compareFacets(a.facets, b.facets);
        require(a.genesisUpgrade == b.genesisUpgrade, "genesisUpgrade differs");
        require(
            a.validatorTimelockImplementation == b.validatorTimelockImplementation,
            "validatorTimelockImplementation differs"
        );
        require(a.validatorTimelockProxy == b.validatorTimelockProxy, "validatorTimelockProxy differs");
        require(a.chainTypeManagerProxyAdmin == b.chainTypeManagerProxyAdmin, "chainTypeManagerProxyAdmin differs");
        require(
            a.serverNotifierImplementation == b.serverNotifierImplementation,
            "serverNotifierImplementation differs"
        );
        require(a.serverNotifierProxy == b.serverNotifierProxy, "serverNotifier proxy differs");
        require(a.chainTypeManagerProxy == b.chainTypeManagerProxy, "chainTypeManagerProxy differs");
        require(
            a.chainTypeManagerImplementation == b.chainTypeManagerImplementation,
            "chainTypeManagerImplementation differs"
        );
    }

    function compareDAContracts(DAContracts memory a, DAContracts memory b) internal pure {
        require(a.rollupDAManager == b.rollupDAManager, "rollupDAManager differs");
        require(a.relayedSLDAValidator == b.relayedSLDAValidator, "relayedSLDAValidator differs");
        require(a.validiumDAValidator == b.validiumDAValidator, "validiumDAValidator differs");
    }

    function compareFacets(Facets memory a, Facets memory b) internal pure {
        require(a.adminFacet == b.adminFacet, "adminFacet differs");
        require(a.mailboxFacet == b.mailboxFacet, "mailboxFacet differs");
        require(a.executorFacet == b.executorFacet, "executorFacet differs");
        require(a.gettersFacet == b.gettersFacet, "gettersFacet differs");
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
        contracts.daContracts.relayedSLDAValidator = results.daResult.relayedSLDAValidator;

        // From ProxyAdmin deployer
        contracts.stateTransition.chainTypeManagerProxyAdmin = results.proxyAdminResult.chainTypeManagerProxyAdmin;

        // From ValidatorTimelock deployer
        contracts.stateTransition.validatorTimelockImplementation = results
            .validatorTimelockResult
            .validatorTimelockImplementation;
        contracts.stateTransition.validatorTimelockProxy = results.validatorTimelockResult.validatorTimelockProxy;

        // From Verifiers deployer
        contracts.stateTransition.verifierFflonk = results.verifiersResult.verifierFflonk;
        contracts.stateTransition.verifierPlonk = results.verifiersResult.verifierPlonk;
        contracts.stateTransition.verifier = results.verifiersResult.verifier;

        // From CTM deployer
        contracts.stateTransition.serverNotifierImplementation = results.ctmResult.serverNotifierImplementation;
        contracts.stateTransition.serverNotifierProxy = results.ctmResult.serverNotifierProxy;
        contracts.stateTransition.chainTypeManagerImplementation = results.ctmResult.chainTypeManagerImplementation;
        contracts.stateTransition.chainTypeManagerProxy = results.ctmResult.chainTypeManagerProxy;
        contracts.diamondCutData = results.ctmResult.diamondCutData;

        // Direct deployments - use calculated addresses since they're deployed directly in scripts
        contracts.stateTransition.facets = calculatedContracts.stateTransition.facets;
        contracts.stateTransition.genesisUpgrade = calculatedContracts.stateTransition.genesisUpgrade;
        contracts.multicall3 = calculatedContracts.multicall3;
    }
}
