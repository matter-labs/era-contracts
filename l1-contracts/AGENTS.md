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