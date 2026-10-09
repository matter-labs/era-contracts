# Atomic chain upgrade + DA-validator-pair calldata (Era / chain 301, Sepolia)

## Task

1. Amend the protocol-ops script so a chain upgrade can **also** set the DA
   validator pair right after the upgrade — **atomically**, in a single
   transaction (required for Era: the v31 upgrade resets the chain's L1 DA
   validator, so it must be re-set before the chain can commit batches).
2. Generate the corresponding calldata for **chain 301** (Era) on **Sepolia**.

## What was changed

### Solidity — `l1-contracts/deploy-scripts/AdminFunctions.s.sol`

- Extracted `_buildUpgradeChainFromCTMCall(address)` (the version-aware
  `upgradeChainFromVersion` call builder, reused by the plain upgrade).
- Added `upgradeChainFromCTMAndSetDAValidatorPair(_chainAddress, _adminAddr,
_accessControlRestriction, _l1DaValidator, _l2DaCommitmentScheme)`. It builds a
  2-element `Call[]` — `upgradeChainFromVersion` then `setDAValidatorPair` — and
  runs them through a **single `ChainAdmin.multicall`** via
  `Utils.adminExecuteCalls`. Ordering matters: the upgrade installs the v31
  AdminFacet first, so the subsequent `setDAValidatorPair(address,
L2DACommitmentScheme)` (a v31-only signature) hits the freshly-installed facet
  in the same tx.

### Rust — `protocol-ops/src/commands/chain/upgrade.rs`

- New optional flags `--l1-da-validator` + `--l2-da-commitment-scheme` (clap
  `requires` each other). When both are set, the command drives the combined
  entrypoint; otherwise behavior is unchanged. The DA pair requires a single
  `--chain-id` (it is chain-specific and cannot be applied across a loop).
- `--l2-da-commitment-scheme` reuses the existing `L2DACommitmentScheme` enum.
- `ChainUpgradeOutput` now records the DA pair when set.

### Rust — `protocol-ops/src/common/forge/scripts/mod.rs`

- Registered `AdminFunctionsAbi::upgradeChainFromCTMAndSetDAValidatorPairCall` in
  the `script_calls!` macro so it can be driven via `ForgeRunner::script_call`.

### `l1-contracts/zkstack-out/AdminFunctions.s.sol/AdminFunctions.json`

- Regenerated ABI (additive — the new function only) so the alloy `sol!` macro
  picks up the new binding at compile time.

## Generated calldata

`chain-301/01_chain.upgrade_0x5555555590930f501c88b73ea43b3eeb5a71643c.safe.json`
is a Gnosis Safe Transaction Builder bundle with **one** transaction:

| field                | value                                                                               |
| -------------------- | ----------------------------------------------------------------------------------- |
| chainId              | `11155111` (Sepolia)                                                                |
| to (signer/exec)     | `0x1d22308Cd438C3C4e30f3c5d5b3426bAb688208C` — Era chain's `ChainAdmin`             |
| owner that must sign | `0x5555555590930f501c88B73Ea43B3EEb5A71643c` — `ChainAdmin.owner()`                 |
| method               | `multicall((address,uint256,bytes)[],bool)` (`0x69340beb`), `requireSuccess = true` |

The multicall wraps exactly two inner calls, both targeting the Era diamond
proxy `0xD3bc4353957bc0F138318384aa207C708A9455C4`:

1. `upgradeChainFromVersion(uint256,((address,uint8,bool,bytes4[])[],address,bytes))`
   (`0xfc57565f`) — the legacy v29 variant (chain 301 is currently `0x1d00000004`
   = v29; the Era CTM already exposes v31 = `0x1f00000000`).
2. `setDAValidatorPair(address,uint8)` (`0x2765d079`) with
   `l1DaValidator = 0xcc46b186bd4515fa996adf3c40344ed7d546a65b`,
   `l2DaCommitmentScheme = 3` (`BlobsAndPubdataKeccak256`).

Because both live in one `multicall`, they are applied in a single atomic L1 tx —
the chain is never left upgraded-but-without-DA-validator.

### Inputs (pinned from `upgrade-envs/permanent-values/testnet.toml`)

- Bridgehub (testnet): `0xc4FD2580C3487bba18D63f50301020132342fdbD`
- Era chain id: `301`
- L1 DA validator: `0xcc46b186bd4515fa996adf3c40344ed7d546a65b`
- L2 DA commitment scheme: `BlobsAndPubdataKeccak256`

## Validation

The bundle was produced by a `forge script --broadcast` run against a **live
Sepolia anvil fork**. The multicall executed with `requireSuccess = true`, so the
post-upgrade `setDAValidatorPair` did **not** revert — i.e. the pair is allowed
on the live Era RollupDAManager. No real-chain state was modified.

## Reproduce

```bash
export TENDERLY_SEPOLIA=<L1 Sepolia RPC>
./calldata-out/reproduce.sh
```

The script is idempotent. To execute the bundle for real, replay it with
`protocol-ops dev execute-safe` (or any Safe-bundle-aware executor) signing as
`ChainAdmin.owner()`.
