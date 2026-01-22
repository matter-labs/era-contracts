# Multi-Chain Anvil Testing Environment

A TypeScript-based testing environment that sets up a complete multi-chain ZKsync interoperability stack with:
- 4 Anvil chains (1 L1 + 3 L2s)
- Full L1 contract deployment
- 3 registered L2 chains with initialized system contracts
- 1 L2 designated as Gateway
- Automated batch settlement daemon

## Architecture

```
┌─────────────┐
│   L1 (9545) │ ← Bridgehub, CTM, SharedBridge
└──────┬──────┘
       │
       ├─────► L2 Chain 10 (4050)
       │
       ├─────► L2 Chain 11 (4051) [Gateway]
       │
       └─────► L2 Chain 12 (4052)
```

## File Structure

```
scripts/anvil-interop/
├── src/
│   ├── anvil-manager.ts      # Manage Anvil process lifecycle
│   ├── deployer.ts            # Execute Foundry deployment scripts
│   ├── chain-registry.ts      # Register and initialize L2 chains
│   ├── gateway-setup.ts       # Designate Gateway chain
│   ├── batch-settler.ts       # Batch settlement daemon
│   ├── types.ts               # TypeScript interfaces
│   └── utils.ts               # Helper functions
├── config/
│   ├── anvil-config.json      # Anvil chain configurations
│   ├── l1-deployment.toml     # L1 deployment parameters
│   └── ctm-deployment.toml    # ChainTypeManager config
├── outputs/                   # Deployment outputs (generated)
├── index.ts                   # Main orchestrator
├── package.json
├── tsconfig.json
└── README.md
```

## Prerequisites

- Node.js 18+
- Foundry (forge, anvil)
- Yarn or npm

## Installation

```bash
cd scripts/anvil-interop
yarn install
# or
npm install
```

## Usage

### Start the Environment

```bash
yarn start
# or
npm start
```

This will:
1. Start 4 Anvil chains (L1 + 3 L2s)
2. Deploy L1 core contracts (Bridgehub, SharedBridge, etc.)
3. Deploy and register ChainTypeManager
4. Register 3 L2 chains
5. Initialize L2 system contracts on each chain
6. Designate chain 11 as Gateway
7. Start the batch settlement daemon

### Stop the Environment

Press `Ctrl+C` to gracefully shut down all chains and the batch settler.

### Reset/Cleanup the Environment

If you encounter errors like `NativeTokenVaultAlreadySet` or want to start fresh:

```bash
yarn cleanup
# or
npm run cleanup
```

This will:
- Stop all running Anvil instances
- Remove all deployment outputs
- Reset permanent values
- Clean up broadcast files from Forge

**When to use cleanup:**
- Before starting a fresh deployment run
- After encountering deployment errors
- When testing configuration changes
- If contracts seem to be in an inconsistent state

## Components

### 1. Anvil Manager (`src/anvil-manager.ts`)

Manages the lifecycle of Anvil processes:
- Starts Anvil instances on configured ports
- Performs health checks via RPC
- Handles graceful shutdown
- Provides access to JsonRpcProvider instances

### 2. Deployer (`src/deployer.ts`)

Executes Foundry deployment scripts:
- Deploys L1 core contracts via `DeployL1CoreContracts.s.sol`
- Deploys ChainTypeManager via `DeployCTMIntegration.s.sol`
- Registers CTM with Bridgehub via `RegisterCTM.s.sol`
- Parses TOML outputs to extract deployed addresses

### 3. Chain Registry (`src/chain-registry.ts`)

Registers L2 chains and initializes system contracts:
- Generates chain-specific TOML configs
- Executes `RegisterZKChain.s.sol` for each L2
- Initializes L2 system contracts via `requestL2TransactionDirect()`
- Deploys: L2Bridgehub, L2AssetRouter, L2NativeTokenVault

### 4. Gateway Setup (`src/gateway-setup.ts`)

Designates one L2 as the Gateway chain:
- Deploys GatewayCTMDeployer
- Registers Gateway CTM with L1 Bridgehub
- Executes `GatewayPreparation.s.sol`
- Sets up Gateway-specific infrastructure

### 5. Batch Settler (`src/batch-settler.ts`)

Automated daemon for batch settlement:
- Polls L2 chains for new blocks/transactions
- Aggregates transactions into batches
- Commits batches to L1 (`commitBatchesSharedBridge`)
- Proves batches with mock proofs (`proveBatchesSharedBridge`)
- Executes batches on L1 (`executeBatchesSharedBridge`)
- Emulates EthSender/EthWatcher behavior

**Batch Settlement Flow:**
```
L2 Txs → Pending → Commit → Prove → Execute
         (10 txs)   (L1)     (L1)     (L1)
```

## Configuration

### Anvil Chains (`config/anvil-config.json`)

```json
{
  "chains": [
    { "chainId": 1, "port": 9545, "isL1": true },
    { "chainId": 10, "port": 4050, "isL1": false },
    { "chainId": 11, "port": 4051, "isL1": false, "isGateway": true },
    { "chainId": 12, "port": 4052, "isL1": false }
  ],
  "batchSettler": {
    "pollingIntervalMs": 5000,
    "batchSizeLimit": 10
  }
}
```

### L1 Deployment (`config/l1-deployment.toml`)

