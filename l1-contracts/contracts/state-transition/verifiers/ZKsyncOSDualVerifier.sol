// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {OnlyCtmOwner, UnknownVerifierVersion} from "../L1StateTransitionErrors.sol";
import {IVerifierV2} from "../chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {EmptyProofLength, UnknownVerifierType} from "../../common/L1ContractErrors.sol";

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
contract ZKsyncOSDualVerifier is IVerifier {
    uint256 internal constant ZKSYNC_OS_PLONK_VERIFICATION_TYPE = 2;

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
        if (msg.sender != ctmOwner) {
            revert OnlyCtmOwner();
        }
        // Add logic to add verifiers
        fflonkVerifiers[version] = _fflonkVerifier;
        plonkVerifiers[version] = _plonkVerifier;
    }

    function removeVerifier(uint32 version) external {
        if (msg.sender != ctmOwner) {
            revert OnlyCtmOwner();
        }
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
        if (
            fflonkVerifiers[verifierVersion] == IVerifierV2(address(0)) &&
            plonkVerifiers[verifierVersion] == IVerifier(address(0))
        ) {
            revert UnknownVerifierVersion();
        }

        if (verifierType == ZKSYNC_OS_PLONK_VERIFICATION_TYPE) {
            uint256[] memory args = new uint256[](1);
            args[0] = computeZKSyncOSHash(_proof[1], _publicInputs);

            return plonkVerifiers[verifierVersion].verify(args, _extractZKSyncOSProof(_proof));
        }
        // If the verifier type is unknown, revert with an error.
        else {
            revert UnknownVerifierType();
        }
    }

    /// @inheritdoc IVerifier
    /// @dev Used for backward compatibility with older Verifier implementation. Returns PLONK verification key hash.
    function verificationKeyHash() external view returns (bytes32) {
        return plonkVerifiers[0].verificationKeyHash();
    }

    function _extractZKSyncOSProof(uint256[] calldata _proof) internal pure returns (uint256[] memory result) {
        uint256 resultLength = _proof.length - 1 - 1;

        // Allocate memory for the new array (_proof.length - 1) since the first element is omitted.
        result = new uint256[](resultLength);

        // Copy elements starting from index 1 (the second element) of the original array.
        assembly {
            calldatacopy(add(result, 0x20), add(_proof.offset, 0x40), mul(resultLength, 0x20))
        }
    }

    function computeZKSyncOSHash(
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
