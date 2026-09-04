# EVM-1521 handoff

## Delivered

L1 priority requests now enter through a governance-owned, transparent-proxy
L1InteropCenter using ERC-7786 `sendMessage` or an exactly-one-call `sendBundle`.
Direct and indirect requests retain Mailbox transport, canonical transaction hashes,
refund aliasing, token custody and failed-transfer recovery. Bridgehub's former request
entry points are removed, its registry controls authorization, and migration-admin
protection recognizes both new entry points. Deployment, upgrade, Solidity helpers,
TypeScript deposits, Rust verification, documentation, ABIs, selectors, hashes and current
Anvil states are migrated; the L2 contract is renamed without changing its executable runtime.

Base: `cfbfd9231ed7033e8bb765650f9d8f83c37d679c` on `draft/v0.34.0`.
Branch: `vg/evm-1521-l1-interop-center`. Full clone; no cherry-picks or rebases of #2271.
The prior branch has 511 commits of base drift. PR #2454 is present; the v33 release is
not an ancestor and current genesis remains `0.32.0`, execution version 5.

## Decisions to challenge

- Remove the two Bridgehub request ABIs immediately. This assumes no external v34
  consumers or cross-chain sender implementations; repository search finds three
  production implementers but cannot establish the external inventory. One-release
  forwarding shims are the rejected alternative if partners still require them.
- Resolve authorization dynamically through Bridgehub. Per-chain storage saves gas
  but adds diamond storage and a configuration migration for every chain.
- Keep the L2 implementation outside the new storage-bearing L1 base. Sharing more
  implementation would risk storage and bytecode behavior at the L2 size limit.
- Support exactly one call per L1 bundle. Rejecting bundles loses interface parity;
  multi-call atomicity would require a different transport design.
- Preserve the original handshake marker numerically, changing only its identifier.
  Changing the marker would add an unnecessary wire incompatibility.
- Reject `factoryDeps` on indirect messages even when empty. Silently ignoring it
  would hide caller mistakes. Require transaction parameters and reject duplicate,
  misplaced, truncated or unsupported attributes.
- Extend PermanentRestriction to indirect bundles and the current chain asset handler.
  Updating only `sendMessage`, as in #2271, would leave an equivalent migration route
  outside its admin check. Direct messages to the asset router do not count as migrations.
- Select historical/current upgrade discovery explicitly with `has_l1_interop_center`.
  The default is false; existing-center upgrades set it true. Probing missing historical
  getters and suppressing their failures was rejected. Upgrade output records whether
  the center proxy is newly deployed for provenance verification.

The detailed design, alternatives and migration instructions are in
[the design note](protocol-docs/l1-interop-center.md).

## Behavior and regression coverage

| Change                                                                                        | Justification and coverage                                                                                                                                                                                                                                                                                                                                            |
| --------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| New permissionless sends, owner-only pause/unpause, locked initializer, nonreentrant wrappers | `Interop/L1InteropCenter.t.sol`, `Interop/InteropAttributeDomains.t.sol`: direct/indirect success and failure, exact funding fuzzing, bundle length, attributes, event recipient, owner/zero-address checks and reentry through both wrappers.                                                                                                                        |
| Mailbox and three L1 senders accept only the registered center                                | `Base/OnlyL1InteropCenter.t.sol`, Mailbox request tests, AssetRouter, CTMDeploymentTracker and ChainRegistrationSender tests include unauthorized Bridgehub/caller negatives and confirmation access checks.                                                                                                                                                          |
| Canonical confirmation after Mailbox dispatch                                                 | `integration/L1InteropCenterIntegration.t.sol`: real router/vault/Mailbox/nullifier, recorded `depositHappened`, canonical hash and `bridgeRecoverFailedTransfer` refund. Only the L2 inclusion proof is mocked to isolate proof verification.                                                                                                                        |
| Exact funding across ETH and ERC20 base/deposit assets                                        | Integration funding matrix and `L1InteropDepositHarnesses.t.sol` exercise both migrated deposit harnesses. `L1InteropRequestHelpers.t.sol` fuzzes forwarded ETH; `L1InteropRequestHelpersIntegration.t.sol` executes all four governance/admin, direct/indirect ERC20-base combinations against the real vault and Mailbox.                                           |
| Bridgehub registry setter                                                                     | Bridgehub tests check owner/upgrader access, zero address rejection, event and state. The field occupies the first reserved gap slot.                                                                                                                                                                                                                                 |
| Migration admin recognition                                                                   | PermanentRestriction tests cover valid message/bundle, direct false positives, truncated attributes, old selectors and unapproved admins.                                                                                                                                                                                                                             |
| Upgrade deployment and wiring                                                                 | `Upgrades/L1InteropCenterWiring.t.sol` checks new proxy ownership/registration, existing proxy upgrade preserving owner/pause state, and missing proxy rejection. `L1InteropCenterOwnership.t.sol` covers governance acceptance; `L1InteropCenterDiscovery.t.sol` covers historical/current registry ABIs. Local upgrade integration and the frozen v31 harness pass. |
| L2 rename and mirrored indirect vocabulary                                                    | Full L2 Foundry and Anvil interop suites; executable runtime equality and unchanged storage below. The built-in still rejects initiation on L1.                                                                                                                                                                                                                       |
| Historical and current tooling                                                                | Rust tests retain selectors `0xd52471c1` and `0x24fd57fb`, check current mode/value decoding, simulator recognition, gateway CREATE2 decoding, stage-1 new/existing proxy provenance, optional historical aliases and current stage-2 approval/call positions. TS tests cover ERC-7930 recipients and attribute encoding.                                             |

