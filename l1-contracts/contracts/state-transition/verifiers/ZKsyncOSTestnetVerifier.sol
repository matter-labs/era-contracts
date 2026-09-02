// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ZKsyncOSVerifier} from "./ZKsyncOSVerifier.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {IZKsyncOSVerifier} from "../chain-interfaces/IZKsyncOSVerifier.sol";
import {InvalidMockProofLength, InvalidProof} from "../../common/L1ContractErrors.sol";
import {MAINNET_CHAIN_ID, ZKSYNC_OS_MOCK_PROOF_LENGTH, ZKSYNC_OS_MOCK_PROOF_MAGIC} from "../../common/Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Modified version of the main verifier contract for the testnet environment
/// @dev This contract is used to support mock verification.
contract ZKsyncOSTestnetVerifier is ZKsyncOSVerifier {
    constructor(IVerifier _plonkVerifier) ZKsyncOSVerifier(_plonkVerifier) {
        assert(block.chainid != MAINNET_CHAIN_ID);
    }

    /// @inheritdoc IZKsyncOSVerifier
    // solhint-disable-next-line func-name-mixedcase
    function IS_TESTNET_VERIFIER() external pure override returns (bool) {
        return true;
    }

    /// @dev Verifies the correctness of public input, doesn't check the validity of proof itself.
    function mockVerify(uint256[] memory _publicInputs, uint256[] memory _proof) public pure override returns (bool) {
        if (_proof.length != ZKSYNC_OS_MOCK_PROOF_LENGTH) {
            revert InvalidMockProofLength();
        }
        if (_proof[0] != ZKSYNC_OS_MOCK_PROOF_MAGIC) {
            revert InvalidProof();
        }
        if (_proof[1] != _publicInputs[0]) {
            revert InvalidProof();
        }
        return true;
    }
}
