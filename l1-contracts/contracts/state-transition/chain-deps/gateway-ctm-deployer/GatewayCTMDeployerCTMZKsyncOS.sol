// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ZKsyncOSChainTypeManager} from "../../ZKsyncOSChainTypeManager.sol";

import {L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR} from "../../../common/l2-helpers/L2ContractAddresses.sol";
import {WrongCTMDeployerVariant} from "../../../common/L1ContractErrors.sol";

import {GatewayCTMFinalConfig} from "./GatewayCTMDeployer.sol";
import {GatewayCTMDeployerCTMBase} from "./GatewayCTMDeployerCTMBase.sol";

/// @title GatewayCTMDeployerCTMZKsyncOS
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Gateway CTM ZKsyncOS deployer: deploys ServerNotifier and ZKsyncOS CTM, links them together.
contract GatewayCTMDeployerCTMZKsyncOS is GatewayCTMDeployerCTMBase {
    constructor(GatewayCTMFinalConfig memory _config) {
        if (!_config.baseConfig.isZKsyncOS) {
            revert WrongCTMDeployerVariant();
        }
        _deployInner(_config);
    }

    /// @inheritdoc GatewayCTMDeployerCTMBase
    function _deployCTMImplementation(bytes32 _salt) internal override returns (address) {
        return
            address(new ZKsyncOSChainTypeManager{salt: _salt}(L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, address(0)));
    }
}
