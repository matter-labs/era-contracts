# V31 upgrade documentation


In the exmaples below I use `--upgrade-timestamp 1` for both Era and Zksync OS. This can be used to start an immediate upgrade.

## Transaction format

By default all the commands below simulate the transactions on a fork and dump the executed transactions in the gnosis safe like format. If one needs to create a PR in the transaction simulator supported format, you can do the following:

```
cargo run --release -- dev manifest-to-simulator \
  --manifest <path-to-folder-with-manifest.json> \
  --network <network> \
  --out <out-dir>/set-upgrade-timestamp-simulator.json
```

## ZKsync OS

Note, that the server needs the bytecode supplier to be provided manually into the config. 

ZKsync OS testnet: `0x4332c61541c4aD8ffFB158c51d9C915e8114E845`
ZKsync OS mainnet TODO.

```
cd protocol_ops 

cargo run --release -- chain set-upgrade-timestamp \
  --env <env> \
  --chain-id <chain-id> \
  --l1-rpc-url <l1-rpc-url> \
  --new-protocol-version 133143986176 \
  --upgrade-timestamp <unix-seconds> \
  --out ./v31-upgrade/set-upgrade-timestamp \
  --subdir <unique-run-name>-set-ts
```
Then, to check whether the server is ready, use this command:

```
cd ../tools/upgrade-readiness-checker

cargo run --release -- \
  --chain-id <chain-id> \
  --l2-rpc-url <chain-rpc> \
  --settlement-rpc-url <l1-or-gateway-rpc> \
  --bridgehub-address <bridgehub> \
  --target-minor-version 31 \
  --target-patch-version 0 \
  --zksync-os
```

If the server is ready, you can finalize the upgrade.

The finalization calldata:

```
cargo run --release -- chain upgrade \
  --env <env> \
  --chain-id <chain-id> \
  --l1-rpc-url <l1-rpc-url> \
  --out ./v31-upgrade/chain-upgrade \
  --subdir <unique-run-name>-chain-upgrade
```

To execute the upgrade there are two options:
- use transaction simulator execute-eoa script (avaliable in [this branch](https://github.com/matter-labs/transaction-simulator/pull/321) for now, soon to be merged) after converting the txs to the transaction simulator format
- use the following:
```
cargo run --release -- ecosystem upgrade-broadcast \
  --manifest <out-dir>/manifest.json \
  --l1-rpc-url <rpc-url> \
  --key <bundle-target-address>=<private-key>
```

### Providing the pre-v31 total supply

⚠️ This is a one-time operation. Be extremely careful with the chain, Bridgehub,
RPC endpoints, upgrade transaction, and `raw uint256` value you provide. Once the
total supply is set, the operation cannot be undone.

After a ZKsync OS chain is upgraded to v31, provide its pre-v31 base-token total supply.
First calculate the value from the repository root:

```
yarn ts-node l1-contracts/scripts/calculate-zkos-pre-v31-total-supply.ts \
  --chain-id <chain-id> \
  --bridgehub <bridgehub> \
  --l1-rpc <l1-rpc-url> \
  --l2-rpc <chain-rpc> \
  --upgrade-l1-tx <chain-upgrade-l1-tx-hash>
```

The script prints `raw uint256`; use that value as `--pre-v31-total-supply` in
the protocol-ops command that generates the Safe calldata:

```
cd protocol-ops

cargo run --release -- chain set-zkos-pre-v31-total-supply \
  --env <env> \
  --chain-id <chain-id> \
  --l1-rpc-url <l1-rpc-url> \
  --pre-v31-total-supply <raw-uint256> \
  --out ./v31-upgrade/set-zkos-pre-v31-total-supply \
  --subdir <unique-run-name>-set-zkos-pre-v31-total-supply
```

## Era

Note, that the server needs the bytecode supplier to be provided manually into the config. 

Era testnet: `0xB9703133d2A84cebdC2B5D21d01939aE483dbdcE`.
Era mainnet TODO.


The set upgrade timestamp is the same:

```
cargo run --release -- chain set-upgrade-timestamp \
  --env <env> \
  --chain-id <chain-id> \
  --l1-rpc-url <l1-rpc-url> \
  --new-protocol-version 133143986176 \
  --upgrade-timestamp <unix-seconds> \
  --out ./v31-upgrade/set-upgrade-timestamp \
  --subdir <unique-run-name>-set-ts
```

Then, to check whether the server is ready, use this command (the only difference is the lack of `--zksync-os` flag):

```
cd ../tools/upgrade-readiness-checker

cargo run --release -- \
  --chain-id <chain-id> \
  --l2-rpc-url <chain-rpc> \
  --settlement-rpc-url <l1-or-gateway-rpc> \
  --bridgehub-address <bridgehub> \
  --target-minor-version 31 \
  --target-patch-version 0 \
```


If the server is ready, you can finalize the upgrade.

The finalization calldata:

```
cargo run --release -- chain upgrade \
  --env <env> \
  --chain-id <chain-id> \
  --l1-rpc-url <l1-rpc-url> \
  --l1-da-validator <l1-da-validator> \
  --l2-da-commitment-scheme <commitment-scheme> \
  --out <out-dir>/chain-upgrade \
  --subdir <unique-run-name>-chain-upgrade
```

⚠️ Note that for Era we need to set the new DA validator pair.

E.g. for rollups, the params should be:

```
cargo run --release -- chain upgrade \
  --env <env> \
  --chain-id <chain-id> \
  --l1-rpc-url <l1-rpc-url> \
  --l1-da-validator <l1-rollup-da-validator> \
  --l2-da-commitment-scheme blobs-and-pubdata-keccak256 \
  --out <out-dir>/chain-upgrade \
  --subdir <unique-run-name>-chain-upgrade
```

The addresses of l1-rollup-da-validator are:
- testnet: 0xC18954Bb455de04D31Ac0196aDC33Bc6579D9174
- mainnet: TODO

If a chain is a Validium, please reuse the l1 rollup da validator it already uses.
