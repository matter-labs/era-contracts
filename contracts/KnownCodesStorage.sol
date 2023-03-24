// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interfaces/IKnownCodesStorage.sol";
import "./libraries/Utils.sol";
import "./libraries/SystemContractHelper.sol";
import {BOOTLOADER_FORMAL_ADDRESS, BYTECODE_COMPRESSOR_CONTRACT} from "./Constants.sol";

/**
 * @author Matter Labs
 * @notice The storage of this contract will basically serve as a mapping for the known code hashes.
 * @dev Code hash is not strictly a hash, it's a structure where the first byte denotes the version of the hash,
 * the second byte denotes whether the contract is constructed, and the next two bytes denote the length in 32-byte words.
 * words. And then the next 28 bytes is the truncated hash.
 */
contract KnownCodesStorage is IKnownCodesStorage {
    modifier onlyBootloader() {
        require(msg.sender == BOOTLOADER_FORMAL_ADDRESS, "Callable only by the bootloader");
        _;
    }

    modifier onlyBytecodeCompressor() {
        require(msg.sender == address(BYTECODE_COMPRESSOR_CONTRACT), "Callable only by the bytecode compressor");
        _;
    }

    /// @notice The method that is used by the bootloader to mark several bytecode hashes as known.
    /// @param _shouldSendToL1 Whether the bytecode should be sent on L1.
    /// @param _hashes Hashes of the bytecodes to be marked as known.
    function markFactoryDeps(bool _shouldSendToL1, bytes32[] calldata _hashes) external onlyBootloader {
        unchecked {
            uint256 hashesLen = _hashes.length;
            for (uint256 i = 0; i < hashesLen; ++i) {
                uint256 codeLengthInBytes = Utils.bytecodeLenInBytes(_hashes[i]);
                _markBytecodeAsPublished(_hashes[i], 0, codeLengthInBytes, _shouldSendToL1);
            }
        }
    }

    /// @notice The method used to mark a single bytecode hash as known.
    /// @dev Only trusted contacts can call this method, currently only the bytecode compressor.
    /// @param _bytecodeHash The hash of the bytecode that is marked as known.
    /// @param _l1PreimageHash The hash of the preimage is be shown on L1 if zero - the full bytecode will be shown.
    /// @param _l1PreimageBytesLen The length of the preimage in bytes.
    function markBytecodeAsPublished(
        bytes32 _bytecodeHash,
        bytes32 _l1PreimageHash,
        uint256 _l1PreimageBytesLen
    ) external onlyBytecodeCompressor {
        _markBytecodeAsPublished(_bytecodeHash, _l1PreimageHash, _l1PreimageBytesLen, false);
    }

    /// @notice The method used to mark a single bytecode hash as known
    /// @param _bytecodeHash The hash of the bytecode that is marked as known
    /// @param _l1PreimageHash The hash of the preimage to be shown on L1 if zero - the full bytecode will be shown
    /// @param _l1PreimageBytesLen The length of the preimage in bytes
    /// @param _shouldSendToL1 Whether the bytecode should be sent on L1
    function _markBytecodeAsPublished(
        bytes32 _bytecodeHash,
        bytes32 _l1PreimageHash,
        uint256 _l1PreimageBytesLen,
        bool _shouldSendToL1
    ) internal {
        if (getMarker(_bytecodeHash) == 0) {
            _validateBytecode(_bytecodeHash);

            if (_shouldSendToL1) {
                _sendBytecodeToL1(_bytecodeHash, _l1PreimageHash, _l1PreimageBytesLen);
            }

            // Save as known, to not resend the log to L1
            assembly {
                sstore(_bytecodeHash, 1)
            }

            emit MarkedAsKnown(_bytecodeHash, _shouldSendToL1);
        }
    }

    /// @notice Method used for sending the bytecode (preimage for the bytecode hash) on L1.
    /// @dev While bytecode must be visible to L1 observers, it's not necessary to disclose the whole raw bytecode.
    /// To achieve this, it's possible to utilize compressed data using a known compression algorithm. Thus, the
    /// L1 preimage data may differ from the raw bytecode.
    /// @param _bytecodeHash The hash of the bytecode that is marked as known.
    /// @param _l1PreimageHash The hash of the preimage to be shown on L1 if zero - the full bytecode will be shown.
    /// @param _l1PreimageBytesLen The length of the preimage in bytes.
    /// @dev This method sends a single L2->L1 log with the bytecodeHash and l1PreimageHash. It is the responsibility of the L1
    /// smart contracts to make sure that the preimage for this bytecode hash has been shown.
    function _sendBytecodeToL1(bytes32 _bytecodeHash, bytes32 _l1PreimageHash, uint256 _l1PreimageBytesLen) internal {
        // Burn gas to cover the cost of publishing pubdata on L1

        // Get the cost of 1 pubdata byte in gas
        uint256 meta = SystemContractHelper.getZkSyncMetaBytes();
        uint256 pricePerPubdataByteInGas = SystemContractHelper.getGasPerPubdataByteFromMeta(meta);

        // Calculate how many bytes of calldata will need to be transferred to L1.
        // We published the data as ABI-encoded `bytes`, so we pay for:
        // - bytecode length in bytes, rounded up to a multiple of 32 (it always is, because of the bytecode format)
        // - 32 bytes of encoded offset
        // - 32 bytes of encoded length

        uint256 gasToPay = (_l1PreimageBytesLen + 64) * pricePerPubdataByteInGas;
        _burnGas(Utils.safeCastToU32(gasToPay));

        // Send a log to L1 that bytecode should be known.
        // L1 smart contract will check the availability of bytecodeHash preimage.
        SystemContractHelper.toL1(true, _bytecodeHash, _l1PreimageHash);
    }

    /// @notice Method used for burning a certain amount of gas
    /// @param _gasToPay The number of gas to burn.
    function _burnGas(uint32 _gasToPay) internal view {
        bool precompileCallSuccess = SystemContractHelper.precompileCall(
            0, // The precompile parameters are formal ones. We only need the precompile call to burn gas.
            _gasToPay
        );
        require(precompileCallSuccess, "Failed to charge gas");
    }

    /// @notice Returns the marker stored for a bytecode hash. 1 means that the bytecode hash is known
    /// and can be used for deploying contracts. 0 otherwise.
    function getMarker(bytes32 _hash) public view override returns (uint256 marker) {
        assembly {
            marker := sload(_hash)
        }
    }

    /// @notice Validates the format of bytecodehash
    /// @dev zk-circuit accepts & handles only valid format of bytecode hash, other input has undefined behavior
    /// That's why we need to validate it
    function _validateBytecode(bytes32 _bytecodeHash) internal pure {
        uint8 version = uint8(_bytecodeHash[0]);
        require(version == 1 && _bytecodeHash[1] == bytes1(0), "Incorrectly formatted bytecodeHash");

        require(Utils.bytecodeLenInWords(_bytecodeHash) % 2 == 1, "Code length in words must be odd");
    }
}
