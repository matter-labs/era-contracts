// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {DEPLOYER_SYSTEM_CONTRACT, SYSTEM_CONTEXT_CONTRACT, L2_BRIDGE_HUB, L2_ASSET_ROUTER, L2_MESSAGE_ROOT, L2_NATIVE_TOKEN_VAULT_ADDR} from "./Constants.sol";
import {IContractDeployer, ForceDeployment} from "./interfaces/IContractDeployer.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {ISystemContext} from "./interfaces/ISystemContext.sol";
import {IL2GenesisUpgrade, FixedForceDeploymentsData, ZKChainSpecificForceDeploymentsData} from "./interfaces/IL2GenesisUpgrade.sol";

import {GatewayUpgrade} from "./GatewayUpgrade.sol";

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @notice The contract that is used for facilitating the upgrade of the L2
/// to the protocol version that supports gateway
/// @dev This contract is neither predeployed nor a system contract. It is located
/// in this folder due to very overlaping functionality with `L2GenesisUpgrade` and
/// faciliating reusage of the code.
/// @dev During the ugprade, it will be delegate-called by the `ComplexUpgrader` contract.
contract L2GatewayUpgrade is GatewayUpgrade {
    function upgrade(
        ForceDeployment[] calldata _forceDeployments,
        address _ctmDeployer,
        bytes calldata _fixedForceDeploymentsData,
        bytes calldata _additionalForceDeploymentsData
    ) external payable {
        // Firstly, we force deploy the main set of contracts. 
        // Those will be deployed without any contract invocation.
        IContractDeployer(DEPLOYER_SYSTEM_CONTRACT).forceDeployOnAddresses{value: msg.value}(_forceDeployments);

        // Secondly, we perform the more complex deployment of the gateway contracts. 
        performGatewayContractsInit(_ctmDeployer, _fixedForceDeploymentsData, _additionalForceDeploymentsData);
    }
}
