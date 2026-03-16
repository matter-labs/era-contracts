Regenerate zkstack-out artifacts and selectors after interface changes.

## When to use

Run this skill when:
- You modified a Solidity interface file (added/removed functions, events, errors)
- CI fails with "l1-contracts/zkstack-out is out of date"
- CI fails with "Selectors file does not match computed selectors"
- You added a new contract that needs to be available in zkstack_cli

## What gets regenerated

1. **zkstack-out/** - Extracted ABIs from Forge build output, used by:
   - `zkstack_cli` Rust binary (via `abigen!` macro for type-safe bindings)
   - Anvil interop test suite (TypeScript ABI imports)

2. **selectors** - Function selector list computed from compiled contracts

## Steps

1. **Build all contracts:**
   ```bash
   cd l1-contracts && forge build
   ```

2. **Regenerate zkstack-out artifacts:**
   ```bash
   cd l1-contracts && npx ts-node scripts/copy-to-zkstack-out.ts
   ```

3. **Format the generated JSON files** (required - CI checks for trailing newlines):
   ```bash
   cd .. && yarn prettier:fix
   ```

4. **Regenerate selectors:**
   ```bash
   cd l1-contracts && yarn selectors --fix
   ```

5. **Show what changed:**
   ```bash
   git status -- l1-contracts/zkstack-out l1-contracts/selectors
   git diff --stat -- l1-contracts/zkstack-out l1-contracts/selectors
   ```

## If adding a new contract to zkstack-out

If a new contract needs to be available in zkstack-out:

1. Read `l1-contracts/scripts/copy-to-zkstack-out.ts`
2. Add the contract filename to the `REQUIRED_CONTRACTS` array
3. Add a comment noting whether it's for `zkstack_cli` or `anvil-interop`
4. Re-run the regeneration steps above

## Notes
- The `yarn build:foundry` command combines forge build + copy-to-zkstack-out in one step
- zkstack-out contains ONLY the ABI arrays, not full Forge artifacts
- Selectors file must match byte-for-byte in CI (strict comparison)
- Always commit both zkstack-out/ and selectors changes together
