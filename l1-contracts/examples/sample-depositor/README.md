# Sample: bridge an ERC20 to a contract on a ZK chain and withdraw it back

Two small contracts that exercise the v33 deposit and withdrawal paths end to end:

- **`SampleDepositor`** (L1) holds an ERC20 (for example USDC on Sepolia) and has a function that bridges a given
  amount to an address on a ZK chain. The deposit is `Bridgehub.requestL2TransactionTwoBridges` with the
  `L1AssetRouter` as the second bridge; the `L1NativeTokenVault` pulls the tokens from the depositor and the L2
  priority transaction mints the bridged token to the receiver.
- **`SampleWithdrawer`** (L2) receives the bridged token and has a function that withdraws a given amount to an L1
  address. A withdrawal is a non-atomic interop bundle sent to the L1 chain id (`InteropCenter.sendBundle`); its single
  indirect call makes the `L2AssetRouter` burn the tokens from the withdrawer. The bundle is executed on L1 by the
  `L1InteropHandler` once the chain has published the message-inclusion proof (`executeBundle`). Each bundle salt can
  be used once per sender, so the withdrawer salts every bundle with its withdrawal counter.

Everything is deployed and driven with forge scripts, so the same commands work against the local anvil-interop
chains and against Sepolia. The pieces a chain's server does in production are covered by TypeScript: the
anvil-interop harness relays the priority transaction and mocks the inclusion proof locally, and
`scripts/finalize-withdrawal.ts` waits for the real proof and finalizes on a live L1.

```
examples/sample-depositor/
├── contracts/
│   ├── SampleDepositor.sol            L1: holds the ERC20, bridges it to a ZK chain
│   └── SampleWithdrawer.sol           L2: receives the bridged token, withdraws it to L1
├── script/
│   ├── DeploySampleDepositor.s.sol    L1: deploy (+ optionally deploy a test token) and fund the depositor
│   ├── DeploySampleWithdrawer.s.sol   L2: deploy the withdrawer
│   ├── BridgeToL2.s.sol               L1: SampleDepositor.bridgeTo(...)
│   └── WithdrawToL1.s.sol             L2: SampleWithdrawer.withdraw(...)
├── scripts/
│   └── finalize-withdrawal.ts         live chains: wait for the proof, execute the bundle on L1
└── test/
    ├── sample-depositor.spec.ts       the anvil-interop run: deposit, then three withdrawals
    └── forge-broadcast.ts             reads addresses / tx hashes from forge's broadcast output
```

## Running locally (anvil-interop)

The test starts the pregenerated anvil-interop chains, deploys both contracts with the forge scripts, bridges
1000 test tokens from the depositor to the withdrawer, and then sends three withdrawals (100, 250 and 400 tokens
to two L1 recipients), finalizing each on L1 and checking balances, `bridgedOut` and the bundle statuses.

```bash
cd l1-contracts
forge build                       # once; the harness reads ABIs from out/
yarn example:sample-depositor     # about a minute: chains + deploy + deposit + 3 withdrawals
```

Useful variations (see `test/anvil-interop/README.md` for the harness flags):

```bash
# Keep the chains running afterwards, e.g. to inspect them with cast
yarn example:sample-depositor --keep-chains

# Re-run only the spec against chains that are still running
ANVIL_INTEROP_SKIP_SETUP=1 ANVIL_INTEROP_SKIP_CLEANUP=1 \
  yarn hardhat test examples/sample-depositor/test/sample-depositor.spec.ts --network hardhat --no-compile

# Use a gateway-settled chain (12 or 13) instead of the direct-settled chain 10
SAMPLE_L2_CHAIN_ID=12 yarn example:sample-depositor

# Avoid port clashes with another anvil-interop run
ANVIL_INTEROP_PORT_OFFSET=3000 yarn example:sample-depositor
```

Every transaction is printed as a `cast run <hash> -r <rpc>` command for tracing while the chains are up.

## Running against Sepolia and a live ZK chain

The forge scripts are configured through environment variables. Every script also needs `PRIVATE_KEY`; the
deployer of a contract becomes its owner, and only the owner can bridge / withdraw.

### 1. Deploy and fund the depositor on Sepolia

```bash
cd l1-contracts
export PRIVATE_KEY=0x...                      # funded on Sepolia
export L1_RPC_URL=https://sepolia...
export BRIDGEHUB=0x...                        # the ecosystem's L1 Bridgehub
export TOKEN=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238   # USDC on Sepolia (6 decimals)
FUND_AMOUNT=100000000 \
  forge script examples/sample-depositor/script/DeploySampleDepositor.s.sol --rpc-url $L1_RPC_URL --broadcast
```

