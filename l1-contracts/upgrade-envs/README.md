# Upgrade environments

This directory holds the inputs and the committed outputs of ecosystem upgrades, per release and
per environment. The pipeline that consumes them is described in
[protocol-docs/ecosystem-upgrade.md](../../protocol-docs/ecosystem-upgrade.md).

## Layout

```
upgrade-envs/
  permanent-values/<env>.toml           # per-environment facts, independent of the release
  <release>/<env>.toml                  # per-release inputs for that environment
  <release>/output/<env>/               # the committed artifacts of that rollout
  <release>/sim-descriptions.toml       # labels for the transaction-simulator scenarios
```

`<release>` is the full release name (`v0.34.0-chain-config`); `<env>` is `stage`, `testnet`,
`mainnet`, `adi`, `local`, `foundry-upgrade`, `zksync-os-integration-test` or `anvil-interop` (the
fixture `.github/tests/release-flow.sh` upgrades). `protocol_ops --env <env>` reads
`permanent-values/<env>.toml` together with `<release>/<env>.toml` of the release named by
`current_upgrade_env_dir!` in `protocol-ops/src/common/forge/scripts/mod.rs` (moved by
`yarn new-release`), and writes to
`<release>/output/<env>/`. Both files must exist for an environment: the tooling refuses to fall
back to `local` values.

### `permanent-values/<env>.toml`

What identifies the environment: L1 chain id, Bridgehub, the registered CTMs with their VM type,
the governance kind (`puh` for a `ProtocolUpgradeHandler`, otherwise the legacy `Governance`),
the testnet-verifier flag (`testnet_verifier`, true everywhere except mainnet; the prepare refuses
to run without it), the ZK token asset id and owners that must be wrapped rather than
impersonated. Update it when a release moves an address; never put per-release values here.

### `<release>/<env>.toml`

What the release needs from the environment: the owner address and Era chain id, the CREATE2 salt
for the core deploys and one per CTM under `[create2_factory_salts]`, and the release's one-off
switches (`redeploy_zk_governance`, which `yarn new-release` does not copy into the next release,
`[contracts] eip7702_checker`). Keep it small: anything derivable from L1 is read from L1 instead. The old protocol version in particular
is not read from here: the CTM script reads it from the CTM. The `old_protocol_version` and
`testnet_verifier` keys some input files still carry are dead.

The salts must be rotated before every regeneration. A repeated `(salt, init code)` pair resolves to
the contract an earlier run already deployed, so a regeneration with old salts deploys nothing new
for unchanged contracts and its run records no deployment transaction for them.

```bash
python3 -c "import secrets; print('0x' + secrets.token_hex(32))"
```

### `[contracts] eip7702_checker`

Carry the CTM domain's live EIP-7702 checker forward from the previous prepare's output
(`[state_transition] eip7702_checker_addr`). It is a permanent, argument-less singleton the
`MailboxFacet` pins as an immutable, and nothing on-chain exposes it, so it cannot be
auto-detected. Omitting it makes the prepare deploy a fresh one, which changes the Mailbox's
immutable and therefore replaces the Mailbox facet — and cuts it on every chain — even for an
upgrade that changes neither. Omit it only for a CTM that has no checker yet.

### `<release>/output/<env>/`

| File                          | Committed | Content                                                                                                                                                                     |
| ----------------------------- | --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ecosystem.toml`              | yes       | the artifact: every new address, the registry objects (`[core.registry]`, `[ctms.*.registry]`), the one governance bundle (`[governance_calls]`) and `[[external_actions]]` |
| `transactions.txt`            | yes       | L1 transaction hashes of the deployer's broadcasts, appended on every run; an operational record that no verifier reads                                                     |
| `extra-verification-logs.txt` | yes       | `forge verify-contract` lines with constructor arguments, one per deployed contract                                                                                         |
| `sim-inputs/`, `simulator/`   | yes       | transaction-simulator inputs and scenarios                                                                                                                                  |
| `chain-upgrades/<chain-id>/`  | yes       | the per-chain Safe bundles (`set-upgrade-timestamp`, `upgrade`)                                                                                                             |
| `README.md`                   | yes       | the rollout record for that environment: ceremony, validation results, reproduction commands                                                                                |
| `prepare/`, `fork-rehearsal/` | no        | per-run Safe bundles, `manifest.json` and rehearsal logs, regenerated by the prepare (see below)                                                                            |

`.gitignore` excludes the whole `fork-rehearsal/` directory. Elsewhere under `output/`, including
`prepare/`, the per-run files are ignored by file pattern: every `*.safe.json` and `manifest.json`
(except in `sim-inputs/` and `chain-upgrades/`) plus a list of scratch files (`executed.json`,
`anvil.log`, `manifest-deployer-only.json`, `sepolia-deploy-executed.json`, `regen/`, ...).
Anything else written into `prepare/` shows up as untracked and must not be committed.

If the deployer broadcast is run again after a regeneration, the previously deployed contracts
are skipped, so `transactions.txt` is append-only: the hashes of earlier runs stay in it as the
record of those deployments. Provenance does not depend on it: `protocol-ops ecosystem verify-bootstrap`
re-derives every CREATE2 address from the salts and the creation code (see
[docs/registry-driven-upgrades.md](../../docs/registry-driven-upgrades.md#provenance-and-validation)).

## Earlier releases

The `v0.26.x` to `v0.30.0` directories predate the current tooling and keep the format of their
time (`*-ecosystem.yaml` outputs generated by `upgrade-yaml-output-generator`, `run-latest.json`
broadcast logs, `verification-logs`). They are historical records and are not regenerated.
