// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {ProcessLogsInput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {BalanceChange, ConfirmBalanceMigrationData} from "../../common/Messaging.sol";

interface IGWAssetTracker {
    /// @notice Emitted when the gateway settlement fee is updated.
    ///         This is the fee that operator must pay for each interop call.
    ///         It's paid by operator of source chain on the moment of chain settling on GW.
    /// @param oldFee Previous fee amount.
    /// @param newFee New fee amount.
    event GatewaySettlementFeeUpdated(uint256 indexed oldFee, uint256 indexed newFee);

    /// @notice Returns the current gateway settlement fee per interop call.
    function gatewaySettlementFee() external view returns (uint256);

    /// @notice Returns the wrapped ZK token used for fee payments.
    function wrappedZKToken() external view returns (address);

    /// @notice Sets the gateway settlement fee per interop call.
    /// @param _fee New fee amount in wrapped ZK token wei.
    function setGatewaySettlementFee(uint256 _fee) external;

    /// @notice Withdraws accumulated gateway fees to a recipient.
    /// @param _recipient Address to receive the fees.
    function withdrawGatewayFees(address _recipient) external;

    function setAddresses(uint256 _l1ChainId) external;

    function handleChainBalanceIncreaseOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        BalanceChange calldata _balanceChange
    ) external;

    function processLogsAndMessages(ProcessLogsInput calldata) external;

    function initiateGatewayToL1MigrationOnGateway(uint256 _chainId, bytes32 _assetId) external;

    function confirmMigrationOnGateway(ConfirmBalanceMigrationData calldata _tokenBalanceMigrationData) external;

    function setLegacySharedBridgeAddress(uint256 _chainId, address _legacySharedBridgeAddress) external;

    function requestPauseDepositsForChain(uint256 _chainId) external;
}