`FUND_AMOUNT` is transferred from the deployer to the depositor (here 100 USDC), so the deployer must hold it.
Leave `TOKEN` unset to deploy a mintable `TestnetERC20Token` instead; `FUND_AMOUNT` is then minted. The script
prints the addresses (they are also in `broadcast/DeploySampleDepositor.s.sol/11155111/run-latest.json`).

### 2. Deploy the withdrawer on the ZK chain

```bash
export L2_RPC_URL=https://...
forge script examples/sample-depositor/script/DeploySampleWithdrawer.s.sol --rpc-url $L2_RPC_URL --broadcast \
  --gas-estimate-multiplier 600
```

On ZKsync OS chains `eth_estimateGas` does not account for the pubdata a transaction publishes (contract
bytecode above all), so forge's default headroom runs out of gas: this deployment estimated at 1.3M gas and
consumed 5.0M on the testnet. Scale the estimate generously for every transaction sent to the ZK chain; unused
gas is refunded.

### 3. Bridge tokens to the withdrawer

```bash
DEPOSITOR=0x... L2_CHAIN_ID=<zk chain id> L2_RECEIVER=<withdrawer> AMOUNT=50000000 \
  forge script examples/sample-depositor/script/BridgeToL2.s.sol --rpc-url $L1_RPC_URL --broadcast
```

The script quotes the L2 gas with `Bridgehub.l2TransactionBaseCost` at `L1_GAS_PRICE_WEI` (default 50 gwei) for
`L2_GAS_LIMIT` (default 2,000,000) and sends that much ETH along; the surplus is refunded on L2 to
`REFUND_RECIPIENT` (default: the owner). The quote must not be below the gas price the L1 transaction is mined
with, otherwise the Bridgehub rejects the deposit. The chain's server executes the priority transaction within a
few minutes. Its L2 hash is the `txHash` of the `NewPriorityRequest` event in the L1 receipt (the hash forge
prints comes from its simulation and differs):

```bash
cast receipt <l1 tx hash> --json --rpc-url $L1_RPC_URL | jq -r \
  '.logs[] | select(.topics[0]=="0x4531cd5795773d7101c17bdeb9f5ab7f47d7056017506f937083be5d6e77a382") | "0x"+.data[66:130]'
cast receipt <that hash> status --rpc-url $L2_RPC_URL
```

The bridged token then shows up at

```bash
cast call 0x0000000000000000000000000000000000010004 "l2TokenAddress(address)(address)" $TOKEN --rpc-url $L2_RPC_URL
cast call <l2 token> "balanceOf(address)(uint256)" <withdrawer> --rpc-url $L2_RPC_URL
```

### 4. Withdraw to L1 (repeat as often as you like)

```bash
WITHDRAWER=0x... L1_TOKEN=$TOKEN AMOUNT=10000000 L1_RECIPIENT=0x... \
  forge script examples/sample-depositor/script/WithdrawToL1.s.sol --rpc-url $L2_RPC_URL --broadcast \
  --gas-estimate-multiplier 600
```

`L1_TOKEN` is resolved to the bridged token through the `L2NativeTokenVault`; pass `L2_TOKEN` to name it directly.
Every run sends a new bundle (fresh salt) and prints its hash.

### 5. Finalize each withdrawal on L1

Once the withdrawal's batch is executed on L1 and the chain's RPC serves the inclusion proof
(`zks_getL2ToL1LogProof`), execute the bundle through the `L1InteropHandler`:

```bash
L2_WITHDRAWAL_TX_HASH=<tx hash of step 4> \
  yarn ts-node examples/sample-depositor/scripts/finalize-withdrawal.ts
```

The script waits for the proof (up to `PROOF_TIMEOUT_MS`, default 60 min), simulates `executeBundle`, sends it,
and checks that the bundle is `FullyExecuted`. The recipient then holds the tokens on L1.

## Limitations

- Only ZK chains whose base token is ETH are supported: the depositor pays the L2 gas with the ETH sent along.
- If the L2 leg of a deposit fails, the tokens are claimable on L1 through `L1Nullifier.claimFailedDeposit` and
  are returned to the depositor contract; `SampleDepositor.withdrawToken` lets the owner move them out.
- The contracts are examples: single owner, no pausing, no accounting beyond the ERC20 balances.
