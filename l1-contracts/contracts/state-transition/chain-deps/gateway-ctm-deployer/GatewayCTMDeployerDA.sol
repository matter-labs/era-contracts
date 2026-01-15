// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {RollupDAManager} from "../../data-availability/RollupDAManager.sol";
import {RelayedSLDAValidator} from "../../data-availability/RelayedSLDAValidator.sol";
import {ValidiumL1DAValidator} from "../../data-availability/ValidiumL1DAValidator.sol";

import {ROLLUP_L2_DA_COMMITMENT_SCHEME} from "../../../common/Config.sol";

import {GatewayDADeployerConfig, GatewayDADeployerResult} from "./GatewayCTMDeployer.sol";

/// @title GatewayCTMDeployerDA
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Phase 1 of Gateway CTM deployment: deploys DA contracts.
/// @dev Deploys: RollupDAManager, ValidiumL1DAValidator, RelayedSLDAValidator.
/// This contract is expected to be deployed via the built-in L2 `Create2Factory`.
contract GatewayCTMDeployerDA {
    GatewayDADeployerResult internal deployedResult;

    /// @notice Returns the deployed contracts from this phase.
    /// @return result The struct with information about the deployed contracts.
    function getResult() external view returns (GatewayDADeployerResult memory result) {
        result = deployedResult;
    }

    constructor(GatewayDADeployerConfig memory _config) {
        bytes32 salt = _config.salt;

        GatewayDADeployerResult memory result;

        // Deploy DA contracts
        RollupDAManager rollupDAManager = new RollupDAManager{salt: salt}();
        result.validiumDAValidator = address(new ValidiumL1DAValidator{salt: salt}());
        result.relayedSLDAValidator = address(new RelayedSLDAValidator{salt: salt}());

        // Initialize DA manager
        rollupDAManager.updateDAPair(result.relayedSLDAValidator, ROLLUP_L2_DA_COMMITMENT_SCHEME, true);
        // Note, that the governance still has to accept it.
        // It will happen in a separate voting after the deployment is done.
        rollupDAManager.transferOwnership(_config.aliasedGovernanceAddress);
        result.rollupDAManager = address(rollupDAManager);

        deployedResult = result;
    }
}
