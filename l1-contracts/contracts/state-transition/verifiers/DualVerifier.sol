// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifierV2} from "../chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {UnknownVerifierType, EmptyProofLength} from "../../common/L1ContractErrors.sol";

// 0xd08a97e6
error InvalidMockProofLength();
// 0x09bde339
error InvalidProof();

// 0x616008dd
error UnsupportedChainIdForMockVerifier();

/// @title Dual Verifier
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This contract wraps two different verifiers (FFLONK and PLONK) and routes zk-SNARK proof verification
/// to the correct verifier based on the provided proof type. It reuses the same interface as on the original `Verifier`
/// contract, while abusing on of the fields (`_recursiveAggregationInput`) for proof verification type. The contract is
/// needed for the smooth transition from PLONK based verifier to the FFLONK verifier.
contract DualVerifier is IVerifier {
    /// @notice Type of verification for FFLONK verifier.
    uint256 internal constant FFLONK_VERIFICATION_TYPE = 0;

    /// @notice Type of verification for PLONK verifier.
    uint256 internal constant PLONK_VERIFICATION_TYPE = 1;

    uint256 internal constant OHBENDER_PLONK_VERIFICATION_TYPE = 2;

    // @notice This is test only verifier (mock), and must be removed before prod.
    uint256 internal constant OHBENDER_MOCK_VERIFICATION_TYPE = 3;

    address public ctmOwner;

    mapping(uint32 => IVerifierV2) public fflonkVerifiers;
    mapping(uint32 => IVerifier) public plonkVerifiers;

    /// @param _fflonkVerifier The address of the FFLONK verifier contract.
    /// @param _plonkVerifier The address of the PLONK verifier contract.
    /// @param _ctmOwner The address of the contract owner, who can add or remove verifiers.
    constructor(IVerifierV2 _fflonkVerifier, IVerifier _plonkVerifier, address _ctmOwner) {
        ctmOwner = _ctmOwner;
        fflonkVerifiers[0] = _fflonkVerifier;
        plonkVerifiers[0] = _plonkVerifier;
    }

    function addVerifier(uint32 version, IVerifierV2 _fflonkVerifier, IVerifier _plonkVerifier) external {
        require(msg.sender == ctmOwner, "Only ctmOwner can add verifiers");
        // Add logic to add verifiers
        fflonkVerifiers[version] = _fflonkVerifier;
        plonkVerifiers[version] = _plonkVerifier;
    }

    function removeVerifier(uint32 version) external {
        require(msg.sender == ctmOwner, "Only ctmOwner can remove verifiers");
        delete fflonkVerifiers[version];
        delete plonkVerifiers[version];
    }

    /// @notice Routes zk-SNARK proof verification to the appropriate verifier (FFLONK or PLONK) based on the proof type.
    /// @param _publicInputs The public inputs to the proof.
    /// @param _proof The zk-SNARK proof itself.
    /// @dev  The first element of the `_proof` determines the verifier type.
    ///     - 0 indicates the FFLONK verifier should be used.
    ///     - 1 indicates the PLONK verifier should be used.
    /// @return Returns `true` if the proof verification succeeds, otherwise throws an error.
    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) public view virtual returns (bool) {
        // Ensure the proof has a valid length (at least one element
        // for the proof system differentiator).
        if (_proof.length == 0) {
            revert EmptyProofLength();
        }

        // The first element of `_proof` determines the verifier type (either FFLONK or PLONK).
        uint256 verifierType = _proof[0] & 255;
        uint32 verifierVersion = uint32(_proof[0] >> 8);
        require(
            fflonkVerifiers[verifierVersion] != IVerifierV2(address(0)) ||
                plonkVerifiers[verifierVersion] != IVerifier(address(0)),
            "Unknown verifier version"
        );

        if (verifierType == FFLONK_VERIFICATION_TYPE) {
            return fflonkVerifiers[verifierVersion].verify(_publicInputs, _extractProof(_proof));
        } else if (verifierType == PLONK_VERIFICATION_TYPE) {
            return plonkVerifiers[verifierVersion].verify(_publicInputs, _extractProof(_proof));
        } else if (verifierType == OHBENDER_PLONK_VERIFICATION_TYPE) {
            uint256[] memory args = new uint256[](1);
            args[0] = computeOhBenderHash(_proof[1], _publicInputs);

            return plonkVerifiers[verifierVersion].verify(args, _extractOhBenderProof(_proof));
        } else if (verifierType == OHBENDER_MOCK_VERIFICATION_TYPE) {
            // just for safety - only allowing default anvil chain and sepolia testnet
            if (block.chainid != 31337 && block.chainid != 11155111) {
                revert UnsupportedChainIdForMockVerifier();
            }

            uint256[] memory args = new uint256[](1);
            args[0] = computeOhBenderHash(_proof[1], _publicInputs);

            return mockverify(args, _extractOhBenderProof(_proof));
        }
        // If the verifier type is unknown, revert with an error.
        else {
            revert UnknownVerifierType();
        }
    }

    function mockverify(uint256[] memory _publicInputs, uint256[] memory _proof) public view virtual returns (bool) {
        if (_proof.length != 2) {
            revert InvalidMockProofLength();
        }
        if (_proof[0] != 13) {
            revert InvalidProof();
        }
        if (_proof[1] != _publicInputs[0]) {
            revert InvalidProof();
        }
        return true;
    }

    /// @inheritdoc IVerifier
    /// @dev Used for backward compatibility with older Verifier implementation. Returns PLONK verification key hash.
    function verificationKeyHash() external view returns (bytes32) {
        return plonkVerifiers[0].verificationKeyHash();
    }

    /// @notice Calculates a keccak256 hash of the runtime loaded verification keys from the selected verifier.
    /// @return The keccak256 hash of the loaded verification keys based on the verifier.
    function verificationKeyHash(uint256 _verifierType) external view returns (bytes32) {
        uint256 verifierType = _verifierType & 255;
        uint32 verifierVersion = uint32(verifierType >> 8);

        require(
            fflonkVerifiers[verifierVersion] != IVerifierV2(address(0)) ||
                plonkVerifiers[verifierVersion] != IVerifier(address(0)),
            "Unknown verifier version"
        );

        if (verifierType == FFLONK_VERIFICATION_TYPE) {
            return fflonkVerifiers[verifierVersion].verificationKeyHash();
        } else if (verifierType == PLONK_VERIFICATION_TYPE) {
            return plonkVerifiers[verifierVersion].verificationKeyHash();
        }
        // If the verifier type is unknown, revert with an error.
        else {
            revert UnknownVerifierType();
        }
    }

    /// @notice Extract the proof by removing the first element (proof type differentiator).
    /// @param _proof The proof array array.
    /// @return result A new array with the first element removed. The first element was used as a hack for
    /// differentiator between FFLONK and PLONK proofs.
    function _extractProof(uint256[] calldata _proof) internal pure returns (uint256[] memory result) {
        uint256 resultLength = _proof.length - 1;

        // Allocate memory for the new array (_proof.length - 1) since the first element is omitted.
        result = new uint256[](resultLength);

        // Copy elements starting from index 1 (the second element) of the original array.
        assembly {
            calldatacopy(add(result, 0x20), add(_proof.offset, 0x20), mul(resultLength, 0x20))
        }
    }

    function _extractOhBenderProof(uint256[] calldata _proof) internal pure returns (uint256[] memory result) {
        uint256 resultLength = _proof.length - 1 - 1;

        // Allocate memory for the new array (_proof.length - 1) since the first element is omitted.
        result = new uint256[](resultLength);

        // Copy elements starting from index 1 (the second element) of the original array.
        assembly {
            calldatacopy(add(result, 0x20), add(_proof.offset, 0x40), mul(resultLength, 0x20))
        }
    }

    function computeOhBenderHash(
        uint256 initialHash,
        uint256[] calldata _publicInputs
    ) public pure returns (uint256 result) {
        if (initialHash == 0) {
            initialHash = _publicInputs[0];
            for (uint256 i = 1; i < _publicInputs.length; i++) {
                initialHash = uint256(keccak256(abi.encodePacked(initialHash, _publicInputs[i]))) >> 32;
            }
        } else {
            for (uint256 i = 0; i < _publicInputs.length; i++) {
                initialHash = uint256(keccak256(abi.encodePacked(initialHash, _publicInputs[i]))) >> 32;
            }
        }

        result = initialHash;
    }
}
