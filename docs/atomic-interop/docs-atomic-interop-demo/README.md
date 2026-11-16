# Atomic interop demo

A local sandbox of two ZKsync OS chains on protocol version v33 that settle on a local Ethereum node,
with three example flows of ZKsync atomic interop: a cross-chain call, a refund after a missed deadline,
and a token swap.

## Quickstart

You need Docker with Docker Compose.

```bash
docker compose run --rm demo
```

This starts the chains, waits until they are registered with each other, and runs the three flows. The
initial run downloads about 430 MB of Docker images and the 21 MB L1 state; later runs take about a minute and a half. The chains
keep running afterwards:

| Node                 | Chain ID | RPC                     |
| -------------------- | -------- | ----------------------- |
| Ethereum (L1, Anvil) | 31337    | `http://127.0.0.1:8545` |
| Chain A              | 506      | `http://127.0.0.1:3050` |
| Chain B              | 507      | `http://127.0.0.1:3051` |

Run a flow again from your machine (needs Node.js):

```bash
npm install
npm run call     # or: npm run refund, npm run swap, npm run demo
```

Stop and delete everything with `docker compose down`. The next start begins with new chains.

The tutorial, `docs/atomic-interop/02-tutorial.md` in this repository, walks through the code.

## What's inside

| Path                                      | Content                                                                                                |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `scripts/common.ts`                       | Chains, accounts, addresses and ABIs, helpers for hints and proofs, and one function per contract call |
| `scripts/call.ts`, `refund.ts`, `swap.ts` | The three flows; `scripts/demo.ts` runs them in a row                                                  |
| `contracts/`                              | The receiver and the demo token; the scripts compile them with `solc`                                  |
| `docker-compose.yaml`                     | The L1, the two chains, the registration step and the demo                                             |
| `docker/`                                 | What the containers load: genesis, server configs, start-up scripts, and the L1 state download         |

| Service              | Image                                                                       |
| -------------------- | --------------------------------------------------------------------------- |
| `l1`                 | `ghcr.io/foundry-rs/foundry:v1.8.4` (Anvil)                                 |
| `chain-a`, `chain-b` | `ghcr.io/matter-labs/zksync-os-server:v0.24.5`                              |
| `register`           | `ghcr.io/foundry-rs/foundry:v1.8.4`                                         |
| `demo`               | `node:24.22.1-slim`; `docker compose run --rm demo` starts it, `up` doesn't |

The servers run with simulated provers, close a batch after at most a second, and watch the L1 every
100 ms. Their pubdata price is capped at 1 gwei per byte: the sandbox's nearly empty batches would
otherwise raise it until contract deployments exceed the per-transaction gas limit. Their databases are
kept in memory. Anvil makes a block every 250 ms and starts with its clock set
to the current time. On both chains, the ZKsync rich wallet `0x36615Cf349d7F6344891B1e7CA7C72883F5dc049`
and Anvil's accounts #1 to #9 hold 100 ETH each. These are public test keys: never use them on a real
network.

## How the L1 state was made

The input is a v33.2 single-chain L1 state with chain 506 on era-contracts `v0.33.2` (`0efa1dd`), public
as `dev/zksyncos/l1-state.json.gz` in `matter-labs/local-prividium` at commit `f5fcd53`;
`docker/genesis.json` comes from the same folder.

`docker/generate-l1-state.sh` loads it into Anvil 1.8.4 and adds chain 507 by replaying chain 506's
creation transactions with a new chain ID, new operator keys and a new CREATE2 salt. These are the steps
of era-contracts' `RegisterZKChain.s.sol` plus the deployment's funding: operator funding, the chain's
`Governance`, `ChainAdminOwnable` and `ProxyAdmin`, `Bridgehub.createNewChain`, the validator roles, the
token multiplier, the admin handover, `unpauseDeposits`, the DA validator pair and 10 L2 deposits. It then
checks the new chain against chain 506 and writes the gzipped dump.

```bash
docker/generate-l1-state.sh path/to/local-prividium/dev/zksyncos/l1-state.json.gz
```

The result is 21 MB, so it isn't on `main`: it is `l1-state.json.gz` on the `atomic-interop-demo-assets`
branch of era-contracts. The `l1-state` service (`docker/fetch-l1-state.mjs`) downloads it from a fixed
commit of that branch, checks its sha256 and keeps it in a Docker volume. A `docker/l1-state.json.gz` made by
the script above is used instead when present. To publish a new state, commit it to that branch and update
the commit and hash in `docker/fetch-l1-state.mjs`.

Interop registration (`ChainRegistrationSender.registerChain`) isn't in the state: it reverts with
`ChainHasNoBatchesInMessageRoot` until the chain being registered has a batch executed on L1, which needs
the servers. `docker/register.sh` does it on every start, in both directions, and waits until each chain
has processed the other's registration.
