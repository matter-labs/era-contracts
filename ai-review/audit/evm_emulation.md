## Security issues

### 1. `CALL` gas accounting diverges from Ethereum (stipend and base cost not charged)

- **Severity**: Low  
- **Impact**: For `CALL` with non‑zero `value`, the emulator undercharges the caller: it forwards the correct amount of gas to the callee (including the 2300 stipend) but does not deduct the stipend or the 700 base `CALL` cost from the caller’s emulated gas. Over many value‑transferring calls this can make `gasleft()` inside emulated EVM contracts significantly larger than it would be on Ethereum, changing control flow and allowing operations (including late `SSTORE`s or additional calls/loops) that would be out‑of‑gas on L1 to succeed on zkSync.

**Details**

The relevant code is in `EvmEmulator.yul` and is identical in the `_deployed` variant:

```yul
function performCall(oldSp, evmGasLeft, oldStackHead, isStatic) -> newGasLeft, sp, stackHead {
    ...
    let addr, gasUsed := _genericPrecallLogic(rawAddr, argsOffset, argsSize, retOffset, retSize)

    if gt(value, 0) {
        if isStatic {
            panic()
        }

        gasUsed := add(gasUsed, 9000) // positive_value_cost

        if isAddrEmpty(addr) {
            gasUsed := add(gasUsed, 25000) // value_to_empty_account_cost
        }
    }

    evmGasLeft := chargeGas(evmGasLeft, gasUsed)
    gasToPass := capGasForCall(evmGasLeft, gasToPass)
    evmGasLeft := sub(evmGasLeft, gasToPass)

    if gt(value, 0) {
        gasToPass := add(gasToPass, 2300)
    }

    let success, frameGasLeft := _genericCall(
        addr,
        gasToPass,
        value,
        add(argsOffset, MEM_OFFSET()),
        argsSize,
        add(retOffset, MEM_OFFSET()),
        retSize,
        isStatic
    )

    newGasLeft := add(evmGasLeft, frameGasLeft)
    stackHead := success
}
```

Key observations:

1. **Base `CALL` cost (700 gas) is never charged.**  
   The only costs accounted in `gasUsed` are:
   - memory expansion via `_genericPrecallLogic` (`expandMemory2`)
   - address warm/cold access (100 or 2600)
   - `positive_value_cost` (9000) when `value > 0`
   - `value_to_empty_account_cost` (25000) when sending to an empty account  

   Standard EVM `G_call` (= 700) is missing entirely.

2. **The 2300 stipend is not charged to the caller.**

   - After computing `gasToPass` using `capGasForCall(evmGasLeft, gasToPass)` (which implements the 63/64 rule), the emulator does:
     ```yul
     evmGasLeft := sub(evmGasLeft, gasToPass)

     if gt(value, 0) {
         gasToPass := add(gasToPass, 2300)
     }
     ```
   - Crucially, **the 2300 stipend is added to `gasToPass` but never subtracted from `evmGasLeft`.**
   - When the call returns:
     ```yul
     newGasLeft := add(evmGasLeft, frameGasLeft)
     ```
     `frameGasLeft` is the callee’s remaining EVM gas (including any unused part of the stipend). The caller recovers that remaining gas, but **never pays for what the callee spent from the stipend.**

3. **Effect: caller “mints” up to 2300 EVM gas per value‑transferring call.**

   Consider:
   - `value > 0`
   - `gas` argument = 0 (so `gasToPass` before stipend is 0)
   - callee uses little or no gas from the stipend

   Then:
   - Environment cost (`gasUsed`) is correctly charged (memory + 9000 + warm/cold + optional 25000).
   - `evmGasLeft` is not reduced by the 2300 stipend, only by `gasUsed`.
   - The callee receives 2300 gas; unspent gas is returned via `frameGasLeft`.
   - Net effect per call: caller’s `evmGasLeft` is **higher by up to 2300** compared to Ethereum, while the callee still saw the full stipend.

   Over `N` such calls, the emulator’s `evmGasLeft` inside the emulated contract can exceed the true Ethereum value by roughly `N * 2300` gas (minus whatever the callees actually spend from the stipend). Combined with the missing 700 base cost, the divergence per call is substantial.

4. **This directly affects `OP_GAS` and all later gas checks.**

   - `OP_GAS` is implemented as:
     ```yul
     case 0x5A { // OP_GAS
         evmGasLeft := chargeGas(evmGasLeft, 2)
         sp, stackHead := pushStackItem(sp, evmGasLeft, stackHead)
         ip := add(ip, 1)
     }
     ```
   - So the emulated contract observes the inflated `evmGasLeft` via `gasleft()`.

