// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interfaces/IKnownCodesStorage.sol";
import "./libraries/Utils.sol";
import "./libraries/SystemContractHelper.sol";
import {BOOTLOADER_FORMAL_ADDRESS, BYTECODE_PUBLISHING_OVERHEAD} from "./Constants.sol";

/**
 * @author Matter Labs
 * @notice The storage of this contract will basically serve as a mapping for the known code hashes.
 * @dev Code hash is not strictly a hash, it's a structure where the first 2 bytes
 * denote the version of the hash, the second two bytes denote the length in 32-byte
 * words. And then the next 28 bytes is the truncated hash.
 */
contract KnownCodesStorage is IKnownCodesStorage {
    modifier onlyBootloader() {
        require(msg.sender == BOOTLOADER_FORMAL_ADDRESS, "Callable only by the bootloader");
        _;
    }

    /// @notice The method that is used by the bootloader to mark several bytecode hashes as known.
    /// @param _shouldSendToL1 Whether the bytecode should be sent on L1.
    /// @param _hashes Hashes of the bytecodes to be marked as known
    function markFactoryDeps(bool _shouldSendToL1, bytes32[] calldata _hashes) external onlyBootloader {
        unchecked {
            uint256 hashesLen = _hashes.length;
            for (uint256 i = 0; i < hashesLen; ++i) {
                _markFactoryDeps(_hashes[i], _shouldSendToL1);
            }
        }
    }

    /// @notice The method used to mark a single bytecode hash as known
    /// @param _bytecodeHash The hash of the bytecode to be marked as known
    /// @param _shouldSendToL1 Whether the bytecode should be sent on L1
    function _markFactoryDeps(bytes32 _bytecodeHash, bool _shouldSendToL1) internal {
        if (getMarker(_bytecodeHash) == 0) {
            _validateBytecode(_bytecodeHash);

            if (_shouldSendToL1) {
                _sendBytecodeToL1(_bytecodeHash);
            }

            // Save as known, to not resend the log to L1
            assembly {
                sstore(_bytecodeHash, 1)
            }

            emit MarkedAsKnown(_bytecodeHash, _shouldSendToL1);
        }
    }

    /// @notice Method used for sending the bytecode (preimage for the bytecode hash) on L1.
    /// @param _bytecodeHash The hash of the bytecode that is to be sent on L1.
    /// @dev This method sends a single L2->L1 log with the bytecodeHash. It is the responsibility of the L1
    /// smart contracts to make sure that the preimage for this bytecode hash has been shown.
    function _sendBytecodeToL1(bytes32 _bytecodeHash) internal {
        // Burn gas to cover the cost of publishing pubdata on L1
        uint256 gasToPay;
        {
            // Get bytecode length in bytes
            uint256 codeLengthInBytes = Utils.bytecodeLenInBytes(_bytecodeHash);

            // Get the cost of 1 pubdata byte in gas
            uint256 meta = SystemContractHelper.getZkSyncMetaBytes();
            uint256 pricePerPubdataByteInGas = SystemContractHelper.getGasPerPubdataByteFromMeta(meta);

            gasToPay = (codeLengthInBytes + BYTECODE_PUBLISHING_OVERHEAD) * pricePerPubdataByteInGas;
        }

        _burnGas(gasToPay);

        // Send a log to L1 that bytecode should be known.
        // L1 smart contract will check the availability of bytecodeHash preimage.
        SystemContractHelper.toL1(true, _bytecodeHash, 0);
    }

    /// @notice Method used for burning a certain amount of gas (gas in EVM terms)
    /// @param _gasToPay The number of gas to pay
    function _burnGas(uint256 _gasToPay) internal view {
        // The precompile parameters are formal ones. We only need the precompile call
        // to burn gas.
        uint256 precompileParams = SystemContractHelper.packPrecompileParams(0, 0, 0, 0, 0);

        bool precompileCallSuccess = SystemContractHelper.precompileCall(
            precompileParams,
            Utils.safeCastToU32(_gasToPay)
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
