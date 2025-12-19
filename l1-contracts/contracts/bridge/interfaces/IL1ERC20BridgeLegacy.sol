// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IL1Nullifier} from "./IL1Nullifier.sol";
import {IL1NativeTokenVault} from "../ntv/IL1NativeTokenVault.sol";
import {IL1AssetRouter} from "../asset-router/IL1AssetRouter.sol";

/// @title L1 Bridge contract legacy interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Legacy Bridge interface before ZK chain migration, used for backward compatibility with ZKsync Era
interface IL1ERC20BridgeLegacy {

    function isWithdrawalFinalized(uint256 _l2BatchNumber, uint256 _l2MessageIndex) external view returns (bool);

    /// @notice Finalize the withdrawal and release funds
    /// @param _l2BatchNumber The L2 batch number where the withdrawal was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization
    function finalizeWithdrawal(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external;

}