Prividium's sender remains the L1 asset router; its tests run in the full suite.
The nullifier's forwarded confirmation ABI and `BridgehubDepositFinalized` event remain
unchanged. The existing gateway migration/recovery/return/upgrade tests pass.

Removed-call consumer audit covers contracts, deploy scripts, Solidity tests, Anvil TS,
ABIs, Rust and docs. No old request functions, old marker identifier or exact
`bridgehubDeposit` function name remains in production contracts, deploy scripts or
Anvil source. Historical upgrade records and Rust decoders deliberately keep historical
names; the v31 calldata guide labels those examples as historical. `bridgehubDepositBaseToken`
and the forwarded nullifier confirmation retain their existing internal ABI names.

## Storage and size

Compared upstream `forge inspect <Contract> storage-layout --json` at base and current
source, normalizing compiler AST/type IDs while retaining member types, slots and offsets.

| Contract                                           | Storage result                                                                                                                                                               |
| -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| L1Bridgehub                                        | Existing fields unchanged. Add `address interopCenter` at slot 221, offset 0; `uint256[36] __gap` at 221 becomes `uint256[35] __gap` at 222. Final occupied range unchanged. |
| L2Bridgehub                                        | Same append through shared BridgehubBase; existing fields unchanged.                                                                                                         |
| L1AssetRouter, L1Nullifier                         | Unchanged.                                                                                                                                                                   |
| CTMDeploymentTracker, ChainRegistrationSender      | Unchanged.                                                                                                                                                                   |
| MailboxFacet, L2AssetRouter                        | Unchanged.                                                                                                                                                                   |
| InteropCenter → L2InteropCenter                    | Unchanged, including storage-bearing inheritance.                                                                                                                            |
| PermanentRestriction, PrividiumTransactionFilterer | Unchanged.                                                                                                                                                                   |

No existing live field is reclaimed or renumbered. L1InteropCenter is a new proxy with
no predecessor layout. Its implementation is locked against initialization.

| Runtime                                    |           Bytes | EIP-170 limit |
| ------------------------------------------ | --------------: | ------------: |
| First-cut L1InteropCenter                  |          14,382 |        24,576 |
| Final L1InteropCenter                      |          14,413 |        24,576 |
| Base InteropCenter / final L2InteropCenter | 22,247 / 22,247 |        24,576 |

The L2 deployed runtime is byte-for-byte identical after removing CBOR compiler metadata.
The complete artifact hash changes because of the source path/name and metadata.

## Gas

Matched real-Mailbox fixtures at base and current source, using
`vm.snapshotGasLastCall` around an encoded external request call. Both use an ETH-base
chain, 1 ETH mint value, 1 gwei gas price, 1,000,000 destination gas, no factory dependencies;
the indirect request additionally deposits 1 ETH worth of the test ERC20. Setup, ABI
encoding, assertions and transaction intrinsic gas are excluded. These are execution
comparisons, not universal wallet transaction estimates.

