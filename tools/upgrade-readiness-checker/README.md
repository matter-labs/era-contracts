# upgrade-readiness-checker

Waits until a ZKsync chain's pending protocol upgrade has been processed by the
server and finalized on the settlement layer. Exits `0` on finalization and
non-zero on fatal setup errors; blocks otherwise. Slack notifications are the
workflow's responsibility.

## What "ready" means

The upgrade can be safely finalized on L1 once:

1. The L2 server has produced a receipt for the canonical upgrade tx (i.e.
   included it in L2 block **N**), and
2. Block **N-1** is finalized on the settlement layer — its batch has been
   executed. In zksync-os the `"finalized"` block tag resolves to
   `last_executed_block`, so we compare `finalized >= N - 1`, i.e. batch
   execution on the settlement layer.

## How it works

1. Resolves `ChainTypeManager` via
   `Bridgehub.chainTypeManager(chainId)` on the settlement layer.
2. Scans for the newest `NewUpgradeCutData(targetProtocolVersion, ...)` on the CTM
   and dispatches on the cut's init calldata:
   - a registry edge (`upgradeFromTransition(transition)`) is resolved per chain,
     because the event is keyed by the target version only and a replaced edge
     leaves several cuts under it. A chain below the target reads the transition
     its CTM commits for the chain's own version (`upgradeTransition`), which
     must land on the target, and takes `l2UpgradeTx(bridgehub, chainId)` from
     it. A chain at or past the target already crossed, so the hash comes from
     its diamond's `UpgradeComplete(target)` event;
   - the bootstrap edge (`upgradeFromBootstrap(migration)`) reads the
     transaction from the migration's `l2UpgradeTx(chainId)`;
   - a legacy pre-v35 cut embeds it in `ProposedUpgrade`.
3. For a legacy cut, replays the per-chain upgrade-data rewrite for v31+ upgrades
   (trying the current ABI, then the legacy ABI used by already-published upgrades).
   Computes the canonical tx hash: `keccak256(tx.abi_encode())`. An upgrade with
   no L2 transaction (`txType == 0`) exits with a diagnostic.
4. Polls the chain's L2 RPC:
   - `eth_getTransactionReceipt(hash)` — once present, we have block **N**.
   - `eth_getBlockByNumber("finalized", false)` — waits until the returned
     block number is ≥ N-1.
5. The tool blocks indefinitely until finalization. The surrounding workflow
   owns any upper-bound timeout and user-facing notifications (Slack).

Verifier-only upgrades have no L2 receipt to monitor, so the checker exits
with an explicit diagnostic instead of waiting for a transaction that cannot appear.

## Running locally

```sh
cargo run --release -- \
  --chain-id 300 \
  --l2-rpc-url https://my-chain.rpc \
  --settlement-rpc-url https://sepolia.rpc \
  --bridgehub-address 0x... \
  --target-minor-version 31 \
  --target-patch-version 0
```

The minor/patch pair is packed into the u256 the CTM stores (`(minor << 32) | patch`).

All flags also accept environment variables (see `--help`).
