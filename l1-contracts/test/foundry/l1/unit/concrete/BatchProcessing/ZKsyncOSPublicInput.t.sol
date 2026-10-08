// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    GOLDEN_CHAIN_ID,
    BATCH_OUTPUT_HASH_GOLDEN,
    PUBLIC_INPUT_HASH_GOLDEN,
    PUBLIC_INPUT_HASH_GOLDEN_FILTERING_ONLY,
    PUBLIC_INPUT_HASH_GOLDEN_LARGE_CONTRACTS_ONLY,
    PUBLIC_INPUT_HASH_GOLDEN_BOTH_FLAGS
} from "foundry-test/TestConstants.sol";

import {TestCommitter} from "contracts/dev-contracts/test/TestCommitter.sol";
import {IInteropFeeManager} from "contracts/core/interop-fee/IInteropFeeManager.sol";
import {ZKsyncOSVerifier} from "contracts/state-transition/verifiers/ZKsyncOSVerifier.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT, PUBLIC_INPUT_SHIFT} from "contracts/common/Config.sol";

contract CommitterZKsyncOSPublicInputHarness is TestCommitter {
    // Only the public-input hashing is exercised, which never charges the interop fee.
    constructor() TestCommitter(IInteropFeeManager(address(0))) {}

    function util_setZKsyncOSChainConfig(uint256 _chainId, uint64 _maxTxGasLimit) external {
        s.chainId = _chainId;
        s.zksyncOSMaxTxGasLimit = _maxTxGasLimit;
    }

    function util_setZKsyncOSChainConfigFlags(bool _filteringEnabled, bool _largeContractsEnabled) external {
        s.zksyncOSL1TxFilteringEnabled = _filteringEnabled;
        s.zksyncOSLargeContractsEnabled = _largeContractsEnabled;
    }

    function getBatchProofPublicInput(
        bytes32 _prevBatchStateCommitment,
        bytes32 _currentBatchStateCommitment,
        bytes32 _batchOutputHash
    ) external view returns (uint256) {
        return
            uint256(
                _getBatchCommitment(
                    _prevBatchStateCommitment,
                    _currentBatchStateCommitment,
                    _getZKsyncOSChainConfigHash(),
                    _batchOutputHash
                )
            );
    }
}

/// @notice Pins the batch public input for the combined ZKsync OS chain configuration.
/// @dev See {protocol-docs/chain-config.md#proof-commitment}.
contract ZKsyncOSPublicInputTest is Test {
    CommitterZKsyncOSPublicInputHarness internal committer;
    ZKsyncOSVerifier internal verifier;

    function setUp() public {
        committer = new CommitterZKsyncOSPublicInputHarness();
        // Only `computeZKsyncOSHash` is exercised here; the wrapped verifier is never called.
        verifier = new ZKsyncOSVerifier(IVerifier(address(1)));
        committer.util_setZKsyncOSChainConfig(GOLDEN_CHAIN_ID, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT);
    }

    function test_publicInput_matchesZKsyncOSGoldenVector() public view {
        uint256 publicInput = committer.getBatchProofPublicInput(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN);

        assertEq(publicInput, uint256(PUBLIC_INPUT_HASH_GOLDEN));
    }

    function test_publicInput_matchesZKsyncOSFlagGoldenVectors() public {
        committer.util_setZKsyncOSChainConfigFlags(true, false);
        assertEq(
            committer.getBatchProofPublicInput(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN),
            uint256(PUBLIC_INPUT_HASH_GOLDEN_FILTERING_ONLY)
        );

        committer.util_setZKsyncOSChainConfigFlags(false, true);
        assertEq(
            committer.getBatchProofPublicInput(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN),
            uint256(PUBLIC_INPUT_HASH_GOLDEN_LARGE_CONTRACTS_ONLY)
        );

        committer.util_setZKsyncOSChainConfigFlags(true, true);
        assertEq(
            committer.getBatchProofPublicInput(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN),
            uint256(PUBLIC_INPUT_HASH_GOLDEN_BOTH_FLAGS)
        );
    }

    function test_publicInput_unsetMaxTxGasLimitFallsBackToDefault() public {
        // `0` in storage (chains deployed before the field existed) must hash like the default.
        committer.util_setZKsyncOSChainConfig(GOLDEN_CHAIN_ID, 0);

        uint256 publicInput = committer.getBatchProofPublicInput(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN);

        assertEq(publicInput, uint256(PUBLIC_INPUT_HASH_GOLDEN));
    }

    function test_publicInput_commitsToChainConfig() public {
        uint256 base = committer.getBatchProofPublicInput(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN);

        committer.util_setZKsyncOSChainConfig(GOLDEN_CHAIN_ID, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT + 1);
        uint256 raisedGasLimit = committer.getBatchProofPublicInput(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN);

        committer.util_setZKsyncOSChainConfig(GOLDEN_CHAIN_ID + 1, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT);
        uint256 differentChainId = committer.getBatchProofPublicInput(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN);

        assertNotEq(base, raisedGasLimit);
        assertNotEq(base, differentChainId);
    }

    /// @notice The prover hashes the concatenation of all per-batch hashes once. A rolling
    /// fold coincides for N <= 2, so N == 3 is the smallest case that pins the rule.
    function test_publicInput_multiBatchFoldHashesConcatenationOnce() public view {
        uint256[] memory inputs = new uint256[](3);
        inputs[0] = committer.getBatchProofPublicInput(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN);
        inputs[1] = committer.getBatchProofPublicInput(bytes32(0), bytes32(uint256(1)), BATCH_OUTPUT_HASH_GOLDEN);
        inputs[2] = committer.getBatchProofPublicInput(
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
        inputs[0] = committer.getBatchProofPublicInput(bytes32(0), bytes32(0), BATCH_OUTPUT_HASH_GOLDEN);

        assertEq(verifier.computeZKsyncOSHash(0, inputs), inputs[0] >> PUBLIC_INPUT_SHIFT);
    }
}