| Request  |    Base | Current |        Increase |
| -------- | ------: | ------: | --------------: |
| Direct   | 237,969 | 271,615 | 33,646 (14.14%) |
| Indirect | 386,192 | 423,645 |  37,453 (9.70%) |

The isolated dynamic authorization check costs 12,755 gas cold / 1,755 warm versus
2,396 cold / 396 warm for a stored-address check: incremental 10,359 / 1,359 gas.
The cold probe explicitly clears access warmth; it does not modify storage values.
Reproduce current measurements with `L1RequestGas.t.sol`.

## Validation

Toolchain: upstream Foundry v1.5.1, commit `b0a9dd9ce` (repository pin), Solidity 0.8.28,
Node 22, Yarn 1.22.22, Rust 1.91.1 for protocol-ops checks (matching CI),
Rust 1.95 for the local upgrade harness, and nightly-2026-02-10 for the OS genesis generator. All commands are local; Anvil creates local chains only.
Recorded completed runs:

| Command                                                                                                                       | Result                                                                                                                                 |
| ----------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `forge clean --root da-contracts && forge clean --root l1-contracts` then `yarn da build:foundry` and `yarn l1 build:foundry` | Pass; clean default-profile build and ABI copy with the pinned dependency remapping.                                                   |
| `yarn l1 test:foundry`                                                                                                        | **2,524 passed, 0 failed, 0 skipped**, 303 suites; 67.54 s tests / 68.91 s command. Includes Prividium and gateway integration.        |
| Same full test command at base, with the new direct comparison test                                                           | 2,471 passed, 0 failed; 62.25 s tests / 72.24 s command. Untouched baseline has 2,470 tests.                                           |
| `yarn lint:check`                                                                                                             | Pass; markdownlint, solhint, eslint, CI-script typecheck, prettier and documentation anchors.                                          |
| `yarn l1 errors-lint --check`                                                                                                 | Pass; all selector comments correct, 6.56 s.                                                                                           |
| `yarn calculate-hashes:fix` then `yarn calculate-hashes:check`                                                                | Pass; strict manifest contains 173 contracts, check 1.80 s.                                                                            |
| OS genesis generator using `nightly-2026-02-10`, `--locked --release`                                                         | Pass; generator artifact rename updated and `configs/genesis/zksync-os/latest.json` reproduces exactly after the clean build.          |
| `forge selectors list --threads 1` with normalized final newline                                                              | Regenerated `l1-contracts/selectors` using upstream Forge; exact comparison checked.                                                   |
| `forge inspect <Contract> storage-layout --json` at base and current source                                                   | All 11 layouts above pass; only the reserved Bridgehub gap changes.                                                                    |
| `cargo fmt --manifest-path protocol-ops/Cargo.toml --check`                                                                   | Pass.                                                                                                                                  |
| `cargo clippy --manifest-path protocol-ops/Cargo.toml --locked --offline --all-targets -- -D warnings`                        | Pass with the CI-pinned Rust toolchain.                                                                                                |
| `cargo test --manifest-path protocol-ops/Cargo.toml --locked --offline`                                                       | **46 passed, 0 failed**; binary/doc targets also pass.                                                                                 |
| Anvil directory: `yarn tsc --noEmit` and `yarn test:unit`                                                                     | Pass; 51 unit cases and TypeScript typecheck.                                                                                          |
| `ANVIL_INTEROP_PORT_OFFSET=20000 ANVIL_INTEROP_FRESH_DEPLOY=1 yarn l1 test:hardhat:interop`                                   | **105 passing**, 300.53 s total.                                                                                                       |
| Anvil directory: `ANVIL_INTEROP_PORT_OFFSET=20000 yarn test:v31-to-v32`                                                       | Pass; frozen v31 upgrade of L1-settled chain 10 and gateway chain 11 with final-version checks, 240.04 s.                              |
| Anvil directory: `ANVIL_INTEROP_PORT_OFFSET=20000 yarn setup-and-dump`                                                        | Pass; six v0.34.0 snapshots and addresses regenerated twice (190.37 / 145.98 s); CI comparator passes. Historical snapshots unchanged. |
| `yarn l1 test:hardhat:interop --port-offset 20000`                                                                            | **104 passing**, all ten groups; 82.1 s test run.                                                                                      |
| `git diff --check` and tracked-file audit                                                                                     | Pass; no dependencies, build outputs or temporary evidence included.                                                                   |

