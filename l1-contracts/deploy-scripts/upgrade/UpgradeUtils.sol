    // SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StateTransitionDeployedAddresses} from "../Utils.sol";

// solhint-disable no-console, gas-custom-errors
    
    // solhint-disable-next-line gas-struct-packing
    struct Gateway {
        StateTransitionDeployedAddresses gatewayStateTransition;
        bytes facetCutsData;
        bytes additionalForceDeployments;
        uint256 chainId;
        address baseToken;
        bytes upgradeCutData;
    }

    /// @notice Internal state of the upgrade script
    struct EcosystemUpgradeConfig {
        bool initialized;
        bool expectedL2AddressesInitialized;
        bool fixedForceDeploymentsDataGenerated;
        bool diamondCutPrepared;
        bool upgradeCutPrepared;
        bool factoryDepsPublished;
        bool ecosystemContractsDeployed;
        string outputPath;
    }