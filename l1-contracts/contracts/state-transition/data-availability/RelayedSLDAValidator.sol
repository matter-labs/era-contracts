// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL1DAValidator, L1DAValidatorOutput, PubdataSource} from "../chain-interfaces/IL1DAValidator.sol";
import {CalldataDAGateway} from "./CalldataDAGateway.sol";

import {IBridgehub} from "../../bridgehub/IBridgehub.sol";
import {L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_BRIDGEHUB_ADDR} from "../../common/L2ContractAddresses.sol";
import {BlobHashBlobCommitmentMismatchValue, L1DAValidatorInvalidSender, InvalidPubdataSource} from "../L1StateTransitionErrors.sol";

/// @dev The version that is used for the `RelayedSLDAValidator` calldata.
/// This is needed to ensure easier future-compatible encoding.
uint8 constant RELAYED_SL_DA_VALIDATOR_VERSION = 0;

/// @notice The DA validator intended to be used in Era-environment.
/// @dev For compatibility reasons it accepts calldata in the same format as the `RollupL1DAValidator`, but unlike the latter it
/// does not support blobs.
/// @dev Note that it does not provide any compression whatsoever.
contract RelayedSLDAValidator is IL1DAValidator, CalldataDAGateway {
    /// @dev Ensures that the sender is the chain that is supposed to send the message.
    /// @param _chainId The chain id of the chain that is supposed to send the message.
    function _ensureOnlyChainSender(uint256 _chainId) internal view {
        // Note that this contract is only supposed to be deployed on L2, where the
        // bridgehub is predeployed at `L2_BRIDGEHUB_ADDR` address.
        if (IBridgehub(L2_BRIDGEHUB_ADDR).getZKChain(_chainId) != msg.sender) {
            revert L1DAValidatorInvalidSender(msg.sender);
        }
    }

    /// @dev Relays the calldata to L1.
    /// @param _chainId The chain id of the chain that is supposed to send the message.
    /// @param _batchNumber The batch number for which the data availability is being checked.
    /// @param _pubdata The pubdata to be relayed to L1.
    function _relayCalldata(uint256 _chainId, uint256 _batchNumber, bytes calldata _pubdata) internal {
        // Re-sending all the pubdata in pure form to L1.
        // slither-disable-next-line unused-return
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR.sendToL1(
            abi.encode(RELAYED_SL_DA_VALIDATOR_VERSION, _chainId, _batchNumber, _pubdata)
        );
    }

    /// @inheritdoc IL1DAValidator
    function checkDA(
        uint256 _chainId,
        uint256 _batchNumber,
        bytes32 _l2DAValidatorOutputHash,
        bytes calldata _operatorDAInput,
        uint256 _maxBlobsSupported
    ) external returns (L1DAValidatorOutput memory output) {
        // Unfortunately we have to use a method call instead of a modifier
        // because of the stack-too-deep error caused by it.
        _ensureOnlyChainSender(_chainId);

        // Preventing "stack too deep" error
        uint256 blobsProvided;
        bytes32 fullPubdataHash;
        bytes calldata l1DaInput;
        {
            bytes32 stateDiffHash;
            bytes32[] memory blobsLinearHashes;
            (
                stateDiffHash,
                fullPubdataHash,
                blobsLinearHashes,
                blobsProvided,
                l1DaInput
            ) = _processL2RollupDAValidatorOutputHash(_l2DAValidatorOutputHash, _maxBlobsSupported, _operatorDAInput);

            output.stateDiffHash = stateDiffHash;
            output.blobsLinearHashes = blobsLinearHashes;
        }

        uint8 pubdataSource = uint8(l1DaInput[0]);

        // Note, that the blobs are not supported in the RelayedSLDAValidator.
        if (pubdataSource == uint8(PubdataSource.Calldata)) {
            bytes calldata pubdata;
            bytes32[] memory blobCommitments;

            (blobCommitments, pubdata) = _processCalldataDA(
                blobsProvided,
                fullPubdataHash,
                _maxBlobsSupported,
                l1DaInput[1:]
            );

            _relayCalldata(_chainId, _batchNumber, pubdata);

            output.blobsOpeningCommitments = blobCommitments;
        } else {
            revert InvalidPubdataSource(pubdataSource);
        }

        // We verify that for each set of blobHash/blobCommitment are either both empty
        // or there are values for both.
        // This is mostly a sanity check and it is not strictly required.
        for (uint256 i = 0; i < _maxBlobsSupported; ++i) {
            if (
                (output.blobsLinearHashes[i] != bytes32(0) || output.blobsOpeningCommitments[i] != bytes32(0)) &&
                (output.blobsLinearHashes[i] == bytes32(0) || output.blobsOpeningCommitments[i] == bytes32(0))
            ) {
                revert BlobHashBlobCommitmentMismatchValue();
            }
        }
    }
}
