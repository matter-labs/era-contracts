// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EraDualVerifier} from "./EraDualVerifier.sol";
import {ZKsyncOSDualVerifier} from "./ZKsyncOSDualVerifier.sol";
import {IVerifierV2} from "../chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {IDualVerifier} from "../chain-interfaces/IDualVerifier.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Modified version of the main verifier contract for the testnet environment
/// @dev This contract is used to skip the zkp verification for the testnet environment.
/// If the proof is not empty, it will verify it using the main verifier contract,
/// otherwise, it will skip the verification.
contract TestnetVerifier is IVerifier, IDualVerifier {
    IDualVerifier public immutable dualVerifier;

    constructor(
        IVerifierV2 _fflonkVerifier,
        IVerifier _plonkVerifier,
        address _zksyncOSVerifierOwner,
        bool _isZKsyncOS
    ) {
        assert(block.chainid != 1);

        if (_isZKsyncOS) {
            dualVerifier = new ZKsyncOSDualVerifier(_fflonkVerifier, _plonkVerifier, _zksyncOSVerifierOwner);
        } else {
            dualVerifier = new EraDualVerifier(_fflonkVerifier, _plonkVerifier);
        }
    }

    /// @dev Verifies a zk-SNARK proof, skipping the verification if the proof is empty.
    /// @inheritdoc IVerifier
    function verify(uint256[] calldata _publicInputs, uint256[] calldata _proof) public view override returns (bool) {
        // We allow skipping the zkp verification for the test(net) environment
        // If the proof is not empty, verify it, otherwise, skip the verification
        if (_proof.length == 0) {
            return true;
        }

        return dualVerifier.verify(_publicInputs, _proof);
    }

    /// @inheritdoc IVerifier
    function verificationKeyHash() external view override returns (bytes32) {
        return dualVerifier.verificationKeyHash();
    }

    function verificationKeyHash(uint256 _verifierType) external view returns (bytes32) {
        return dualVerifier.verificationKeyHash(_verifierType);
    }

    function plonkVerifiers(uint32 version) external view returns (IVerifier) {
        return dualVerifier.plonkVerifiers(version);
    }

    function fflonkVerifiers(uint32 version) external view returns (IVerifierV2) {
        return dualVerifier.fflonkVerifiers(version);
    }
}
