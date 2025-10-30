// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {UnknownVerifierVersion, InvalidVerifierVersion} from "../L1StateTransitionErrors.sol";
import {IVerifierV2} from "../chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {EmptyProofLength, Unauthorized, UnknownVerifierType, InvalidMockProofLength, UnsupportedChainIdForMockVerifier, InvalidProof} from "../../common/L1ContractErrors.sol";
import {ZKsyncOSChainTypeManager} from "../../state-transition/ZKsyncOSChainTypeManager.sol";
import {IDualVerifier} from "../chain-interfaces/IDualVerifier.sol";
import {IZKsyncOSVerifier} from "../chain-interfaces/IZKsyncOSVerifier.sol";

/// @title Dual Verifier
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This contract wraps ZKsync OS specific Plonk verifiers and routes zk-SNARK proof verification
/// to the verifier based on the provided proof type. It reuses the same interface as on the original `Verifier`
/// contract, while abusing on of the fields (`_recursiveAggregationInput`) for proof verification type.
contract ZKsyncOSDualVerifier is IVerifier, IDualVerifier {
    uint32 public constant DEFAULT_EXECUTION_VERSION = 3;

    /// @dev Type of verification for ZKsync OS PLONK verifier.
    uint256 internal constant ZKSYNC_OS_PLONK_VERIFICATION_TYPE = 2;

    // @notice This is proof-skipping verifier (mock), it's only checking the correctness of the public inputs.
    uint256 internal constant ZKSYNC_OS_MOCK_VERIFICATION_TYPE = 3;

    /// @dev Address of the CTM, owner of which can also add or remove verifiers.
    ZKsyncOSChainTypeManager public immutable CHAIN_TYPE_MANAGER;

    /// @notice Mapping of different verifiers dependant on their version.
    mapping(uint32 => IVerifierV2) public fflonkVerifiers;
    mapping(uint32 => IVerifier) public plonkVerifiers;

    modifier onlyCtmOwner() {
        if (msg.sender != CHAIN_TYPE_MANAGER.owner()) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @param _fflonkVerifier The address of the FFLONK verifier contract.
    /// @param _plonkVerifier The address of the PLONK verifier contract.
    /// @param _chainTypeManager The address of the CTM, owner of which can add or remove verifiers.
    constructor(IVerifierV2 _fflonkVerifier, IVerifier _plonkVerifier, address _chainTypeManager) {
        CHAIN_TYPE_MANAGER = ZKsyncOSChainTypeManager(_chainTypeManager);
        fflonkVerifiers[DEFAULT_EXECUTION_VERSION] = _fflonkVerifier;
        plonkVerifiers[DEFAULT_EXECUTION_VERSION] = _plonkVerifier;

        if (_fflonkVerifier != IVerifierV2(address(0))) {
            if (IZKsyncOSVerifier(address(_fflonkVerifier)).executionVersion() != DEFAULT_EXECUTION_VERSION) {
                revert InvalidVerifierVersion();
            }
        }
        if (_plonkVerifier != IVerifier(address(0))) {
            if (IZKsyncOSVerifier(address(_plonkVerifier)).executionVersion() != DEFAULT_EXECUTION_VERSION) {
                revert InvalidVerifierVersion();
            }
        }
    }

    function addVerifier(uint32 version, IVerifierV2 _fflonkVerifier, IVerifier _plonkVerifier) external onlyCtmOwner {
        fflonkVerifiers[version] = _fflonkVerifier;
        plonkVerifiers[version] = _plonkVerifier;
    }

    function removeVerifier(uint32 version) external onlyCtmOwner {
        delete fflonkVerifiers[version];
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

        // The first element of `_proof` determines the verifier type.
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
        } else if (verifierType == ZKSYNC_OS_MOCK_VERIFICATION_TYPE) {
            // just for safety - not allowing to use mock verifier on mainnet
            if (block.chainid == 1) {
                revert UnsupportedChainIdForMockVerifier();
            }

            uint256[] memory args = new uint256[](1);
            args[0] = computeZKSyncOSHash(_proof[1], _publicInputs);

            return mockVerify(args, _extractZKSyncOSProof(_proof));
        }
        // If the verifier type is unknown, revert with an error.
        else {
            revert UnknownVerifierType();
        }
    }

    /// @dev Verifies the correctness of public input, doesn't check the validity of proof itself.
    function mockVerify(uint256[] memory _publicInputs, uint256[] memory _proof) public view virtual returns (bool) {
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
        return plonkVerifiers[DEFAULT_EXECUTION_VERSION].verificationKeyHash();
    }

    /// @notice Calculates a keccak256 hash of the runtime loaded verification keys from the selected verifier.
    /// @return The keccak256 hash of the loaded verification keys based on the verifier.
    function verificationKeyHash(uint256 _verifierType) external view returns (bytes32) {
        uint256 verifierType = _verifierType & 255;
        uint32 verifierVersion = uint32(_verifierType >> 8);

        if (
            fflonkVerifiers[verifierVersion] == IVerifierV2(address(0)) &&
            plonkVerifiers[verifierVersion] == IVerifier(address(0))
        ) {
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
