// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IProtocolUpgradeHandler} from "./IProtocolUpgradeHandler.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IEmergencyUpgrageBoard {
    function GUARDIANS() external view returns (address);

    function SECURITY_COUNCIL() external view returns (address);

    function ZK_FOUNDATION_SAFE() external view returns (address);

    function executeEmergencyUpgrade(
        IProtocolUpgradeHandler.Call[] calldata _calls,
        bytes32 _salt,
        bytes calldata _guardiansSignatures,
        bytes calldata _securityCouncilSignatures,
        bytes calldata _zkFoundationSignatures
    ) external;
}
