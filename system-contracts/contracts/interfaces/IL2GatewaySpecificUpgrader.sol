// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {ChainCreationParams, DiamondCutData} from "./IChainTypeManager.sol";
import {ForceDeployment} from "./IContractDeployer.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface for the L2GatewaySpecificUpgrader contract.
 */
interface IL2GatewaySpecificUpgrader {
    function upgradeIfGateway(
        address ctmAddress,
        ChainCreationParams calldata chainCreationParams,
        DiamondCutData calldata upgradeCutData,
        uint256 oldProtocolVersion,
        uint256 oldProtocolVersionDeadline,
        uint256 newProtocolVersion,
        ForceDeployment[] calldata
    ) external;
}
