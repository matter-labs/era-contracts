// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {ZKsyncOSDualVerifier} from "contracts/state-transition/verifiers/ZKsyncOSDualVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT, PUBLIC_INPUT_SHIFT} from "contracts/common/Config.sol";

contract ExecutorZKsyncOSPublicInputHarness is ExecutorFacet {
    constructor() ExecutorFacet(block.chainid) {}

    function util_setZKsyncOSChainConfig(uint256 _chainId, uint64 _maxTxGasLimit) external {
        s.chainId = _chainId;
        s.zksyncOSMaxTxGasLimit = _maxTxGasLimit;
    }

    function getBatchProofPublicInputZKsyncOS(
        bytes32 _prevBatchStateCommitment,
        bytes32 _currentBatchStateCommitment,
        bytes32 _currentBatchCommitment
    ) external view returns (uint256) {
        return
            _getBatchProofPublicInputZKsyncOS(
                _prevBatchStateCommitment,
                _currentBatchStateCommitment,
                _currentBatchCommitment
            );
    }
}

/// @notice Pins the ZKsync OS batch proof public input encoding to golden vectors shared with the
/// ZKsync OS implementation (`public_input.rs` / `chain_config.rs` in the zksync-os repository):
/// changing the encoding on either side must update both.
/// @dev `_getBatchProofPublicInputZKsyncOS` returns the hash UNTRUNCATED; `PUBLIC_INPUT_SHIFT` is
/// applied once by `computeZKsyncOSHash` after the multi-batch fold.
/// @dev The public input is `keccak256(state_before, state_after, chain_config_hash, batch_output)`,
/// where `chain_config_hash = keccak256(chain_id, fri_proof_verification_enabled, max_tx_gas_limit)`
/// as three 32-byte big-endian words. FRI proof verification is always disabled from the settlement
/// layer, so its word is always zero.
contract ZKsyncOSPublicInputTest is Test {
    ExecutorZKsyncOSPublicInputHarness internal executor;
    ZKsyncOSDualVerifier internal verifier;

    /// @dev `BatchOutput::hash()` golden vector from zksync-os (`batch_output_hash_golden_vector`).
    bytes32 internal constant BATCH_OUTPUT_HASH_GOLDEN =
        0x1c24f398aa0701f9348912ecca748ba93bfb84bfe4f283c16514311419f4f658;

    /// @dev `BatchPublicInput::hash()` for zero state commitments, `chain_config_hash` of chain id 37
    /// with FRI proof verification disabled and the default max tx gas limit (matching zksync-os
    /// `ChainConfig::new(37, false, DEFAULT_MAX_TX_GAS_LIMIT).hash()`), and `BATCH_OUTPUT_HASH_GOLDEN`.
    bytes32 internal constant PUBLIC_INPUT_HASH_GOLDEN =
        0xa6ed40b112cb51e6d0d0defe86e29ae9b7b8df601160de98e5e6ff29036ff440;

    uint256 internal constant GOLDEN_CHAIN_ID = 37;

    function setUp() public {
        executor = new ExecutorZKsyncOSPublicInputHarness();
        // only `computeZKsyncOSHash` is exercised here; the sub-verifiers are never called
        verifier = new ZKsyncOSDualVerifier(IVerifierV2(address(1)), IVerifier(address(2)), address(this));
        executor.util_setZKsyncOSChainConfig(GOLDEN_CHAIN_ID, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT);
    }

    function test_publicInput_matchesZKsyncOSGoldenVector() public view {
        uint256 publicInput = executor.getBatchProofPublicInputZKsyncOS(
            bytes32(0),
            bytes32(0),
            BATCH_OUTPUT_HASH_GOLDEN
        );

        assertEq(publicInput, uint256(PUBLIC_INPUT_HASH_GOLDEN));
    }

    function test_publicInput_unsetMaxTxGasLimitFallsBackToDefault() public {
        // `0` in storage (chains deployed before the field existed) must hash like the default.
        executor.util_setZKsyncOSChainConfig(GOLDEN_CHAIN_ID, 0);

        uint256 publicInput = executor.getBatchProofPublicInputZKsyncOS(
            bytes32(0),
            bytes32(0),
            BATCH_OUTPUT_HASH_GOLDEN
        );

        assertEq(publicInput, uint256(PUBLIC_INPUT_HASH_GOLDEN));
    }

    function test_publicInput_commitsToChainConfig() public {
        uint256 base = executor.getBatchProofPublicInputZKsyncOS(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN);

        executor.util_setZKsyncOSChainConfig(GOLDEN_CHAIN_ID, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT + 1);
        uint256 raisedGasLimit = executor.getBatchProofPublicInputZKsyncOS(
            bytes32(0),
            bytes32(0),
            BATCH_OUTPUT_HASH_GOLDEN
        );

        executor.util_setZKsyncOSChainConfig(GOLDEN_CHAIN_ID + 1, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT);
        uint256 differentChainId = executor.getBatchProofPublicInputZKsyncOS(
            bytes32(0),
            bytes32(0),
            BATCH_OUTPUT_HASH_GOLDEN
        );

        assertNotEq(base, raisedGasLimit);
        assertNotEq(base, differentChainId);
    }

    /// @notice The prover hashes the concatenation of all per-batch hashes once. A rolling
    /// fold coincides for N <= 2, so N == 3 is the smallest case that pins the rule.
    function test_publicInput_multiBatchFoldHashesConcatenationOnce() public view {
        uint256[] memory inputs = new uint256[](3);
        inputs[0] = executor.getBatchProofPublicInputZKsyncOS(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN);
        inputs[1] = executor.getBatchProofPublicInputZKsyncOS(
            bytes32(0),
            bytes32(uint256(1)),
            BATCH_OUTPUT_HASH_GOLDEN
        );
        inputs[2] = executor.getBatchProofPublicInputZKsyncOS(
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            BATCH_OUTPUT_HASH_GOLDEN
        );

        uint256 flat = uint256(keccak256(abi.encodePacked(inputs))) >> PUBLIC_INPUT_SHIFT;
        uint256 rolling = uint256(
            keccak256(abi.encodePacked(uint256(keccak256(abi.encodePacked(inputs[0], inputs[1]))), inputs[2]))
        ) >> PUBLIC_INPUT_SHIFT;

        assertEq(verifier.computeZKsyncOSHash(0, inputs), flat);
        assertNotEq(flat, rolling);
    }

    /// @notice A single-batch range is the bare hash, with no keccak over it.
    function test_publicInput_singleBatchIsNotHashed() public view {
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = executor.getBatchProofPublicInputZKsyncOS(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN);

        assertEq(verifier.computeZKsyncOSHash(0, inputs), inputs[0] >> PUBLIC_INPUT_SHIFT);
    }
}
