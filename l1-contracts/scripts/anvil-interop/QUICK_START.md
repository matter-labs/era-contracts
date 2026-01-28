# Quick Start Guide

## Setup (One Time)

1. **Build contracts:**
   ```bash
   cd /path/to/contracts/l1-contracts
   forge build
   ```

2. **Navigate to anvil-interop:**
   ```bash
   cd scripts/anvil-interop
   ```

## Running the Stack

### Option A: All at Once (Recommended)
```bash
yarn step:all
```

This runs steps 1-5 automatically with proper error handling.

### Option B: Step by Step
```bash
yarn step1  # Start Anvil chains
yarn step2  # Deploy L1 contracts
yarn step3  # Register L2 chains
yarn step4  # Initialize L2 (L2GenesisUpgrade with isZKsyncOS=true)
yarn step5  # Setup gateway
```

## Testing L2→L2 Messaging

```bash
# Basic test (chain 11 → chain 12)
yarn send:l2-to-l2

# Custom parameters
yarn send:l2-to-l2 [sourceChainId] [targetChainId] [targetAddress] [calldata]
```

## Cleanup

```bash
yarn cleanup
```

Stops all Anvil processes and cleans up deployment state.

## Quick Check

**Verify everything is running:**
```bash
# Check Anvil processes
ps aux | grep anvil

# Check PIDs file
cat outputs/anvil-pids.json

# Check deployment state
ls outputs/state/
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "L2 chains not found" | Run `yarn step1` first |
| step:all stops at step1 | **FIXED** - now uses detached processes |
| "Could not read [Contract]" | Run `forge build` first |
| Transaction reverted | Check gas limit (should be 50M), verify L1 deployed |

## Key Changes

- ✅ **Anvil processes now stay running** after step1 exits
- ✅ **Uses L2GenesisUpgrade** with `isZKsyncOS = true`
- ✅ **Normal solc bytecodes** from `out/` directory
- ✅ **PID tracking** for process management
- ✅ **step:all works correctly** now

## What's Next?

After successful setup:
- `yarn step6` - Start the settler daemon
- `yarn test:interop` - Run interop tests
- `yarn deploy:test-token` - Deploy test ERC20 token
- `yarn send:token` - Send token transfers

---

For detailed technical information, see:
- `FIXED_L2_SETUP.md` - Complete changelog
- `L2_GENESIS_UPGRADE_CHANGES.md` - Technical details
