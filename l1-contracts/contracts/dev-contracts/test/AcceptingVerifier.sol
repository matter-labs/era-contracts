// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";

/// @notice Test-only verifier that accepts any proof. Used as the chain fixture's
///         verifier so batch-processing suites can prove with placeholder proofs;
///         real verifier behavior is covered by the ZKsyncOSVerifier unit tests.
contract AcceptingVerifier is IVerifier {
    function verify(uint256[] calldata, uint256[] calldata) external pure returns (bool) {
        return true;
    }

    function verificationKeyHash() external pure returns (bytes32) {
        return keccak256("AcceptingVerifier");
    }
}
