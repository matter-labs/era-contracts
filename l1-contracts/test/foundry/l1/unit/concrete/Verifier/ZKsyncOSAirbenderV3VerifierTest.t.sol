// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ZKsyncOSVerifier} from "contracts/state-transition/verifiers/ZKsyncOSVerifier.sol";
import {ZKsyncOSAirbenderV3Verifier} from "contracts/state-transition/verifiers/ZKsyncOSAirbenderV3Verifier.sol";
import {AirbenderV3VerificationRegistry} from "contracts/state-transition/verifiers/AirbenderV3VerificationRegistry.sol";
import {InvalidProofFormat} from "contracts/common/L1ContractErrors.sol";
import {ZKSYNC_OS_PLONK_VERIFICATION_TYPE} from "contracts/common/Config.sol";

/// @dev A registry that records marks, like zksync-airbender's `TestRegistry`.
contract RecordingRegistry {
    uint256 public count;

    function markVerified(bytes32, bytes32) external {
        count += 1;
    }
}

/// @notice Real-proof anchor for the Airbender v3 (GKR/WHIR) verifier stack.
/// @dev Fixtures (`airbender-v3/`) come from zksync-airbender `av_gkr_compiler` 84e2c89d6, pessimistic
///      conjecture mode: `single_tx_calldata.hex` and `verified_mark.hex` are the committed
///      `verifier_evm/debug_data` of the canonical L1 bundle, and `gkr_whir_verifier_runtime.hex`
///      is the deployed code of that mode's `merged/src/GkrWhirVerifier.sol` (runtime plus the
///      embedded setup). The runtime exceeds EIP-170, so it is etched rather than created. The
///      verifier pins registry 0x78D5…4E91; the stateless registry is etched there.
contract ZKsyncOSAirbenderV3VerifierTest is Test {
    string internal constant FIXTURES = "./test/foundry/l1/integration/fixtures/airbender-v3/";
    address internal constant PINNED_REGISTRY = 0x78D549f2A140923c517c23b008DFfE979B3c4E91;

    address internal gkrWhirVerifier;
    bytes internal proofBytes;
    bytes32 internal publicInput;
    bytes32 internal chainHash;
    ZKsyncOSAirbenderV3Verifier internal adapter;
    ZKsyncOSVerifier internal verifier;
    bool internal fixturesAvailable;

    modifier requiresFixtures() {
        vm.skip(!fixturesAvailable);
        _;
    }

    function setUp() public {
        string memory runtimePath = string.concat(FIXTURES, "gkr_whir_verifier_runtime.hex");
        if (!vm.exists(runtimePath)) {
            return;
        }
        fixturesAvailable = true;
        gkrWhirVerifier = makeAddr("gkrWhirVerifier");
        vm.etch(gkrWhirVerifier, _readHex(runtimePath));
        vm.etch(PINNED_REGISTRY, type(AirbenderV3VerificationRegistry).runtimeCode);

        proofBytes = _readHex(string.concat(FIXTURES, "single_tx_calldata.hex"));
        bytes memory mark = _readHex(string.concat(FIXTURES, "verified_mark.hex"));
        assertEq(mark.length, 64);
        assembly {
            sstore(publicInput.slot, mload(add(mark, 0x20)))
            sstore(chainHash.slot, mload(add(mark, 0x40)))
        }

        adapter = new ZKsyncOSAirbenderV3Verifier(gkrWhirVerifier, [bytes32(uint256(1)), chainHash, bytes32(uint256(2))]);
        verifier = new ZKsyncOSVerifier(IVerifier(address(adapter)));
    }

    function test_verifiesTheFixtureProof() public requiresFixtures {
        uint256[] memory publicInputs = _publicInputs(publicInput);
        uint256[] memory proof = _envelope(proofBytes);
        uint256 gasBefore = gasleft();
        bool ok = verifier.verify(publicInputs, proof);
        emit log_named_uint("ZKsyncOSVerifier.verify gas (execution only)", gasBefore - gasleft());
        assertTrue(ok);
    }

    function test_rawVerifierReportsTheFixtureStatement() public requiresFixtures {
        bytes memory proof = proofBytes;
        uint256 gasBefore = gasleft();
        (bool success, bytes memory result) = gkrWhirVerifier.staticcall(proof);
        emit log_named_uint("GkrWhirVerifier gas (execution only)", gasBefore - gasleft());
        assertTrue(success);
        (bytes32 reportedPublicInput, bytes32 reportedChainHash) = abi.decode(result, (bytes32, bytes32));
        assertEq(reportedPublicInput, publicInput);
        assertEq(reportedChainHash, chainHash);
    }

    function test_rejectsAnotherBatchCommitment() public requiresFixtures {
        bytes32 other = bytes32(uint256(publicInput) ^ (uint256(1) << 100));
        assertFalse(verifier.verify(_publicInputs(other), _envelope(proofBytes)));
    }

    function test_rejectsAnUnpinnedChainHash() public requiresFixtures {
        ZKsyncOSAirbenderV3Verifier otherProgram = new ZKsyncOSAirbenderV3Verifier(
            gkrWhirVerifier,
            [bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3))]
        );
        ZKsyncOSVerifier otherVerifier = new ZKsyncOSVerifier(IVerifier(address(otherProgram)));
        assertFalse(otherVerifier.verify(_publicInputs(publicInput), _envelope(proofBytes)));
    }

    function test_rejectsATamperedProof() public requiresFixtures {
        bytes memory tampered = bytes.concat(proofBytes);
        tampered[tampered.length / 2] ^= 0x01;
        assertFalse(verifier.verify(_publicInputs(publicInput), _envelope(tampered)));
    }

    function test_rejectsMultiBatchRanges() public requiresFixtures {
        uint256[] memory publicInputs = new uint256[](2);
        publicInputs[0] = uint256(publicInput);
        publicInputs[1] = uint256(publicInput);
        assertFalse(verifier.verify(publicInputs, _envelope(proofBytes)));
    }

    function test_rejectsAMislabeledLength() public requiresFixtures {
        uint256[] memory proof = _envelope(proofBytes);
        proof[2] += 32;
        vm.expectRevert(InvalidProofFormat.selector);
        verifier.verify(_publicInputs(publicInput), proof);
    }

    /// The executor verifies through STATICCALL: with a registry that writes state the generated
    /// verifier's mark reverts, so even a valid proof fails, which is why the stateless registry is
    /// required.
    function test_recordingRegistryFailsVerificationInAStaticCall() public requiresFixtures {
        vm.etch(PINNED_REGISTRY, type(RecordingRegistry).runtimeCode);
        uint256[] memory publicInputs = _publicInputs(publicInput);
        uint256[] memory proof = _envelope(proofBytes);
        (bool success, bytes memory result) = address(verifier).staticcall{gas: 30_000_000}(
            abi.encodeCall(ZKsyncOSVerifier.verify, (publicInputs, proof))
        );
        assertTrue(success);
        assertFalse(abi.decode(result, (bool)));
    }

    function _publicInputs(bytes32 _commitment) internal pure returns (uint256[] memory publicInputs) {
        publicInputs = new uint256[](1);
        publicInputs[0] = uint256(_commitment);
    }

    /// @dev `[type, carriedHash, byteLength, data words...]`, as the server encodes the proof.
    function _envelope(bytes memory _proofBytes) internal pure returns (uint256[] memory proof) {
        uint256 words = (_proofBytes.length + 31) / 32;
        proof = new uint256[](3 + words);
        proof[0] = ZKSYNC_OS_PLONK_VERIFICATION_TYPE;
        proof[1] = 0;
        proof[2] = _proofBytes.length;
        bytes memory padded = bytes.concat(_proofBytes, new bytes(words * 32 - _proofBytes.length));
        for (uint256 i = 0; i < words; ++i) {
            uint256 word;
            assembly {
                word := mload(add(add(padded, 0x20), mul(i, 0x20)))
            }
            proof[3 + i] = word;
        }
    }

    function _readHex(string memory _path) internal view returns (bytes memory) {
        return vm.parseBytes(string.concat("0x", vm.trim(vm.readFile(_path))));
    }
}
