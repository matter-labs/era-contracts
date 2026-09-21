// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {ZKsyncOSVerifier} from "contracts/state-transition/verifiers/ZKsyncOSVerifier.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT, PUBLIC_INPUT_SHIFT} from "contracts/common/Config.sol";

contract ExecutorZKsyncOSPublicInputHarness is ExecutorFacet {
    function util_setZKsyncOSChainConfig(uint256 _chainId, uint64 _maxTxGasLimit) external {
        s.chainId = _chainId;
        s.zksyncOSMaxTxGasLimit = _maxTxGasLimit;
    }

    function getBatchProofPublicInput(
        bytes32 _prevBatchStateCommitment,
        bytes32 _currentBatchStateCommitment,
        bytes32 _currentBatchCommitment
    ) external view returns (uint256) {
        return
            _getBatchProofPublicInput(_prevBatchStateCommitment, _currentBatchStateCommitment, _currentBatchCommitment);
    }
}

/// @notice Pins batch public inputs to the golden vectors in ZKsync OS's `public_input.rs`.
/// @dev See {protocol-docs/chain-config.md#proof-commitment}.
contract ZKsyncOSPublicInputTest is Test {
    ExecutorZKsyncOSPublicInputHarness internal executor;
    ZKsyncOSVerifier internal verifier;

    /// @dev `BatchOutput::hash()` golden vector from zksync-os (`batch_output_hash_golden_vector`).
    bytes32 internal constant BATCH_OUTPUT_HASH_GOLDEN =
        0x1c24f398aa0701f9348912ecca748ba93bfb84bfe4f283c16514311419f4f658;

    /// @dev Shared with ZKsync OS's `batch_public_input_hash_golden_vector` (filtering disabled).
    bytes32 internal constant PUBLIC_INPUT_HASH_GOLDEN =
        0xdf099e94dc933cb1e302ad66826a922df76c4759542b07311d99b0c5e9eb436d;

    uint256 internal constant GOLDEN_CHAIN_ID = 37;

    function setUp() public {
        executor = new ExecutorZKsyncOSPublicInputHarness();
        // Only `computeZKsyncOSHash` is exercised here; the wrapped verifier is never called.
        verifier = new ZKsyncOSVerifier(IVerifier(address(1)));
        executor.util_setZKsyncOSChainConfig(GOLDEN_CHAIN_ID, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT);
    }

    function test_publicInput_matchesZKsyncOSGoldenVector() public view {
        uint256 publicInput = executor.getBatchProofPublicInput(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN);

        assertEq(publicInput, uint256(PUBLIC_INPUT_HASH_GOLDEN));
    }

    function test_publicInput_unsetMaxTxGasLimitFallsBackToDefault() public {
        // `0` in storage (chains deployed before the field existed) must hash like the default.
        executor.util_setZKsyncOSChainConfig(GOLDEN_CHAIN_ID, 0);

        uint256 publicInput = executor.getBatchProofPublicInput(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN);

        assertEq(publicInput, uint256(PUBLIC_INPUT_HASH_GOLDEN));
    }

    function test_publicInput_commitsToChainConfig() public {
        uint256 base = executor.getBatchProofPublicInput(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN);

        executor.util_setZKsyncOSChainConfig(GOLDEN_CHAIN_ID, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT + 1);
        uint256 raisedGasLimit = executor.getBatchProofPublicInput(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN);

        executor.util_setZKsyncOSChainConfig(GOLDEN_CHAIN_ID + 1, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT);
        uint256 differentChainId = executor.getBatchProofPublicInput(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN);

        assertNotEq(base, raisedGasLimit);
        assertNotEq(base, differentChainId);
    }

    /// @notice The prover hashes the concatenation of all per-batch hashes once. A rolling
    /// fold coincides for N <= 2, so N == 3 is the smallest case that pins the rule.
    function test_publicInput_multiBatchFoldHashesConcatenationOnce() public view {
        uint256[] memory inputs = new uint256[](3);
        inputs[0] = executor.getBatchProofPublicInput(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN);
        inputs[1] = executor.getBatchProofPublicInput(bytes32(0), bytes32(uint256(1)), BATCH_OUTPUT_HASH_GOLDEN);
        inputs[2] = executor.getBatchProofPublicInput(
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
        inputs[0] = executor.getBatchProofPublicInput(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN);

        assertEq(verifier.computeZKsyncOSHash(0, inputs), inputs[0] >> PUBLIC_INPUT_SHIFT);
    }
}
