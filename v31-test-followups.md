# v31 Test Coverage Follow-ups

This report was produced while auditing PR #2173 against `origin/draft-v31`.

## Disabled or Skipped Tests

### `system-contracts/test/EvmEmulation.spec.ts` - `Can use BLOBBASEFEE opcode`

- Reason disabled: anvil-zksync currently uses an EVM emulator that does not execute the Cancun `BLOBBASEFEE` opcode in this harness.
- Action needed: update the test runner/emulator dependency, then assert the returned blob base fee through the deployed bytecode path.
- Re-enable criteria: the raw-bytecode contract deploys and calls successfully under the system-contracts runner, and the test asserts the expected blob base fee value.
- Risk while disabled: emulator support drift for `BLOBBASEFEE` can be missed by the system-contracts suite.

### `system-contracts/test/EvmEmulation.spec.ts` - `Can use BLOBHASH opcode`

- Reason disabled: anvil-zksync currently uses an EVM emulator that does not execute the Cancun `BLOBHASH` opcode in this harness.
- Action needed: update the test runner/emulator dependency, then assert the returned blob hash through the deployed bytecode path.
- Re-enable criteria: the raw-bytecode contract deploys and calls successfully under the system-contracts runner, and the test asserts the expected blob hash value.
- Risk while disabled: emulator support drift for `BLOBHASH` can be missed by the system-contracts suite.

### `l1-contracts/package.json` - `UpgradeTestv31_Remote.test_DefaultUpgrade_MainnetFork`

- Reason disabled: the default L1 Foundry command excludes this remote mainnet-fork upgrade test because it requires remote fork/config fixtures that are not available in the standard local test environment.
- Action needed: document or generate the required sanitized fork config files and run this test in a dedicated RPC-backed upgrade validation job.
- Re-enable criteria: a documented command with required environment variables and fixtures can run the v31 remote upgrade path deterministically in CI or a maintainer-controlled validation job.
- Risk while disabled: remote/stage upgrade fixture drift can be missed by the default local suite.

## Deep-dive Decisions for Previously Disabled or Commented Tests

### Restored coverage

- `test_removeChainTypeManager_cannotBeCalledByRandomAddress` (`l1-contracts/test/foundry/l1/unit/concrete/Bridgehub/experimental_bridge.t.sol`): Restored as an active fuzz test because `removeChainTypeManager` still exists and still needs function-specific non-owner coverage.
- `Should require that the next committed batch contains an upgrade tx hash log` (`l1-contracts/test/unit_tests/l2-upgrade.test.spec.ts`): Restored as an active test because a pending upgrade must force the next committed batch to include the expected upgrade transaction hash log.

### `system-contracts/test/Interop.spec.ts`

- Decision: removed.
- Reason: the file was a captured-payload scratch harness. One active test had no real assertions, and the skipped interop test decoded/re-encoded a large fixture without checking stable protocol effects.
- Replacement coverage: active interop coverage exists in `l1-contracts/test/anvil-interop/test/hardhat` and the Foundry `L2Interop*` suites.
- Confidence: 98%; keeping the skipped test would preserve noise rather than actionable coverage.

Removed test cases:

- `Interop tests` (`system-contracts/test/Interop.spec.ts`): Removed because the deleted suite was only a scratch interop harness; maintained interop coverage now lives in the Anvil interop and Foundry `L2Interop*` suites.
- `successfully executed interop 1.5` (`system-contracts/test/Interop.spec.ts`): Removed because the active body had no stable protocol assertions and mainly preserved a commented captured payload.
- `successfully executed interop` (`system-contracts/test/Interop.spec.ts`): Removed because the test was fully commented out, never executed, and only contained an old transaction-construction stub.
- `successfully executed interop 2` (`system-contracts/test/Interop.spec.ts`): Removed because the skipped test only decoded and re-encoded a captured payload without asserting durable interop behavior.

### `l1-contracts/test/foundry/l2/integration/L2NativeTokenVaultBridgeBurnRegressionTest.t.sol`

- Decision: removed.
- Reason: the wrapper only skipped inherited tests in the zkfoundry L2 context. The inherited regression uses Foundry/stdstore and mocked system-contract behavior that is not appropriate for this runner.
- Replacement coverage: the same regression scenarios execute actively in `l1-contracts/test/foundry/l1/integration/l2-tests-in-l1-context/L2NativeTokenVaultBridgeBurnRegressionL1Test.t.sol`.
- Confidence: 98%; deleting the skip-only wrapper is better than carrying permanently skipped tests with duplicate active coverage elsewhere.

Removed test cases:

- `test_regression_bridgeBurnRegularBridgedTokenStillCallsBridgeBurn` (`l1-contracts/test/foundry/l2/integration/L2NativeTokenVaultBridgeBurnRegressionTest.t.sol`): Removed because this zkfoundry wrapper only called `vm.skip(true)`; active coverage is in `L2NativeTokenVaultBridgeBurnRegressionL1Test.t.sol`.
- `test_regression_bridgeBurnBaseTokenAsBridgedTokenCallsBurnMsgValue` (`l1-contracts/test/foundry/l2/integration/L2NativeTokenVaultBridgeBurnRegressionTest.t.sol`): Removed because this zkfoundry wrapper only called `vm.skip(true)`; active coverage is in `L2NativeTokenVaultBridgeBurnRegressionL1Test.t.sol`.
- `testFuzz_regression_bridgeBurnBaseTokenVariousAmounts` (`l1-contracts/test/foundry/l2/integration/L2NativeTokenVaultBridgeBurnRegressionTest.t.sol`): Removed because this zkfoundry wrapper only called `vm.skip(true)`; active coverage is in `L2NativeTokenVaultBridgeBurnRegressionL1Test.t.sol`.

