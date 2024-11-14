// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IVerifier} from "./chain-interfaces/IVerifier.sol";
import {ZKChainStorage} from "./chain-deps/ZKChainStorage.sol";
import {ZeroAddress} from "../common/L1ContractErrors.sol";

/// @title Dual Verifier
/// @author Matter Labs
/// @notice Wrapper contract to verify a zk-SNARK proof based on the proof type
/// @custom:security-contact security@matterlabs.dev
contract DualVerifier is IVerifier{

    // slither-disable-next-line uninitialized-state
    ZKChainStorage internal s;
    
    /// @dev Routes the proof verification to appropriate verifier based on the length of proof
    /// @inheritdoc IVerifier
    function verify(
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof
    ) public view virtual returns (bool) {
        address plonkVerifier = s.plonkVerifier;
        address fflonkVerifier = s.fflonkVerifier;
        uint256 fflonkProofLength = s.fflonkProofLength;
        uint256 proofLength = _proof.length;
        // Selects the verifier based on the proof type
        address verifier;
        if (proofLength == fflonkProofLength) {
            verifier = fflonkVerifier;
        }
        else {
            verifier = plonkVerifier;
        }

        if (verifier == address(0)) {
            revert ZeroAddress();
        }

        return IVerifier(verifier).verify(_publicInputs, _proof);

    }
}