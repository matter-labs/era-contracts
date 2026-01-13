# General guidelines

## Solidity Code Rules

**CRITICAL: Never use try-catch or staticCall in Solidity code**
- Do NOT use `try`/`catch` blocks for error handling
- Do NOT use low-level `staticcall`, `call`, or `delegatecall`
- If a function might not exist or could revert, refactor the code to avoid calling it
- Use proper interface checks, conditional logic, or restructure the code instead
- If the function was introduced in a new version, query the protocol version from the ChainTypeManager or the Diamond proxy

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