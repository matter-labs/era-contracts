Run the full pre-push checklist to ensure CI will pass.

## What this skill does

Runs all linting, formatting, artifact regeneration, and tests that CI checks. Fixes issues automatically where possible.

## Steps

Run these commands sequentially from the contracts repository root:

1. **Fix Solidity linting:**
   ```bash
   yarn lint:sol --fix --noPrompt
   ```

2. **Fix TypeScript linting:**
   ```bash
   yarn lint:ts --fix
   ```

3. **Fix formatting (prettier):**
   ```bash
   yarn prettier:fix
   ```

4. **Rebuild and regenerate zkstack-out artifacts** (only if Solidity interfaces were modified):
   ```bash
   cd l1-contracts && yarn build:foundry
   ```

5. **Regenerate selectors** (only if Solidity interfaces were modified):
   ```bash
   cd l1-contracts && yarn selectors --fix
   ```

6. **Run foundry tests:**
   ```bash
   cd l1-contracts && yarn test:foundry
   ```

7. **Check for remaining uncommitted changes:**
   ```bash
   git status
   ```

## After completion

Report to the user:
- Which steps passed/failed
- If any auto-fixes were applied (linting, formatting)
- If zkstack-out or selectors were regenerated
- Test results summary
- Whether there are uncommitted changes that need to be committed

## Notes
- Steps 4-5 can be skipped if only TypeScript or test files were modified (no Solidity interface changes)
- If foundry tests fail, investigate the failure rather than skipping
- Redirect long test output to a file to avoid buffer blocking
- NEVER force push after fixing issues - create new commits
