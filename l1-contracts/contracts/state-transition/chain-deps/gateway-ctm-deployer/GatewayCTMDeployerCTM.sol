// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EraChainTypeManager} from "../../EraChainTypeManager.sol";

import {L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR} from "../../../common/l2-helpers/L2ContractAddresses.sol";
import {WrongCTMDeployerVariant} from "../../../common/L1ContractErrors.sol";

import {GatewayCTMFinalConfig} from "./GatewayCTMDeployer.sol";
import {GatewayCTMDeployerCTMBase} from "./GatewayCTMDeployerCTMBase.sol";

/// @title GatewayCTMDeployerCTM
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Gateway CTM Era deployer: deploys ServerNotifier and Era CTM, links them together.
/// For ZKsyncOS CTM, use GatewayCTMDeployerCTMZKsyncOS instead.
contract GatewayCTMDeployerCTM is GatewayCTMDeployerCTMBase {
    constructor(GatewayCTMFinalConfig memory _config) {
        if (_config.baseConfig.isZKsyncOS) {
            revert WrongCTMDeployerVariant();
        }
        _deployInner(_config);
    }

    /// @inheritdoc GatewayCTMDeployerCTMBase
    function _deployCTMImplementation(bytes32 _salt) internal override returns (address) {
        // PermissionlessValidator is address(0) since Priority Mode is L1-only
        return
            address(
                new EraChainTypeManager{salt: _salt}(L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, address(0), address(0))
            );
    }
}
