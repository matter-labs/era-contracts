// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ZKsyncOSDualVerifier} from "./ZKsyncOSDualVerifier.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {InvalidMockProofLength, InvalidProof} from "../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Modified version of the main verifier contract for the testnet environment
/// @dev This contract is used to support mock verification.
contract ZKsyncOSTestnetVerifier is ZKsyncOSDualVerifier {
    constructor(IVerifier _plonkVerifier, address _initialOwner) ZKsyncOSDualVerifier(_plonkVerifier, _initialOwner) {
        assert(block.chainid != 1);
    }

    /// @dev Verifies the correctness of public input, doesn't check the validity of proof itself.
    function mockVerify(uint256[] memory _publicInputs, uint256[] memory _proof) public pure override returns (bool) {
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
}
