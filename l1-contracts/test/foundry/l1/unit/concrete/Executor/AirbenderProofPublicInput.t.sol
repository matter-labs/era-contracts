// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ExecutorProvingTest} from "contracts/dev-contracts/test/ExecutorProvingTest.sol";
import {AirbenderBinaryCommitmentNotSet} from "contracts/common/L1ContractErrors.sol";

/// @notice Unit tests for the Executor's airbender public-input reconstruction.
/// The airbender SNARK proof was generated against
/// `keccak(program_output ‖ binary_commitment) >> 32`, where the guest emits
/// `program_output = keccak(prevCommitment ‖ currentCommitment)`. This test pins the
/// on-chain derivation to that formula; `AirbenderPlonkProofIntegration.t.sol` separately
/// proves the second stage matches a real proof.
contract AirbenderProofPublicInputTest is Test {
    uint256 internal constant PUBLIC_INPUT_SHIFT = 32;

    ExecutorProvingTest internal executor;

    function setUp() public {
        executor = new ExecutorProvingTest();
    }

    /// The reference derivation, computed independently of the contract.
    function _reference(
        bytes32 _prev,
        bytes32 _curr,
        bytes32 _binaryCommitment
    ) internal pure returns (uint256) {
        bytes32 programOutput = keccak256(abi.encodePacked(_prev, _curr));
        return uint256(keccak256(abi.encodePacked(programOutput, _binaryCommitment))) >> PUBLIC_INPUT_SHIFT;
    }

    function test_derivesTwoLevelPublicInput() public {
        bytes32 prev = keccak256("prev-commitment");
        bytes32 curr = keccak256("curr-commitment");
        bytes32 binaryCommitment = keccak256("airbender-guest-binary");

        executor.setAirbenderBinaryCommitmentForTest(binaryCommitment);

        uint256 got = executor.getAirbenderBatchProofPublicInput(prev, curr);
        assertEq(got, _reference(prev, curr, binaryCommitment), "airbender public input derivation drifted");
    }

    /// The airbender derivation must differ from the Boojum one — otherwise the extra
    /// binary-commitment binding would be a no-op and this whole change would be pointless.
    function test_differsFromBoojumDerivation() public {
        bytes32 prev = keccak256("prev-commitment");
        bytes32 curr = keccak256("curr-commitment");
        executor.setAirbenderBinaryCommitmentForTest(keccak256("airbender-guest-binary"));

        uint256 airbender = executor.getAirbenderBatchProofPublicInput(prev, curr);
        uint256 boojum = executor.getBatchProofPublicInput(prev, curr);
        assertTrue(airbender != boojum, "airbender derivation collapsed to the Boojum one");
    }

    /// A different guest binary must yield a different public input.
    function test_publicInputDependsOnBinaryCommitment() public {
        bytes32 prev = keccak256("prev-commitment");
        bytes32 curr = keccak256("curr-commitment");

        executor.setAirbenderBinaryCommitmentForTest(keccak256("guest-a"));
        uint256 a = executor.getAirbenderBatchProofPublicInput(prev, curr);

        executor.setAirbenderBinaryCommitmentForTest(keccak256("guest-b"));
        uint256 b = executor.getAirbenderBatchProofPublicInput(prev, curr);

        assertTrue(a != b, "public input ignored the binary commitment");
    }

    /// Deriving against an unset (zero) binary commitment must fail loudly rather than
    /// silently producing a wrong public input.
    function test_revertsWhenBinaryCommitmentUnset() public {
        vm.expectRevert(AirbenderBinaryCommitmentNotSet.selector);
        executor.getAirbenderBatchProofPublicInput(keccak256("prev"), keccak256("curr"));
    }
}