Rust used a workspace-local `CARGO_HOME` containing the already-installed registry cache.
Foundry tests required host execution because sandboxed macOS system-configuration lookup
panics; this was an environment issue, not a failing assertion. Generated TS `dist/` was
removed before root lint because the root prettier glob includes ignored build outputs.
The selector wrapper interpolates an unquoted absolute path and fails in this workspace
whose name contains parentheses. Its exact underlying operation was run safely instead:

```python
import pathlib
import subprocess

result = subprocess.run(
    ["forge", "selectors", "list"], cwd="l1-contracts",
    check=True, text=True, capture_output=True,
)
pathlib.Path("l1-contracts/selectors").write_text(result.stdout.rstrip() + "\n")
```

The state dumper uses a relative formatting glob so workspace punctuation cannot prevent
formatting. Only task-owned Anvil ports were used and cleaned up. Generated
chain-11/chain-14 test config changes were restored after runs.

## CI and review corrections

The first CI run exposed five failures, addressed at their sources:

- Pin the duplicate `erc4626-tests` remapping to CI's resolution. All 156 L1 manifest
  entries differed only through compiler metadata; the 17 DA entries already matched.
- Rebuild DA contracts in the snapshot writer after selecting `anvil-interop`. The
  prior local snapshots embedded default-profile DA bytecode and different CREATE2 addresses.
- Use `L2InteropCenter` in the OS genesis generator and regenerate the genesis image.
- Preserve CTMDeploymentTracker's scoped `locked-ether` annotation on its renamed
  payable interface method, which immediately rejects nonzero ETH. No detector was disabled globally.
- Correct the spelling of “implementers” in the documentation.

Independent review passes also tightened deployment ownership acceptance, historical CTM
address discovery, explicit new/existing proxy provenance, and optional historical address
aliases. ERC20 request helpers approve the NativeTokenVault that performs `transferFrom`;
the Rust verifier mirrors that spender and the current 13-call gateway layout, binds
approvals to Bridgehub's registered gateway base token, and rejects ETH-bearing approvals. Targeted
regressions accompany these fixes. These are independent agent reviews, not approvals
from the named human reviewers or a quantified probability of approval.

## Limits and follow-ups

No production/mainnet fork upgrade was attempted: the full repository command explicitly
excludes the RPC-dependent mainnet test and ChainRegistrarTest. All required local suites
were run; live Safe/governance execution and external integrator compatibility remain human
release checks. Historical Rust tests retain request/approval decoding from real frozen calldata. Full
verification of the old 16-call gateway ceremony remains outside the current 13-call
verifier, as on the base branch. The v31 upgrade harness prepares and executes the current
upgrade ceremony against frozen v31 state.

The existing disabled withdrawal invariants (EVM-1391) were not enabled;
both migrated deposit helper families are exercised by explicit matrix tests.

Proposed follow-ups, not filed:

- **Confirm v34 external request and sender ABI inventory.** Obtain partner/SDK sign-off
  before removing the old public surface in a release. If an external consumer exists,
  choose and test a one-release shim policy before deployment.
- **Make selector generation safe for workspace paths with spaces or punctuation.**
  Replace shell redirection with a file descriptor or properly quoted path. The present
  migration used the equivalent upstream command without changing unrelated tooling.
- **Re-enable withdrawal invariants after EVM-1391.** Keep that work separate from request
  initiation so this PR does not alter withdrawal semantics. The new deposit matrices
  cover the migrated helpers while the existing invariant blocker remains.

## Human review and release steps

Review canonical confirmation/recovery and authorization first, then PermanentRestriction's
message/bundle decoding, then stage-1 ownership/registry ordering and historical Rust
compatibility. Confirm the external-consumer assumption and explicit upgrade-discovery flag.
Protocol owns the change; Kalman Lajko is the natural interop/interface reviewer and
Stanislav Bezkorovainyi the deployment/tooling reviewer, with bridge/withdrawal reviewers
for custody and recovery. No review requests were sent.

ABIs, selectors, AllContractsHashes, the OS genesis and v0.34.0 states are regenerated locally.
PR CI verifies them at the reviewed commit;
the hash-update workflow only accepts upstream-repository branches, so it cannot update
this fork PR directly. The human may comment on EVM-1521 with the draft PR and validation
results and select the appropriate status once review is ready. No Linear, Slack or Notion
writes, live deployments, merges or Era-only removals were performed.