Contains parameters for L1 contract deployment:
- Governance addresses
- Security council
- Validator timelock settings
- Verifier configuration

### CTM Deployment (`config/ctm-deployment.toml`)

Contains ChainTypeManager parameters:
- Chain admin address
- Genesis state commitments
- Protocol version
- Verifier address

## Verification Steps

### Check L1 Deployment

```bash
# Query Bridgehub for registered CTM
cast call <BRIDGEHUB_ADDR> "getStateTransitionManager(uint256)" <CHAIN_ID> --rpc-url http://127.0.0.1:9545
```

### Check Chain Registration

```bash
# Query Bridgehub for registered chain
cast call <BRIDGEHUB_ADDR> "getZKChain(uint256)" <CHAIN_ID> --rpc-url http://127.0.0.1:9545
```

### Check L2 System Contracts

```bash
# Query L2 for deployed contract
cast call <CONTRACT_ADDR> "someFunction()" --rpc-url http://127.0.0.1:4050
```

### Check Batch Settlement

Monitor logs for batch settlement activity:
```
📊 Chain 10: Processing blocks 1 to 10
📝 Committing batch for chain 10...
✅ Batch 1 committed for chain 10
🔍 Proving batch for chain 10...
✅ Batch 1 proved for chain 10
⚡ Executing batch for chain 10...
✅ Batch 1 executed for chain 10
```

## Testing

### Submit a Test Transaction

```bash
# Send ETH on L2 chain
cast send <TO_ADDR> --value 1ether --private-key <KEY> --rpc-url http://127.0.0.1:4050
```

The batch settler will automatically:
1. Detect the new transaction
2. Add it to the pending batch
3. Commit the batch once 10 txs accumulate (or after timeout)
4. Prove and execute the batch on L1

### Test L1→L2 Deposit

```bash
# Use Bridgehub to deposit to L2
cast send <BRIDGEHUB_ADDR> "requestL2TransactionDirect(...)" --rpc-url http://127.0.0.1:9545
```

### Test L2→L1 Withdrawal

Submit withdrawal transaction on L2, then wait for batch execution to finalize on L1.

## Troubleshooting

### Anvil Won't Start

- Check if ports are already in use: `lsof -i :9545`
- Kill existing Anvil processes: `pkill anvil` or run `yarn cleanup`

### Forge Script Fails

- Run `yarn cleanup` to reset the environment
- Check TOML config paths in environment variables
- Verify Foundry is installed: `forge --version`
- Check script output in `outputs/` directory

### NativeTokenVaultAlreadySet Error

This error occurs when running the deployment multiple times without cleaning up Anvil state.

**Solution:** Run `yarn cleanup` before starting again

### Batch Settler Not Working

- Verify L2 chains are producing blocks
- Check executor interface matches deployed contracts
- Ensure private key has sufficient balance on L1

### RPC Connection Issues

- Wait for chains to fully start (health checks)
- Verify RPC URLs match Anvil output
- Check for port conflicts

## Continuous Integration

### CI Workflow

The project includes a GitHub Actions workflow (`.github/workflows/anvil-interop-ci.yaml`) that automatically tests the environment on every pull request.

**What the CI checks:**
- TypeScript type checking
- Build compilation
- File structure verification
- Configuration file validation
- Foundry tools availability (Anvil, Forge)

**Running CI locally:**
```bash
# Type check
npx tsc --noEmit

# Build
yarn build

# Verify structure
ls -R src/ config/
```

The CI workflow runs automatically when:
- Pull requests modify files in `l1-contracts/scripts/anvil-interop/`
- Changes are pushed to the `main` branch

**Optional Integration Test:**

The workflow includes a commented-out integration test that can be enabled to:
- Build all contract artifacts
- Start the full Anvil environment
- Verify chains are responding

To enable, uncomment the `integration-test` job in the workflow file.

## Development

### Build TypeScript

```bash
yarn build
```

### Clean Outputs

```bash
# Remove build artifacts only
yarn clean

# Full cleanup (stops Anvil, removes outputs, resets state)
yarn cleanup
```

### Modify Chain Configuration

Edit `config/anvil-config.json` to:
- Add more L2 chains
- Change ports
- Adjust batch settler parameters

### Extend Functionality

- Add more deployment scripts to `deployer.ts`
- Implement L1→L2 message relay in `batch-settler.ts`
- Add monitoring/metrics collection

## Architecture Notes

### Why Mock Proofs?

The batch settler uses mock zero-knowledge proofs for local testing. Real proofs require:
- Specialized proving hardware
- Circuit setup ceremony artifacts
- Significant computation time

For local development, mock proofs allow rapid iteration without proof generation overhead.

### Batch Settlement Timing

Current settings:
- Poll interval: 5 seconds
- Batch size: 10 transactions

Adjust in `config/anvil-config.json` based on testing needs.

### Memory Considerations

Running 4 Anvil instances + batch settler daemon:
- Approximate memory: 500MB-1GB
- Disk space: Minimal (no persistent state)

## References

- ZKsync Era L1 Contracts: `/contracts`
- Deployment Scripts: `/deploy-scripts`
- Integration Tests: `/test/foundry/l1/integration`
- IExecutor Interface: `/contracts/state-transition/chain-interfaces/IExecutor.sol`

## License

MIT