### `l1-contracts/test/unit_tests/l2-upgrade.test.spec.ts` - missing upgrade tx hash log

- Decision: restored as an active test.
- Reason: the behavior is still relevant: a pending upgrade must force the next committed batch to contain the expected upgrade transaction hash log.
- Verification target: the test now builds the next batch without the upgrade hash log and asserts `MissingSystemLogs`.
- Confidence: 98% on the intended assertion and fixture path; local Hardhat execution is blocked because `yarn build` cannot resolve the `forge-std` import from deploy scripts in this checkout, so TypeChain artifacts are not generated.

### `l1-contracts/test/unit_tests/l1_shared_bridge_test.spec.ts` - `Should deposit erc20 token successfully`

- Decision: removed.
- Reason: the commented test referenced stale `l1Weth` setup and duplicated active deposit coverage with weaker assertions.
- Replacement coverage: `Should deposit successfully legacy encoding` in the same file asserts ERC20 balance movement, and the Foundry L1SharedBridge/L1Nullifier suites cover the current bridge flow.
- Confidence: 98%; re-enabling the stale block would add maintenance cost without materially increasing coverage.

Removed test cases:

- `Should deposit erc20 token successfully` (`l1-contracts/test/unit_tests/l1_shared_bridge_test.spec.ts`): Removed because it referenced stale `l1Weth` setup and is covered by active test `Should deposit successfully legacy encoding` in the same file.

### `l1-contracts/test/unit_tests/executor_proof.spec.ts` - commented rollup/validium fixed vectors

- Decision: removed stale commented vectors and kept an active proof-public-input regression assertion.
- Reason: the disabled blocks called historical helper APIs such as `processL2Logs` and `createBatchCommitment` that are no longer exposed by `ExecutorProvingTest`.
- Replacement coverage: current commitment/log behavior is covered by `l1-contracts/test/foundry/l1/unit/concrete/BatchProcessing/ExecutorProof.t.sol`; this TypeScript suite now asserts the exposed `getBatchProofPublicInput` helper directly.
- Confidence: 98%; restoring the commented vectors would require reintroducing obsolete harness APIs.

Removed test cases:

- `Test hashes (Rollup)` (`l1-contracts/test/unit_tests/executor_proof.spec.ts`): Replaced by active test `computes the expected proof public input from adjacent batch commitments`; the old executable body only checked a helper transaction receipt, while the commented commitment assertions referenced obsolete `ExecutorProvingTest` APIs.
- `Test hashes (Validium)` (`l1-contracts/test/unit_tests/executor_proof.spec.ts`): Removed because it was fully commented out and referenced obsolete `ExecutorProvingTest.processL2Logs`, `createBatchCommitment`, and old `getBatchProofPublicInput` call shape.

## Removed Commented-out Test Blocks

The v31 diff contained commented-out Solidity `function test...` blocks that were removed rather than left disabled:

- `test_removeChainTypeManager` (`l1-contracts/test/foundry/l1/unit/concrete/Bridgehub/experimental_bridge.t.sol`): Removed because success and not-registered behavior are covered by active tests `test_removeChainTypeManagerSuccess` and `test_RevertWhen_removeChainTypeManagerNotRegistered` in `BridgehubBase_Extended.t.sol`.
- `test_safeTransferFundsFromSharedBridge_Erc` (`l1-contracts/test/foundry/l1/unit/concrete/Bridges/L1SharedBridge/L1SharedBridgeBase.t.sol`): Removed because `transferFundsFromSharedBridge` and `updateChainBalancesFromSharedBridge` no longer exist; current NTV/L1Nullifier balance movement is covered by active bridge and native-token-vault suites.
- `test_safeTransferFundsFromSharedBridge_Eth` (`l1-contracts/test/foundry/l1/unit/concrete/Bridges/L1SharedBridge/L1SharedBridgeBase.t.sol`): Removed because the old shared-bridge pull API no longer exists; ETH migration/failure paths are covered through current L1Nullifier and NTV tests.
- `test_transferFundsToSharedBridge_Eth_0_AmountTransferred` (`l1-contracts/test/foundry/l1/unit/concrete/Bridges/L1SharedBridge/L1SharedBridgeFails.t.sol`): Removed because the old `transferFundsFromSharedBridge` API is gone; zero-amount failed-deposit behavior is covered by active `test_claimFailedDeposit_amountZero`.
- `test_transferFundsToSharedBridge_Erc_0_AmountTransferred` (`l1-contracts/test/foundry/l1/unit/concrete/Bridges/L1SharedBridge/L1SharedBridgeFails.t.sol`): Removed because the old `transferFundsFromSharedBridge` API and `ZeroAmountToTransfer` error are gone.
- `test_transferFundsToSharedBridge_Erc_WrongAmountTransferred` (`l1-contracts/test/foundry/l1/unit/concrete/Bridges/L1SharedBridge/L1SharedBridgeFails.t.sol`): Removed because the old `transferFundsFromSharedBridge` API and `WrongAmountTransferred` error are gone.
