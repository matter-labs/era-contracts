// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface ISecurityCouncil {
    function approveUpgradeSecurityCouncil(
        bytes32 _id,
        address[] calldata _signers,
        bytes[] calldata _signatures
    ) external;

    function softFreeze(uint256 _validUntil, address[] calldata _signers, bytes[] calldata _signatures) external;

    function hardFreeze(uint256 _validUntil, address[] calldata _signers, bytes[] calldata _signatures) external;

    function unfreeze(uint256 _validUntil, address[] calldata _signers, bytes[] calldata _signatures) external;

    function setSoftFreezeThreshold(
        uint256 _threshold,
        uint256 _validUntil,
        address[] calldata _signers,
        bytes[] calldata _signatures
    ) external;
}
