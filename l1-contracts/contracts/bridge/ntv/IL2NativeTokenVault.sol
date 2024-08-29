// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// import {INativeTokenVault} from "./INativeTokenVault.sol";
// import {IAssetHandler} from "./IAssetHandler.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2NativeTokenVault {
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

    // function tokenAddress(bytes32 _assetId) external view returns (address);

    function l2TokenAddress(address _l1Token) external view returns (address);

    // function calculateCreate2TokenAddress(address _l1Token) external view returns (address);
}