5. **Potential security implications**

   While this does not let a user mint *actual* L2 gas (native `gas()` is still the ultimate limit), it has real semantic consequences for EVM contracts:

   - **Gas‑gated logic can differ from Ethereum.**  
     Code that branches or guards writes on `gasleft()` can take a different branch on zkSync than it would on Ethereum:
     - e.g. “if `gasleft() < THRESHOLD` then revert/safe‑path” checks.
     - bounded loops that rely on running out of gas to stop additional work.
   - **Late `SSTORE`s / state changes that should OOG may succeed.**  
     Because SSTORE enforces `evmGasLeft >= 2301`:
     ```yul
     case 0x55 { // OP_SSTORE
         if isStatic { panic() }
         if lt(evmGasLeft, 2301) { panic() }
         ...
     }
     ```
     an emulated contract can still have `evmGasLeft >= 2301` on zkSync in situations where the same call sequence on Ethereum would have already dropped below that threshold due to proper charging of stipend + base call cost.
   - **Call-depth / recursion patterns that rely on specific gas budgets could differ**, potentially enabling deeper recursion or more external calls than on Ethereum.

   These are **behavioural differences**, not raw gas‑DoS: the actual L2 node is still bounded by native gas. But such behavioural differences can undermine security assumptions in contracts that *intentionally* rely on gas for safety.

**Recommendation**

- Align `CALL` gas accounting with the Ethereum Yellow Paper / EIP‑150 semantics:

  - Add the missing **700 base gas** for `CALL` (and `STATICCALL` / `DELEGATECALL` as appropriate) to `gasUsed` before calling `chargeGas`.
  - When `value > 0`, ensure the **2300 stipend is charged to the caller’s `evmGasLeft`**. One concrete approach in this design:
    - Run `capGasForCall` and subtract `gasToPass` from `evmGasLeft` as today.
    - If `value > 0`, increment both:
      - `gasToPass := add(gasToPass, 2300)`
      - and **also** deduct `2300` from `evmGasLeft` (with a check that there is enough gas to pay the stipend).
    - This preserves correct forwarding to the callee while making the caller pay for all gas the callee can consume.

- After changing accounting, re‑validate:
  - `OP_GAS` behaviour,
  - `CREATE` / `CREATE2` call paths (they eventually use `_genericCall`),
  - and precompile handling (`callPrecompile`) against the reference gas costs.

- If for protocol reasons you deliberately choose to deviate from Ethereum’s call gas semantics, document this explicitly as a **non‑equivalence** and call out that `gasleft()` and OOG boundaries for `CALL` with non‑zero `value` differ from Ethereum, so developers should not rely on precise gas behaviour for safety‑critical logic.


## Open questions / areas needing more context

These are not reported as vulnerabilities, but correctness relies on external components we did not review:

1. **Classification of contracts by `versionedBytecodeHash`**
   - `EvmGasManager.$llvm_AlwaysInline_llvm$_onlyEvmSystemCall` checks that the caller is an “EVM contract” by:
     ```yul
     let versionedCodeHash := $llvm_AlwaysInline_llvm$__getRawSenderCodeHash()
     isEVM := eq(shr(248, versionedCodeHash), 2)
     ```
   - We assume `EvmEmulator` / `EvmEmulator_deployed` have the appropriate `version` set so they can interact with `EvmGasManager`.  
   - To fully validate, we would need:
     - The definition of `versionedBytecodeHash` format in `AccountCodeStorage`.
     - Deployment configuration for the emulator contracts.

2. **MsgValueSimulator and Ether accounting**
   - The emulator relies on `MsgValueSimulator` via `rawCall` and `performSystemCallForCreate` to enforce that context `msg.value` and real L2 balances match.
   - We have not reviewed `MsgValueSimulator.sol` or its interaction with native `context.set_context_u128` / far calls.
   - To validate value semantics end‑to‑end, we would need:
     - The `MsgValueSimulator` contract source,
     - The VM spec for how value/context is plumbed through far calls (`context.set_context_u128` / `context.get_context_u128`).

3. **Bootloader and CODE_ORACLE correctness**
   - `EvmEmulator_deployed.getDeployedBytecode` assumes that `CODE_ORACLE_SYSTEM_CONTRACT` and `getCodeAddress()` supply the correct bytecode for the currently executing EVM account.
   - Any inconsistency there would break emulation, but this is outside the provided scope.
   - Full validation would require:
     - Bootloader and CodeOracle implementations,
     - The formal definition of the `code_source` verbatim instruction.

These open points do not represent identified bugs in the presented code, but they are critical dependencies for the overall correctness of EVM emulation.