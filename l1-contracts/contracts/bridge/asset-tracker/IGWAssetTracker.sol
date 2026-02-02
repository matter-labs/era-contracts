// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {ProcessLogsInput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {BalanceChange, TokenBalanceMigrationData, TokenBridgingData} from "../../common/Messaging.sol";

/// @title IGWAssetTracker
interface IGWAssetTracker {
    /// @notice Emitted when the gateway settlement fee is updated.
    ///         This is the fee that operator must pay for each interop call.
    ///         It's paid by operator of source chain on the moment of chain settling on GW.
    /// @param oldFee Previous fee amount.
    /// @param newFee New fee amount.
    event GatewaySettlementFeeUpdated(uint256 indexed oldFee, uint256 indexed newFee);

    /// @notice Emitted when gateway settlement fees are collected during batch execution.
    /// @param chainId The chain ID that is settling.
    /// @param feePayer Address that paid the settlement fees.
    /// @param amount Total amount of wrapped ZK tokens collected.
    /// @param interopCallCount Number of interop calls that incurred fees.
    event GatewaySettlementFeesCollected(
        uint256 indexed chainId,
        address indexed feePayer,
        uint256 amount,
        uint256 interopCallCount
    );

    /// @notice Emitted when a fee payer's agreement to pay settlement fees is updated.
    /// @param payer Address of the fee payer.
    /// @param chainId Chain ID the agreement applies to.
    /// @param agreed Whether the payer agreed (true) or revoked (false).
    event SettlementFeePayerAgreementUpdated(address indexed payer, uint256 indexed chainId, bool agreed);

    /// @notice Returns the current gateway settlement fee per interop call.
    function gatewaySettlementFee() external view returns (uint256);

    /// @notice Returns the wrapped ZK token used for fee payments.
    function wrappedZKToken() external view returns (IERC20);

    /// @notice Sets the gateway settlement fee per interop call.
    /// @param _fee New fee amount in wrapped ZK token wei.
    function setGatewaySettlementFee(uint256 _fee) external;

    /// @notice Withdraws accumulated gateway fees to a recipient.
    /// @param _recipient Address to receive the fees.
    function withdrawGatewayFees(address _recipient) external;

    /// @notice Returns whether a fee payer has agreed to pay settlement fees for a chain.
    /// @param _payer Address of the fee payer.
    /// @param _chainId Chain ID to check.
    function settlementFeePayerAgreement(address _payer, uint256 _chainId) external view returns (bool);

    /// @notice Opt-in to pay settlement fees for a specific chain.
    /// @dev The fee payer must also approve wrapped ZK tokens for this contract.
    /// @param _chainId Chain ID to agree to pay fees for.
    function agreeToPaySettlementFees(uint256 _chainId) external;

    /// @notice Revoke agreement to pay settlement fees for a specific chain.
    /// @param _chainId Chain ID to revoke agreement for.
    function revokeSettlementFeePayerAgreement(uint256 _chainId) external;

    function setAddresses(uint256 _l1ChainId) external;

    function registerBaseTokenOnGateway(TokenBridgingData calldata _baseTokenBridgingData) external;

    function handleChainBalanceIncreaseOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        BalanceChange calldata _balanceChange
    ) external;

    function processLogsAndMessages(ProcessLogsInput calldata) external;

    function initiateGatewayToL1MigrationOnGateway(uint256 _chainId, bytes32 _assetId) external;

    function confirmMigrationOnGateway(TokenBalanceMigrationData calldata _tokenBalanceMigrationData) external;

    function setLegacySharedBridgeAddress(uint256 _chainId, address _legacySharedBridgeAddress) external;

    function requestPauseDepositsForChain(uint256 _chainId) external;
}
