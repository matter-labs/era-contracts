# v31 Test Coverage Follow-ups

This report was produced while auditing `draft-v31` against `origin/main`.

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

### `system-contracts/test/Interop.spec.ts`

- Decision: removed.
- Reason: the file was a captured-payload scratch harness. One active test had no real assertions, and the skipped interop test decoded/re-encoded a large fixture without checking stable protocol effects.
- Replacement coverage: active interop coverage exists in `l1-contracts/test/anvil-interop/test/hardhat` and the Foundry `L2Interop*` suites.
- Confidence: 98%; keeping the skipped test would preserve noise rather than actionable coverage.

### `l1-contracts/test/foundry/l2/integration/L2NativeTokenVaultBridgeBurnRegressionTest.t.sol`

- Decision: removed.
- Reason: the wrapper only skipped inherited tests in the zkfoundry L2 context. The inherited regression uses Foundry/stdstore and mocked system-contract behavior that is not appropriate for this runner.
- Replacement coverage: the same regression scenarios execute actively in `l1-contracts/test/foundry/l1/integration/l2-tests-in-l1-context/L2NativeTokenVaultBridgeBurnRegressionL1Test.t.sol`.
- Confidence: 98%; deleting the skip-only wrapper is better than carrying permanently skipped tests with duplicate active coverage elsewhere.

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

### `l1-contracts/test/unit_tests/executor_proof.spec.ts` - commented rollup/validium fixed vectors

- Decision: removed stale commented vectors and kept an active proof-public-input regression assertion.
- Reason: the disabled blocks called historical helper APIs such as `processL2Logs` and `createBatchCommitment` that are no longer exposed by `ExecutorProvingTest`.
- Replacement coverage: current commitment/log behavior is covered by `l1-contracts/test/foundry/l1/unit/concrete/BatchProcessing/ExecutorProof.t.sol`; this TypeScript suite now asserts the exposed `getBatchProofPublicInput` helper directly.
- Confidence: 98%; restoring the commented vectors would require reintroducing obsolete harness APIs.

## Removed Commented-out Test Blocks

The v31 diff contained commented-out Solidity `function test...` blocks in:

- `l1-contracts/test/foundry/l1/unit/concrete/Bridgehub/experimental_bridge.t.sol`
- `l1-contracts/test/foundry/l1/unit/concrete/Bridges/L1SharedBridge/L1SharedBridgeBase.t.sol`
- `l1-contracts/test/foundry/l1/unit/concrete/Bridges/L1SharedBridge/L1SharedBridgeFails.t.sol`

These blocks were removed rather than left disabled. The covered behavior is represented by active tests in the Bridgehub, L1SharedBridge, L1Nullifier, and native-token-vault Foundry suites.

## New Externally Available v31 Surface Coverage

The audit used `git diff origin/main...HEAD -- '*.sol'`, signature scanning for `public`/`external`/`receive`/`fallback`, and manual mapping to active tests. The v31 diff includes many contract moves and interface reshapes, so the practical coverage inventory groups the externally callable surface by changed runtime component.

| v31 surface                                                                                            | External/public behavior introduced or changed                                                               | Coverage evidence                                                                                                                                                    |
| ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `da-contracts/contracts/BlobsL1DAValidatorZKsyncOS.sol`                                                | Blob publication, availability checks, and DA validation entrypoints                                         | `da-contracts/test/foundry/BlobsL1DaValidatorZKsyncOS.t.sol`; `yarn test:foundry` passed 8 tests                                                                     |
| `l1-contracts/contracts/bridgehub/*` and ChainTypeManager paths                                        | CTM registration/removal, chain/admin setters, asset routing, gateway and settlement-layer paths             | Bridgehub unit/integration suites under `l1-contracts/test/foundry/l1`; included in passing `yarn test:foundry`                                                      |
| `l1-contracts/contracts/bridge/*`, `native-token-vaults/*`, and asset handlers                         | NTV migration, token registration, deposits, withdrawals, bridgehub deposits, chain balances, asset handlers | L1SharedBridge, L1Nullifier, L1AssetTracker, L2AssetTracker, GWAssetTracker, ChainAssetHandler, and L2-in-L1-context suites; included in passing `yarn test:foundry` |
| `l1-contracts/contracts/state-transition/verifiers/ZKsyncOSDualVerifier.sol`                           | Dual verifier validation and verifier switching behavior                                                     | `l1-contracts/test/foundry/l1/unit/concrete/state-transition/verifiers/ZKsyncOSDualVerifier.t.sol`; included in passing `yarn test:foundry`                          |
| `l1-contracts/contracts/common/UpgradeableBeaconDeployer.sol`                                          | Beacon deployment helper entrypoint and revert paths                                                         | `l1-contracts/test/foundry/l1/unit/concrete/Bridge/UpgradeableBeaconDeployer.t.sol`; included in passing `yarn test:foundry`                                         |
| `l1-contracts/contracts/PrividiumTransactionFilterer.sol`                                              | Admin-managed transaction filterer entrypoints                                                               | `l1-contracts/test/foundry/l1/unit/concrete/PrividiumTransactionFilterer/*`; included in passing `yarn test:foundry`                                                 |
| `l1-contracts/contracts/state-transition/chain-interfaces/Utils.sol` and zksync-os SystemContext paths | zksync-os protocol-version and settlement-layer helpers reachable from public test harnesses                 | `l1-contracts/test/foundry/zksync-os/unit/SystemContext*.t.sol`; included in passing `yarn test:foundry`                                                             |

No uncovered newly added external/public v31 function was identified in the audited L1, L2, and DA runtime surfaces after mapping the diff to active tests. The remaining skipped-test risk is limited to the two system-contract EVM-emulation opcode tests, which are blocked on runner opcode support rather than contract logic, plus the separately documented remote mainnet-fork upgrade test that is intentionally excluded from the default local suite.

## Commands Run

- `git fetch origin main draft-v31`
- `git submodule update --init --recursive`
- `yarn install --frozen-lockfile`
- `cd da-contracts && yarn test:foundry`
- `cd l1-contracts && yarn build:foundry`
- `cd l1-contracts && yarn test:foundry`
- `cd system-contracts && yarn build:foundry`
- `cd l1-contracts && yarn test:zkfoundry`
- `cd l1-contracts && yarn build` attempted; blocked by Hardhat `HH411` resolving `forge-std` from deploy scripts.
- `yarn prettier --write ...`
- `yarn lint:check`
- Skipped-test scan with `rg` over `da-contracts/test`, `l1-contracts/test`, `l2-contracts/test`, `system-contracts/test`, and `system-contracts/bootloader/tests`.
