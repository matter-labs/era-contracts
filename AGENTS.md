# General guidelines

## NEVER kill Anvil processes globally

**THIS IS AN ABSOLUTE RULE - NO EXCEPTIONS**

Never run `pkill -f anvil`, `killall anvil`, or any blanket kill command for Anvil processes. Multiple Anvil sessions may be running in parallel (e.g., interop tests, local development chains). Killing all Anvil processes can destroy other users' or sessions' work.

Instead, use the `cleanup.sh` script in the anvil-interop directory, which targets only processes on known ports.

## Code style requirements

1. Avoid using magic numbers. Most constant numbers especially for system params / well known chain ids must be represented as a constant.
2. All constants should be placed in the dedicated file (e.g. `common/Config.sol` in `l1-contracts`, `Constants.sol` in `system-contracts`, etc). if you do not know where to put the constant to, please closely analyze the corresponding project. If this file can not be found, please create one.
3. Function parameters must be prefixed with `_` (e.g. `_value`, `_owner`). This convention applies to all functions across all contracts.
4. Always use `{ }` for `if` blocks — never inline the body (`if (cond) revert X();` is forbidden; write `if (cond) { revert X(); }`). The same applies to `for`/`while` bodies.
5. Never write doc comments (`///` natspec) for custom errors — error files contain only the `// 0x<selector>` lines maintained by the errors lint. Put any rationale at the revert site instead. When a new file with errors is added, it MUST be registered in the errors lint (`CONTRACTS_DIRECTORIES` in `l1-contracts/scripts/errors-lint.ts`) and `yarn errors-lint --fix` must be run.

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

### NEVER Override Storage Slots in Tests

**THIS IS AN ABSOLUTE RULE - NO EXCEPTIONS**

❌ **FORBIDDEN PATTERNS:**

- `anvil_setStorageAt` to set contract state
- Any direct manipulation of storage slots to bypass contract logic

✅ **CORRECT APPROACH:**

- Use real contract calls and flows to achieve the desired state
- If a flow requires multiple steps (e.g., Token Balance Migration), implement all steps properly
- If a relay transaction fails, fix the root cause instead of setting storage directly

**WHY THIS RULE EXISTS:**

- Storage slot overrides hide real bugs in the test setup
- They make tests fragile and tightly coupled to storage layout
- Real flows validate that the contracts work correctly end-to-end
- Storage layouts change between versions, silently breaking tests

### NEVER Declare ABIs Inline in TypeScript

**THIS IS AN ABSOLUTE RULE - NO EXCEPTIONS**

❌ **FORBIDDEN PATTERNS:**

```typescript
// NEVER DO THIS:
const someAbi = ["function someMethod(uint256 param) view returns (address)"];
const contract = new Contract(addr, someAbi, provider);
```

✅ **CORRECT APPROACH:**

- Always import ABIs from the centralized `contracts.ts` file (or equivalent ABI module)
- If an ABI doesn't exist yet, add it to `contracts.ts` and import it

**WHY THIS RULE EXISTS:**

- Inline ABIs are duplicated across files and easily go out of sync with actual contracts
- Centralized ABIs are easier to maintain and update when contracts change
- Import-based ABIs provide a single source of truth

### Constructors and Immutables

- ONLY contracts deployed on L1 should have immutables. Contracts on L2 are deployed within zksync os environment and so and so DO NOT SUPPORT CONSTRUCTORS ALL (and so no immutable can be set). It is important that the `*Base` contracts that the L2 contracts inherit from dont have immutables or constructors too.
- If you want to add an immutable for L1, always double check whether it is possible to deterministically obtain from other contracts.
- If there is variable that can be an immutable on L1, but we need a similar field on L2, a common pattern is to create a method in the base contract that can be inherited by both. On L2 it can be either a constant (esp if it is an L2 built-in contract address) or a storage variable that must be initialized within during the genesis. For example, look how `initL2` functions are used.

## Documentation and Comments

AI-generated code tends to over-explain: huge doc comments that restate the protocol, repeat themselves, and carry a high noise-to-signal ratio. The rules below exist to keep every piece of information described **exactly once**, in the right place.

### Single source of truth: `protocol-docs/`

- The protocol (flows, motivations, security arguments, design trade-offs) is described in markdown files under `protocol-docs/`.
- Every piece of information must be described once if possible. If the motivation for a function's behavior is already described in the protocol docs, reference it as `{protocol-docs/<path>.md}` instead of restating it.
- When adding a feature whose design/motivation is not yet in `protocol-docs/`, add it there — do not write it into contract comments instead.

### Doc comments (natspec)

- Contract and function doc comments consist of a `@notice` with a high-level summary plus `@param` descriptions (and `@return` where useful). That's it.
- Anything inherited from an interface **MUST** use `/// @inheritdoc` — never copy the interface docs into the implementation.
- `@dev` comments and inline comments are allowed, but they must only describe implementation or UX gotchas (things a reader of _this code_ would trip over) — never protocol motivation or behavior descriptions that belong in `protocol-docs/` or in the function's own `@notice`.

### Never re-describe a function at its call sites

A very common AI failure mode: the behavior of a new function `X` gets described not only in `X`'s own doc comment, but again in the doc comments of every function that calls `X`, and again inline right where the call happens.

