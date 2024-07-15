// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.8.20;

import "./INewHorizenProofVerifier.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./lib/Merkle.sol";

/**
 * @title NewHorizenProofVerifier Contract
 * @notice It allows submitting and verifying attestation proofs that occur off-chain.
 * @dev this replaces the default FflonkVerifier used in CDKValidium
 */
contract NewHorizenProofVerifier is INewHorizenProofVerifier, AccessControl {
    /// @dev Role required for operator to submit/verify proofs.
    bytes32 public constant OPERATOR = keccak256("OPERATOR");

    /// @notice Latest valid attestationId for bridge events.
    uint256 public latestAttestationId;

    /// @notice Mapping of MC attestationIds to proofsAttestations.
    mapping(uint256 => bytes32) public proofsAttestations;

    bool public isEnforcingSequentialAttestations;

    /// @notice Emitted when a new attestation is posted.
    /// @param _attestationId Event attestationId.
    /// @param _proofsAttestation Aggregated proofs attestation.
    event AttestationPosted(uint256 indexed _attestationId, bytes32 indexed _proofsAttestation);

    /// @notice Posted _attestationId must be sequential.
    error InvalidAttestation();

    /// @notice Batch submissions must have an equal number of ids to proof attestations.
    error InvalidBatchCounts();

    /// @notice Prevent owner from handing over ownership
    error OwnerCannotRenounce();

    /**
     * @notice Construct a new NewHorizenProofVerifier contract
     * @param _operator Operator for the contract
     */
    constructor(address _operator) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender); // it is used as owner
        _grantRole(OPERATOR, _operator);
    }

    /**
     * @notice Submit Attestation for a monotonically increasing attestationId
     * @param _attestationId the id of the attestation from the NewHorizen Relayer
     * @param _proofsAttestation attestation of a set of proofs
     * @dev caller must have the OPERATOR role, admin can add caller via AccessControl.grantRole()
     */
    function submitAttestation(uint256 _attestationId, bytes32 _proofsAttestation) external onlyRole(OPERATOR) {
        // Optionally, check that the new _attestationId is sequential.
        if (isEnforcingSequentialAttestations && (_attestationId != latestAttestationId + 1)) {
            revert InvalidAttestation();
        }

        latestAttestationId = _attestationId;
        proofsAttestations[_attestationId] = _proofsAttestation;

        emit AttestationPosted(_attestationId, _proofsAttestation);
    }

    /**
     * @notice Submit a Batch of attestations, useful if a relayer needs to catch up.
     * @param _attestationIds ids of attestations from the NewHorizen Relayer
     * @param _proofsAttestation a set of proofs
     * @dev caller must have the OPERATOR role, admin can add caller via AccessControl.grantRole()
     */
    function submitAttestationBatch(
        uint256[] calldata _attestationIds,
        bytes32[] calldata _proofsAttestation
    ) external onlyRole(OPERATOR) {
        if (_attestationIds.length != _proofsAttestation.length) {
            revert InvalidBatchCounts();
        }

        uint256 limit = _attestationIds.length;
        uint256 sequence = latestAttestationId;

        // Optionally, check that all new _attestationIds are sequential.
        if (isEnforcingSequentialAttestations) {
            for (uint256 i; i < limit; ) {
                if (_attestationIds[i] != sequence + (i + 1)) {
                    revert InvalidAttestation();
                }

                unchecked {
                    ++i;
                }
            }
        }

        for (uint256 i; i < limit; ) {
            proofsAttestations[_attestationIds[i]] = _proofsAttestation[i];
            emit AttestationPosted(_attestationIds[i], _proofsAttestation[i]);
            unchecked {
                ++i;
            }
        }

        latestAttestationId = _attestationIds[_attestationIds.length - 1];
    }

    /**
     * @notice Verify a proof against a stored merkle tree
     * @param _attestationId the id of the attestation from the Horizen main chain
     * @param _leaf of the merkle tree
     * @param _merklePath path from leaf to root of the merkle tree
     * @param _leafCount the number of leaves in the merkle tree
     * @param _index the 0 indexed `index`'th leaf from the bottom left of the tree, see test cases.
     * @dev caller must have the OPERATOR role, admin can add caller via AccessControl.grantRole()
     */
    function verifyProofAttestation(
        uint256 _attestationId,
        bytes32 _leaf,
        bytes32[] calldata _merklePath,
        uint256 _leafCount,
        uint256 _index
    ) external view returns (bool) {
        // AttestationId must have already been posted.
        if (_attestationId > latestAttestationId) {
            return false;
        }

        // Load the proofsAttestations at the given index from storage.
        bytes32 proofsAttestation = proofsAttestations[_attestationId];

        // Verify the proofsAttestations/path.
        return Merkle.verifyProofKeccak(proofsAttestation, _merklePath, _leafCount, _index, _leaf);
    }

    function mockVerifyProofAttestation() external view returns (bool) {
        return true;
    }

    bool public lastResult;

    /**
     * @notice Flip sequential enforcement for submitAttestation()
     * @dev caller must have the OPERATOR role
     */
    function flipIsEnforcingSequentialAttestations() external onlyRole(OPERATOR) {
        isEnforcingSequentialAttestations = !isEnforcingSequentialAttestations;
    }

    /**
     * @notice prohibits owner to renounce its role with this override
     */
    function renounceRole(bytes32 role, address account) public override {
        if (role == DEFAULT_ADMIN_ROLE) {
            revert OwnerCannotRenounce();
        }
        super.renounceRole(role, account);
    }
}
