// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IZKChainBase} from "../chain-interfaces/IZKChainBase.sol";
import {ZKChainCommitment} from "../../common/Config.sol";
import {TxStatus} from "../../common/Messaging.sol";

/// @title The interface of the Migrator Contract that handles chain migration.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IMigrator is IZKChainBase {
    /// @notice Emitted when the migration to the new settlement layer is complete.
    event MigrationComplete();

    /// @notice Emitted when deposits are paused before migration.
    event DepositsPaused(uint256 chainId, uint256 pausedDepositsTimestamp);

    /// @notice Emitted when deposits are unpaused.
    event DepositsUnpaused(uint256 chainId);

    /// @notice Pauses deposits before initiating migration to the Gateway.
    function pauseDepositsBeforeInitiatingMigration() external;

    /// @notice Unpauses deposits, used after the chain is initialized
    function unpauseDeposits() external;

    /// @dev Similar to IL1AssetHandler interface, used to send chains.
    function forwardedBridgeBurn(
        address _settlementLayer,
        address _originalCaller,
        bytes calldata _data
    ) external payable returns (bytes memory _bridgeMintData);

    /// @dev Similar to IL1AssetHandler interface, used to claim failed chain transfers.
    function forwardedBridgeConfirmTransferResult(
        uint256 _chainId,
        TxStatus _txStatus,
        bytes32 _assetInfo,
        address _originalCaller,
        bytes calldata _chainData
    ) external payable;

    /// @dev Similar to IL1AssetHandler interface, used to receive chains.
    function forwardedBridgeMint(bytes calldata _data, bool _contractAlreadyDeployed) external payable;

    /// @notice Returns the commitment for a chain.
    function prepareChainCommitment() external view returns (ZKChainCommitment memory commitment);

    /// @notice Pauses deposits on Gateway, needed as migration is only allowed with this timestamp.
    function pauseDepositsOnGateway(uint256 _timestamp) external;
}
