// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {ProcessLogsInput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {BalanceChange, ConfirmBalanceMigrationData} from "../../common/Messaging.sol";

interface IGWAssetTracker {
    /// @notice Emitted when the gateway settlement fee is updated.
    ///         This is the fee that operator must pay for each interop bundle that was sent by user without paying fixed ZK fee.
    ///         It's paid by operator of source chain of interop bundle on the moment of chain settling on GW.
    /// @param oldFee Previous fee amount.
    /// @param newFee New fee amount.
    event GatewaySettlementFeeUpdated(uint256 indexed oldFee, uint256 indexed newFee);

    function setAddresses(uint256 _l1ChainId) external;

    function handleChainBalanceIncreaseOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        BalanceChange calldata _balanceChange
    ) external;

    function processLogsAndMessages(ProcessLogsInput calldata) external payable;

    function initiateGatewayToL1MigrationOnGateway(uint256 _chainId, bytes32 _assetId) external;

    function confirmMigrationOnGateway(ConfirmBalanceMigrationData calldata _tokenBalanceMigrationData) external;

    function setLegacySharedBridgeAddress(uint256 _chainId, address _legacySharedBridgeAddress) external;

    function requestPauseDepositsForChain(uint256 _chainId) external;
}
