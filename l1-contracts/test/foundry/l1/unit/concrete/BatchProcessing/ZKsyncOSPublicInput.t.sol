// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {ZKsyncOSChainConfig} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT, PUBLIC_INPUT_SHIFT} from "contracts/common/Config.sol";

contract ExecutorZKsyncOSPublicInputHarness is ExecutorFacet {
    constructor() ExecutorFacet(block.chainid) {}

    function util_setZKsyncOSChainConfig(uint256 _chainId, bool _friEnabled, uint64 _maxTxGasLimit) external {
        s.chainId = _chainId;
        s.zksyncOSChainConfig = ZKsyncOSChainConfig({
            friProofVerificationEnabled: _friEnabled,
            maxTxGasLimit: _maxTxGasLimit
        });
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

/// @notice Pins the ZKsync OS batch proof public input encoding to golden vectors shared with
/// the ZKsync OS implementation (`public_input.rs` tests in the zksync-os repository):
/// changing the encoding on either side must update both.
contract ZKsyncOSPublicInputTest is Test {
    ExecutorZKsyncOSPublicInputHarness internal executor;

    /// @dev `BatchOutput::hash()` golden vector from zksync-os (`batch_output_hash_golden_vector`).
    bytes32 internal constant BATCH_OUTPUT_HASH_GOLDEN =
        0x1c24f398aa0701f9348912ecca748ba93bfb84bfe4f283c16514311419f4f658;

    /// @dev `BatchPublicInput::hash()` golden vector from zksync-os
    /// (`batch_public_input_hash_golden_vector`): zero state commitments, chain id 37,
    /// FRI proof verification disabled, default max tx gas limit, and `BATCH_OUTPUT_HASH_GOLDEN`.
    bytes32 internal constant PUBLIC_INPUT_HASH_GOLDEN =
        0x0ebb93a08ee4d25f85259327b052ef970af4871f066c26af4063920b6be80123;

    uint256 internal constant GOLDEN_CHAIN_ID = 37;

    function setUp() public {
        executor = new ExecutorZKsyncOSPublicInputHarness();
        executor.util_setZKsyncOSChainConfig(GOLDEN_CHAIN_ID, false, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT);
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
        executor.util_setZKsyncOSChainConfig(GOLDEN_CHAIN_ID, false, 0);

        uint256 publicInput = executor.getBatchProofPublicInputZKsyncOS(
            bytes32(0),
            bytes32(0),
            BATCH_OUTPUT_HASH_GOLDEN
        );

        assertEq(publicInput, uint256(PUBLIC_INPUT_HASH_GOLDEN) >> PUBLIC_INPUT_SHIFT);
    }

    function test_publicInput_commitsToChainConfig() public {
        uint256 base = executor.getBatchProofPublicInputZKsyncOS(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN);

        executor.util_setZKsyncOSChainConfig(GOLDEN_CHAIN_ID, true, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT);
        uint256 friEnabled = executor.getBatchProofPublicInputZKsyncOS(
            bytes32(0),
            bytes32(0),
            BATCH_OUTPUT_HASH_GOLDEN
        );

        executor.util_setZKsyncOSChainConfig(GOLDEN_CHAIN_ID, false, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT + 1);
        uint256 raisedGasLimit = executor.getBatchProofPublicInputZKsyncOS(
            bytes32(0),
            bytes32(0),
            BATCH_OUTPUT_HASH_GOLDEN
        );

        executor.util_setZKsyncOSChainConfig(GOLDEN_CHAIN_ID + 1, false, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT);
        uint256 differentChainId = executor.getBatchProofPublicInputZKsyncOS(
            bytes32(0),
            bytes32(0),
            BATCH_OUTPUT_HASH_GOLDEN
        );

        assertNotEq(base, friEnabled);
        assertNotEq(base, raisedGasLimit);
        assertNotEq(base, differentChainId);
    }
}
