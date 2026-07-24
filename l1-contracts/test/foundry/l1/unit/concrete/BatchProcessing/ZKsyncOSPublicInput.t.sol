// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT, PUBLIC_INPUT_SHIFT} from "contracts/common/Config.sol";

contract ExecutorZKsyncOSPublicInputHarness is ExecutorFacet {
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
/// @dev The public input is `keccak256(state_before, state_after, chain_config_hash, batch_output)`,
/// where `chain_config_hash = keccak256(chain_id, fri_proof_verification_enabled, max_tx_gas_limit,
/// l2_da_mode)` as four 32-byte big-endian words. FRI proof verification is always disabled from the
/// settlement layer, so its word is always zero; `l2_da_mode` is `FULL_PUBDATA` (0) / `LOGS_ONLY` (1).
contract ZKsyncOSPublicInputTest is Test {
    ExecutorZKsyncOSPublicInputHarness internal executor;

    /// @dev `BatchOutput::hash()` golden vector from zksync-os (`batch_output_hash_golden_vector`).
    bytes32 internal constant BATCH_OUTPUT_HASH_GOLDEN =
        0x1c24f398aa0701f9348912ecca748ba93bfb84bfe4f283c16514311419f4f658;

    /// @dev `BatchPublicInput::hash()` for zero state commitments, `chain_config_hash` of chain id 37
    /// with FRI proof verification disabled, the default max tx gas limit and DA mode `FULL_PUBDATA` (matching
    /// zksync-os `ChainConfig::new(37, false, DEFAULT_MAX_TX_GAS_LIMIT).hash()`, which defaults to
    /// `DAMode::Rollup`), and `BATCH_OUTPUT_HASH_GOLDEN`. Shared with zksync-os
    /// `batch_public_input_hash_golden_vector`.
    bytes32 internal constant PUBLIC_INPUT_HASH_GOLDEN =
        0x0a5143e28ed3fc1728ef4d96319f2306bb5a81bfccd908154e44029988ef9e7c;

    uint256 internal constant GOLDEN_CHAIN_ID = 37;

    function setUp() public {
        executor = new ExecutorZKsyncOSPublicInputHarness();
        executor.util_setZKsyncOSChainConfig(GOLDEN_CHAIN_ID, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT);
    }

    function test_publicInput_matchesZKsyncOSGoldenVector() public view {
        uint256 publicInput = executor.getBatchProofPublicInputZKsyncOS(
            bytes32(0),
            bytes32(0),
            BATCH_OUTPUT_HASH_GOLDEN
        );

        assertEq(publicInput, uint256(PUBLIC_INPUT_HASH_GOLDEN) >> PUBLIC_INPUT_SHIFT);
    }

    function test_publicInput_unsetMaxTxGasLimitFallsBackToDefault() public {
        // `0` in storage (chains deployed before the field existed) must hash like the default.
        executor.util_setZKsyncOSChainConfig(GOLDEN_CHAIN_ID, 0);

        uint256 publicInput = executor.getBatchProofPublicInputZKsyncOS(
            bytes32(0),
            bytes32(0),
            BATCH_OUTPUT_HASH_GOLDEN
        );

        assertEq(publicInput, uint256(PUBLIC_INPUT_HASH_GOLDEN) >> PUBLIC_INPUT_SHIFT);
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
}