- Describe what a function does **only** in its own doc comment. At call sites, rely on the reader following the call to the definition and reading the docs there.
- A call-site comment is justified only for a genuine local gotcha (e.g., ordering constraints with surrounding code, a surprising argument choice) — not for what the callee does.

### Never explain the language

Do not write comments that explain how Solidity works, or that pre-empt a misreading of a line that reads
correctly on its own. Typical offenders: "this is a memory reference, so the write is visible to the
caller", "this is a no-op when the value is already set", "note that this loop is bounded". Reviewers know
the language; these comments only add bulk. Comment the protocol decision or the local gotcha, not the
mechanics of the statement in front of you.

### SDKs, tests, scripts

- Test files, dev tooling, deploy scripts, and SDK code follow the same rules: point to `protocol-docs/` for protocol context instead of restating it in comments.

## Testing Guidelines

All PRs that include feature work, bug fixes, or behavioral changes **MUST** follow these testing requirements.

### Test Structure

Every test **MUST** have proper structure:

- Relevant storage changes **MUST** be asserted.
- Relevant event emissions **MUST** be asserted.
- Relevant logic asserts **MUST** be in place.
- Other relevant side effects **MUST** be asserted.
- Tests **MUST** validate outcomes — not just execute calls.
- Only **relevant** effects need to be checked; there is no need to check every storage write, event emission, etc.

### Coverage Requirements

- Any feature PR **MUST** include tests for happy, unhappy, and edge-case paths.
  - Happy and unhappy path coverage should be straightforward for PR owners and reviewers to verify.
  - Edge-case testing is best effort: PR owners and reviewers should try their best to ensure good coverage, but it is acknowledged that sometimes not all edge cases can be anticipated.
- Ideally, testing should include fuzz and invariant tests where possible. Different testing approaches lead to flexibility and thorough coverage.
- Total coverage **MUST NOT** decrease after any PR.
  - In rare extraordinary cases (e.g., splitting contracts into L1/L2 counterparts) where maintaining coverage would require disproportionate work relative to PR size, this requirement can be discussed on an individual basis. Such cases should be very rare.

### Mocks

- Mocks **MUST** only be used when the intention is to separate concerns or isolate components.
- Mocks should **not** be used as a convenience shortcut to simplify setup when triggering the full execution flow is feasible.
- It should be clear from comments in the test why mocks are being used. The test writer should clearly denote that the file or test is expected to be isolated from the part of the flow being mocked.

### Regression Tests

- Every bug found through audits or the bug bounty program **MUST** have a regression test.
- If the bug is not yet publicly known, consult with the security team before including the regression test to determine appropriate timing.

### Readability

Tests **MUST** be readable for both humans and AI:

- Follow a clear folder structure: separate folders for contracts, separate test files for sections of a contract or logic blocks.
- Add comments for non-trivial tests, especially edge cases and complex flows. Missing context is easily recovered by a few well-placed comments.
- Any guideline deviation (use of mocks, missing checks, etc.) should be explicitly explained in the test.
- Structure tests and the overall codebase to be AI-friendly: keep things clean, avoid complicated structures, and include in-code documentation. AI usage is increasing, and investing effort into clarity pays off.

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

### Running Anvil Interop Tests

```bash
cd l1-contracts

# Run with pre-generated chain states (fastest, ~180s)
yarn test:hardhat:interop

# Use port offset to avoid conflicts with other Anvil instances
ANVIL_INTEROP_PORT_OFFSET=100 yarn test:hardhat:interop

# Force fresh deployment (skips pre-generated states, ~330s)
ANVIL_INTEROP_FRESH_DEPLOY=1 yarn test:hardhat:interop

# Keep chains running after tests (for debugging with cast)
ANVIL_INTEROP_KEEP_CHAINS=1 yarn test:hardhat:interop
```

After modifying mock system contracts (e.g., `MockL2ToL1Messenger`, `MockMintBaseTokenHook`), regenerate chain states:

```bash
cd l1-contracts
forge build
cd test/anvil-interop
npx ts-node setup-and-dump-state.ts
```

### Common Issues

1. **Missing zkout files**: If tests fail with "zkout/BeaconProxy.sol/BeaconProxy.json not found", ensure you've built all artifacts with the steps above.

2. **Config lock errors**: Some tests may fail with "Can't acquire config lock". This is usually a transient issue - try running the tests again.

3. **L1-context vs L2-context tests**: Tests in `l2-tests-in-l1-context` run L2 logic in an L1 environment. Some L2 system contract features may not work as expected in these tests, so assertions should account for this limitation.

4. **zkstack-out artifacts out of date**: If CI fails with "l1-contracts/zkstack-out is out of date", you need to regenerate the compiled artifacts. This happens when you modify interface files (e.g., adding events, functions). Run:

   ```bash
   cd l1-contracts
   forge build
   yarn copy-to-zkstack-out.ts
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

## PR Description Maintenance

Whenever an agent makes changes in a PR, it **MUST** update the PR description to reflect the current state of the changes and ensure it is up to date. If the PR already has a description with existing styling or wording, the agent **MUST** follow that same style and tone when updating it.

## Git Best Practices

### Pushing and Creating PRs

Agents do **not** have push access to the main repository. Always push to a **fork** and create PRs from there. Do not attempt to push directly to `matter-labs/era-contracts`.

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
