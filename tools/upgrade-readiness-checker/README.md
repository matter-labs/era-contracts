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
   `last_executed_block`, so we compare `finalized >= N - 1`. For direct
   L1-settling chains this corresponds to batch execution on L1; for
   gateway-settling chains, on the gateway.

## How it works

1. Resolves `ChainTypeManager` via
   `Bridgehub.chainTypeManager(chainId)` on the settlement layer (L1 for direct
   chains, gateway L2 for gateway-settling chains).
2. Scans for `NewUpgradeCutData(targetProtocolVersion, ...)` on the CTM and
   decodes the embedded `L2CanonicalTransaction` from the diamond cut init
   calldata.
3. Computes the canonical tx hash: `keccak256(tx.abi_encode())`.
4. Polls the chain's L2 RPC:
   - `eth_getTransactionReceipt(hash)` — once present, we have block **N**.
   - `eth_getBlockByNumber("finalized", false)` — waits until the returned
     block number is ≥ N-1.
5. The tool blocks indefinitely until finalization. The surrounding workflow
   owns any upper-bound timeout and user-facing notifications (Slack).

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

## Running from GitHub Actions

See [`.github/workflows/upgrade-readiness-check.yaml`](../../.github/workflows/upgrade-readiness-check.yaml).
Manually triggered; posts to Slack when the tool exits (success or failure).
The Slack webhook is read from the `UPGRADE_READINESS_SLACK_WEBHOOK_URL` repo
secret.
