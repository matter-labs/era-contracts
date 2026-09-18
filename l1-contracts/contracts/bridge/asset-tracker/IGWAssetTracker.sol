// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {ProcessLogsInput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {BalanceChange, MigrationConfirmationData, TokenBridgingData} from "../../common/Messaging.sol";

/// @title IGWAssetTracker
/// @dev IMPORTANT - Settlement Fee Payer Setup:
///      To pay settlement fees for a chain, you must:
///      1. Call `setSettlementFeePayerAgreement(chainId, true)` to opt-in for that specific chain
///      2. Approve this contract to spend your wrapped ZK tokens
///      The agreement mechanism prevents front-running attacks where malicious operators
///      could make you pay for other chains' settlements.
interface IGWAssetTracker {
    /// @notice Emitted when Gateway to L1 migration is initiated for an asset
    /// @param assetId The asset ID being migrated
    /// @param chainId The ID of the chain initiating the asset migration
    /// @param amount The amount being migrated
    event GatewayToL1MigrationInitiated(bytes32 indexed assetId, uint256 indexed chainId, uint256 amount);

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

    /// @notice Set whether the caller agrees to pay settlement fees for a specific chain.
    /// @dev The fee payer must also approve wrapped ZK tokens for this contract.
    function setSettlementFeePayerAgreement(uint256 _chainId, bool _agreed) external;

    /// @notice Initializes the GWAssetTracker on L2.
    /// @param _l1ChainId The chain ID of L1.
    /// @param _owner The owner address.
    function initL2(uint256 _l1ChainId, address _owner) external;

    /// @notice Registers the base token of a chain on the gateway.
    /// @param _baseTokenBridgingData The bridging data for the base token.
    function registerBaseTokenOnGateway(TokenBridgingData calldata _baseTokenBridgingData) external;

    /// @notice The function that is expected to be called by the InteropCenter whenever an L1->L2
    /// transaction gets relayed through ZK Gateway for chain `_chainId`.
    /// @dev Note on trust assumptions: `_chainId` and `_balanceChange` are trusted to be correct, since
    /// they are provided directly by the InteropCenter, which in turn, gets those from the L1 implementation of
    /// the GW Mailbox.
    /// @dev `_canonicalTxHash` is not trusted as it is provided at will by a malicious chain.
    /// @param _chainId The chain ID of the target chain.
    /// @param _canonicalTxHash The canonical transaction hash.
    /// @param _balanceChange The balance change data for the transaction.
    function handleChainBalanceIncreaseOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        BalanceChange calldata _balanceChange
    ) external;

    /// @notice Processes L2->Gateway logs and messages to update chain balances and handle cross-chain operations.
    /// @dev This is the main function that processes a batch of L2 logs from a settling chain.
    /// @dev It reconstructs the logs Merkle tree, validates messages, and routes them to appropriate handlers.
    /// @dev The function handles multiple types of messages: interop, base token, asset router, and system messages.
    /// @param _processLogsInputs The input containing logs, messages, and chain information to process.
    function processLogsAndMessages(ProcessLogsInput calldata _processLogsInputs) external;

    /// @notice Migrates the token balance from Gateway to L1.
    /// @dev This function is intended to be permissionless so that a chain that has moved out
    /// of Gateway has an easy way to migrate its balance out of the system.
    /// @param _chainId The chain ID whose token balance is being migrated.
    /// @param _assetId The asset ID of the token being migrated.
    function initiateGatewayToL1MigrationOnGateway(uint256 _chainId, bytes32 _assetId) external;

    /// @notice Confirms a migration operation has been completed and updates the asset migration number.
    /// @param _migrationConfirmationData The migration confirmation data containing chain ID, asset ID, and migration number.
    function confirmMigrationOnGateway(MigrationConfirmationData calldata _migrationConfirmationData) external;

    /// @notice Sets a legacy shared bridge address for a specific chain.
    /// @param _chainId The chain ID for which to set the legacy bridge address.
    /// @param _legacySharedBridgeAddress The address of the legacy shared bridge contract.
    function setLegacySharedBridgeAddress(uint256 _chainId, address _legacySharedBridgeAddress) external;

    /// @notice Returns the L1 chain ID.
    function L1_CHAIN_ID() external view returns (uint256);

    /// @notice Sets legacy shared bridge addresses for chains that used the old bridging system.
    /// @dev Called during upgrades to maintain backwards compatibility with pre-V31 chains.
    /// @dev Legacy bridges are needed to process withdrawal messages from chains that haven't upgraded yet.
    function setLegacySharedBridgeAddress() external;

    /// @notice Parses interop call data to extract transfer information.
    /// @param _callData The encoded call data containing transfer information.
    /// @return fromChainId The chain ID from which the transfer originates.
    /// @return assetId The asset ID of the token being transferred.
    /// @return transferData The encoded transfer data.
    function parseInteropCall(
        bytes calldata _callData
    ) external pure returns (uint256 fromChainId, bytes32 assetId, bytes memory transferData);

    /// @notice Parses token metadata from encoded token data.
    /// @param _tokenData The encoded token metadata.
    /// @return originChainId The chain ID where the token was originally created.
    /// @return name The token name as encoded bytes.
    /// @return symbol The token symbol as encoded bytes.
    /// @return decimals The token decimals as encoded bytes.
    function parseTokenData(
        bytes calldata _tokenData
    ) external pure returns (uint256 originChainId, bytes memory name, bytes memory symbol, bytes memory decimals);
}
