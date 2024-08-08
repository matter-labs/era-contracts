// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

// import {IL2AssetRouter} from "./IL2AssetRouter.sol";
import {IL2AssetHandler} from "./IL2AssetHandler.sol";

/// @author Matter Labs
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

    function tokenAddress(bytes32 _assetId) external view returns (address);

    function l2TokenAddress(address _l1Token) external view returns (address);

    function setL2TokenBeacon(bool _contractsDeployedAlready, address _l2TokenBeacon) external;
}
