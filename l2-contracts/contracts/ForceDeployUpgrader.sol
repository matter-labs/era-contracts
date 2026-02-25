// SPDX-License-Identifier: MIT OR Apache-2.0

pragma solidity 0.8.28;

import {DEPLOYER_SYSTEM_CONTRACT} from "./L2ContractHelper.sol";
import {
    ForceDeployment,
    IContractDeployer
} from "@matterlabs/zksync-contracts/contracts/system-contracts/interfaces/IContractDeployer.sol";

/// @custom:security-contact security@matterlabs.dev
/// @notice The contract that calls force deployment during the L2 system contract upgrade.
/// @notice It is supposed to be used inherited by an implementation of the ComplexUpgrader. (but it is not useful in itself)
contract ForceDeployUpgrader {
    /// @notice A function that performs force deploy
    /// @param _forceDeployments The force deployments to perform.
    function forceDeploy(ForceDeployment[] calldata _forceDeployments) external payable {
        IContractDeployer(DEPLOYER_SYSTEM_CONTRACT).forceDeployOnAddresses{value: msg.value}(_forceDeployments);
    }
}
