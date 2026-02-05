// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {UnknownVerifierVersion} from "../L1StateTransitionErrors.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {EmptyProofLength, UnknownVerifierType, MockVerifierNotSupported, InvalidProofFormat, ZeroAddress, AddressAlreadySet, EmptyPublicInputsLength} from "../../common/L1ContractErrors.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

/// @title ZKsync OS Dual Verifier
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This contract wraps PLONK verifiers and routes zk-SNARK proof verification
/// to the verifier based on the provided proof type. Unlike the Era version which supports both FFLONK and PLONK,
/// this ZKsync OS version only supports PLONK verification as FFLONK has been deprecated for ZKsync OS.
/// The contract also includes mock verification support for testnet purposes.
/// It reuses the same interface as on the original `Verifier` contract, while abusing one of the fields
/// (`_recursiveAggregationInput`) for proof verification type.
contract ZKsyncOSDualVerifier is Ownable2Step, IVerifier {
    /// @dev Type of verification for ZKsync OS PLONK verifier.
    uint256 internal constant ZKSYNC_OS_PLONK_VERIFICATION_TYPE = 2;

    // @notice This is proof-skipping verifier (mock), it's only checking the correctness of the public inputs.
    uint256 internal constant ZKSYNC_OS_MOCK_VERIFICATION_TYPE = 3;

    /// @notice Mapping of different PLONK verifiers dependent on their version.
    /// @dev Only PLONK verifiers are supported for ZKsync OS. FFLONK has been deprecated.
    mapping(uint32 => IVerifier) public plonkVerifiers;

    /// @param _plonkVerifier The address of the PLONK verifier contract.
    /// @param _initialOwner The address of the initial owner of this contract.
    /// @dev FFLONK is not supported for ZKsync OS as it has been deprecated.
    constructor(IVerifier _plonkVerifier, address _initialOwner) {
        plonkVerifiers[0] = _plonkVerifier;
        _transferOwnership(_initialOwner);
    }

    /// @notice Adds a new PLONK verifier for the specified version.
    /// @param version The version number for the verifier.
    /// @param _plonkVerifier The address of the PLONK verifier contract.
    /// @dev Only PLONK verifiers are supported. FFLONK has been deprecated for ZKsync OS.
    function addVerifier(uint32 version, IVerifier _plonkVerifier) external onlyOwner {
        require(address(_plonkVerifier) != address(0), ZeroAddress());
        require(plonkVerifiers[version] == IVerifier(address(0)), AddressAlreadySet(address(plonkVerifiers[version])));
        plonkVerifiers[version] = _plonkVerifier;
    }

    /// @notice Removes the PLONK verifier for the specified version.
    /// @param version The version number of the verifier to remove.
    function removeVerifier(uint32 version) external onlyOwner {
        delete plonkVerifiers[version];
    }

    /// @notice Routes zk-SNARK proof verification to the appropriate verifier based on the proof type.
    /// @param _publicInputs The public inputs to the proof.
    /// @param _proof The zk-SNARK proof itself.
    /// @dev  The first element of the `_proof` determines the verifier type.
    ///     - 2 indicates the ZKsync OS Plonk verifier should be used.
    ///     - 3 indicates the mock verifier (skipping proof verification) should be used.
    /// @return Returns `true` if the proof verification succeeds, otherwise throws an error.
    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) public view virtual returns (bool) {
        // Ensure the proof has a valid length (at least one element
        // for the proof system differentiator).
        if (_proof.length == 0) {
            revert EmptyProofLength();
        }

        // Ensure public inputs are not empty for clarity.
        if (_publicInputs.length == 0) {
            revert EmptyPublicInputsLength();
        }

        // The first element of `_proof` determines the verifier type.
        uint256 verifierType = _proof[0] & 255;
        uint32 verifierVersion = uint32(_proof[0] >> 8);

        // Validate that unused bits (40-255) are zero.
        if (_proof[0] >> 40 != 0) {
            revert InvalidProofFormat();
        }

        if (plonkVerifiers[verifierVersion] == IVerifier(address(0))) {
            revert UnknownVerifierVersion();
        }

        if (verifierType == ZKSYNC_OS_PLONK_VERIFICATION_TYPE) {
            uint256[] memory args = new uint256[](1);
            args[0] = computeZKsyncOSHash(_proof[1], _publicInputs);

            return plonkVerifiers[verifierVersion].verify(args, _extractZKsyncOSProof(_proof));
        } else if (verifierType == ZKSYNC_OS_MOCK_VERIFICATION_TYPE) {
            uint256[] memory args = new uint256[](1);
            args[0] = computeZKsyncOSHash(_proof[1], _publicInputs);

            return mockVerify(args, _extractZKsyncOSProof(_proof));
        }
        // If the verifier type is unknown, revert with an error.
        else {
            revert UnknownVerifierType();
        }
    }

    /// @dev Verifies the correctness of public input, doesn't check the validity of proof itself.
    function mockVerify(uint256[] memory, uint256[] memory) public view virtual returns (bool) {
        revert MockVerifierNotSupported();
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
        uint32 verifierVersion = uint32(_verifierType >> 8);

        // Validate that unused bits (40-255) are zero.
        if (_verifierType >> 40 != 0) {
            revert InvalidProofFormat();
        }

        if (plonkVerifiers[verifierVersion] == IVerifier(address(0))) {
            revert UnknownVerifierVersion();
        }

        if (verifierType == ZKSYNC_OS_PLONK_VERIFICATION_TYPE) {
            return plonkVerifiers[verifierVersion].verificationKeyHash();
        }
        // If the verifier type is unknown, revert with an error.
        else {
            revert UnknownVerifierType();
        }
    }

    function _extractZKsyncOSProof(uint256[] calldata _proof) internal pure returns (uint256[] memory result) {
        uint256 resultLength = _proof.length - 1 - 1;

        // Allocate memory for the new array (_proof.length - 1) since the first element is omitted.
        result = new uint256[](resultLength);

        // Copy elements starting from index 1 (the second element) of the original array.
        assembly {
            calldatacopy(add(result, 0x20), add(_proof.offset, 0x40), mul(resultLength, 0x20))
        }
    }

    function computeZKsyncOSHash(
        uint256 initialHash,
        uint256[] calldata _publicInputs
    ) public pure returns (uint256 result) {
        uint256 publicInputsLength = _publicInputs.length;
        result = initialHash;

        uint256 i = 0;

        if (result == 0) {
            result = _publicInputs[0];
            i = 1;
        }

        for (; i < publicInputsLength; ++i) {
            result = uint256(keccak256(abi.encodePacked(result, _publicInputs[i]))) >> 32;
        }
    }
}
