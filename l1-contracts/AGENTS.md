# General guidelines

## ⚠️ CRITICAL SOLIDITY CODE RULES ⚠️

### NEVER USE try-catch OR staticcall

**THIS IS AN ABSOLUTE RULE - NO EXCEPTIONS**

❌ **FORBIDDEN PATTERNS:**

```solidity
// NEVER DO THIS:
try contract.someFunction() returns (address result) {
    // ...
} catch {
    return address(0);
}

// NEVER DO THIS:
(bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature("someFunction()"));
if (ok) {
    return abi.decode(data, (address));
}

// NEVER DO THIS:
address result = _tryAddress(target, "someFunction()");
```

✅ **CORRECT APPROACH:**

- If a function reverts, it means the contract is not properly initialized or the script is being called at the wrong time
- Do NOT try to "handle" or "catch" reverts - fix the root cause instead
- If you think you need try-catch or staticcall, you are solving the wrong problem
- Query protocol version, check initialization state, or restructure when the script runs

**WHY THIS RULE EXISTS:**

- try-catch and staticcall hide real errors instead of fixing them
- These patterns make debugging extremely difficult
- They mask initialization issues and timing problems
- The codebase should fail fast and clearly, not silently return defaults

## Debugging Strategies

When debugging Solidity compilation or script failures:

1. **Read Error Messages Carefully**
   - Look for "Member X not found" or "Identifier not found" errors
   - Check if interfaces are properly imported
   - Verify struct field names match between definitions and usage

2. **Check Contract Versions**
   - Functions may not exist in all versions of a contract
   - Query protocol version before calling version-specific functions
   - Check git history to see when functions were added/removed

3. **Verify Interface Implementations**
   - Ensure contracts implement required interfaces
   - Check function signatures match interface declarations
   - Add missing interface implementations if needed

4. **Trace Import Paths**
   - Verify all imports resolve correctly
   - Check for typos in import paths
   - Ensure imported contracts/interfaces exist

5. **Fix Struct/Type Mismatches**
   - Check struct field names in definitions vs usage
   - Verify types match (e.g., `assetRouter` vs `chainAssetHandler`)
   - Look at the actual struct definition in Types.sol or similar files

6. **Test Incrementally**
   - Fix one error at a time
   - Rebuild after each fix to catch new errors
   - Use forge script traces to see where execution fails

- If the function was introduced in a new version, query the protocol version from the ChainTypeManager or the Diamond proxy.

## Running Foundry Tests

### Installing foundry-zksync

The tests require `foundry-zksync` (ZKSync's fork of Foundry) to be installed. Download the specific version used in CI:

```bash
mkdir ./foundry-zksync
curl -LO https://github.com/matter-labs/foundry-zksync/releases/download/foundry-zksync-v0.0.30/foundry_zksync_v0.0.30_linux_amd64.tar.gz
tar zxf foundry_zksync_v0.0.30_linux_amd64.tar.gz -C ./foundry-zksync
chmod +x ./foundry-zksync/forge ./foundry-zksync/cast
rm foundry_zksync_v0.0.30_linux_amd64.tar.gz
export PATH="$PWD/foundry-zksync:$PATH"
```

### Building Artifacts

Before running tests, build all required artifacts from the repository root:

```bash
# Build da-contracts
yarn da build:foundry

# Build l1-contracts
yarn l1 build:foundry

# Build system-contracts
yarn sc build:foundry

# Build l2-contracts
yarn l2 build:foundry
```

### Running Tests

```bash
# Run l1-contracts foundry tests
cd l1-contracts
yarn test:foundry

# Run system-contracts foundry tests
cd system-contracts
yarn test:foundry
```

### Common Issues

1. **Missing zkout files**: If tests fail with "zkout/BeaconProxy.sol/BeaconProxy.json not found", ensure you've built all artifacts with the steps above.

2. **Config lock errors**: Some tests may fail with "Can't acquire config lock". This is usually a transient issue - try running the tests again.

3. **L1-context vs L2-context tests**: Tests in `l2-tests-in-l1-context` run L2 logic in an L1 environment. Some L2 system contract features may not work as expected in these tests, so assertions should account for this limitation.

4. **zkstack-out artifacts out of date**: If CI fails with "l1-contracts/zkstack-out is out of date", you need to regenerate the compiled artifacts. This happens when you modify interface files (e.g., adding events, functions). Run:

   ```bash
   cd l1-contracts
   forge build
   npx ts-node scripts/copy-to-zkstack-out.ts
   cd ..
   yarn prettier:fix  # Required to add trailing newlines to JSON files
   ```

   Then commit the updated JSON files in `zkstack-out/`.

5. **Selectors out of date**: If CI fails with selectors check, regenerate them:

   ```bash
   cd l1-contracts
   yarn selectors --fix
   ```

   Then commit the updated `selectors` file.

## Before Pushing Changes

**ALWAYS run linting and formatting before pushing to ensure CI passes:**

### Running Linting and Formatting

From the repository root:

```bash
# Fix Solidity linting issues
yarn lint:sol --fix --noPrompt

# Fix TypeScript linting issues
yarn lint:ts --fix

# Fix formatting issues
yarn prettier:fix
```

### Pre-Push Checklist

1. **Run linting fixes**: `yarn lint:sol --fix --noPrompt && yarn lint:ts --fix && yarn prettier:fix`
2. **Run foundry tests**: `cd l1-contracts && yarn test:foundry`
3. **Verify no uncommitted changes**: `git status`
4. **Commit and push**: Only after all checks pass

### Common Linting Issues

1. **Line length**: Solidity lines should not exceed the configured max length
2. **Import ordering**: Imports may need to be reordered
3. **Trailing whitespace**: Will be fixed by prettier
4. **Missing or extra newlines**: Will be fixed by prettier

## Git Best Practices

### Never Force Push

**Do NOT use `--force`, `--force-with-lease`, or `git push -f`**

- Always use regular `git push`
- If you need to make additional changes, create a new commit instead of amending
- Force pushing rewrites history and can cause issues for others working on the same branch

❌ **FORBIDDEN:**

```bash
git commit --amend
git push --force
git push --force-with-lease
git push -f
```

✅ **CORRECT:**

```bash
git commit -m "Fix: additional changes"
git push
```
