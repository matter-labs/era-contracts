// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

// import {IL2AssetRouter} from "./IL2AssetRouter.sol";
import {IL2AssetHandler} from "./IL2AssetHandler.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2NativeTokenVault is IL2AssetHandler {
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

    function tokenAddress(bytes32 _assetId) external view returns (address);

    function l2TokenAddress(address _l1Token) external view returns (address);

    function setL2TokenBeacon(address _l2TokenBeacon, bytes32 _l2TokenProxyBytecodeHash) external;

    function configureL2TokenBeacon(bool _contractsDeployedAlready, address _l2TokenBeacon) external;
}
