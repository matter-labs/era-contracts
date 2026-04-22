# Contracts Development Guidelines

## Anvil-Interop Testing

### NEVER Inline ABI Tuple Type Strings

**THIS IS AN ABSOLUTE RULE - NO EXCEPTIONS**

ABI tuple type strings (e.g., `"tuple(uint256 foo, address bar)"`) must always be defined as named constants
in the appropriate constants file (e.g., `const.ts`), never inlined at usage sites.

❌ **FORBIDDEN PATTERNS:**

```typescript
abiCoder.encode(
  ["tuple(bytes32 assetId, address token, string name)"],
  [...]
);
```

✅ **CORRECT APPROACH:**

```typescript
// In const.ts:
export const MY_DATA_TUPLE_TYPE = "tuple(bytes32 assetId, address token, string name)";

// At usage site:
abiCoder.encode([MY_DATA_TUPLE_TYPE], [...]);
```

**WHY THIS RULE EXISTS:**

- Tuple types must match Solidity struct definitions exactly; a single constant makes mismatches easy to spot
- Multiple inline copies drift out of sync when structs change
- Named constants document which Solidity struct the encoding corresponds to
