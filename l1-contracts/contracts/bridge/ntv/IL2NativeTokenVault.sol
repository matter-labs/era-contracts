// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {INativeTokenVault} from "./INativeTokenVault.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2NativeTokenVault is INativeTokenVault {
    event FinalizeDeposit(
        address indexed l1Sender,
        address indexed l2Receiver,
        address indexed l2Token,
        uint256 amount
    );

    event WithdrawalInitiated(
        address indexed l2Sender,
        address indexed l1Receiver,
        address indexed l2Token,
        uint256 amount
    );

    event L2TokenBeaconUpdated(address indexed l2TokenBeacon, bytes32 indexed l2TokenProxyBytecodeHash);

    function l2TokenAddress(address _l1Token) external view returns (address);

    function setLegacyTokenAssetId(address _l2TokenAddress) external;
}
