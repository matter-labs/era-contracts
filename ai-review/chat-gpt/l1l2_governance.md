## Security issues

No Critical, High, or Medium‑severity vulnerabilities were identified in the reviewed governance & upgrade contracts under the documented assumptions. The main patterns (timelock/governance, ChainAdmin restrictions, L1↔L2 upgrade flows) are generally sound.

Below are some low / informational findings and design caveats.

---

### 1. `ServerNotifier.initialize` relies only on `reentrancyGuardInitializer` (non‑standard upgradeable pattern)

- **Severity**: Informational  
- **Impact**: If the custom `ReentrancyGuard.reentrancyGuardInitializer` modifier ever changed semantics or is misunderstood by integrators, `ServerNotifier.initialize` could become callable more than once, allowing the contract owner to be arbitrarily reset and compromising access control for all `onlyOwner` / `onlyChainAdmin` functions. In the current codebase this *likely* works as intended (single‑use), but that guarantee comes from a contract not included in the provided scope.

**Details**

`ServerNotifier` uses OpenZeppelin’s `Ownable2Step` and `Initializable`, but its initializer is:

```solidity
contract ServerNotifier is Ownable2Step, ReentrancyGuard, Initializable {
    ...

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract by setting the initial owner.
    /// @param _initialOwner The address that will be set as the contract owner.
    function initialize(address _initialOwner) public reentrancyGuardInitializer {
        if (_initialOwner == address(0)) {
            revert ZeroAddress();
        }
        _transferOwnership(_initialOwner);
    }
}
```

Key points:

- `initialize` is **not** marked with OZ’s `initializer` / `reinitializer` modifier.
- The only guard against repeated calls is `reentrancyGuardInitializer`, whose implementation is in `common/ReentrancyGuard.sol` (not provided here).
- The constructor calls `_disableInitializers()`, which protects only functions annotated with `initializer`/`reinitializer` and does not affect `initialize` here.

If `reentrancyGuardInitializer` is implemented as the usual pattern:

```solidity
modifier reentrancyGuardInitializer() {
    require(_status == 0, "already initialized");
    _status = _NOT_ENTERED;
    _;
}
```

then the current design is safe (only the first call to `initialize` can succeed). If it’s ever refactored or reused differently, `initialize` could be left unprotected.

**Recommendation**

- Prefer the canonical OZ pattern for upgradeable contracts:

  ```solidity
  function initialize(address _initialOwner) public initializer {
      __ReentrancyGuard_init(); // or equivalent
      _transferOwnership(_initialOwner);
  }
  ```

- If keeping the custom pattern, add explicit comments and tests asserting that:
  - `reentrancyGuardInitializer` enforces exactly‑once semantics, and
  - repeated calls to `initialize` revert.

---

### 2. `ForceDeployUpgrader.forceDeploy` has no access control and relies entirely on system contract checks

- **Severity**: Informational  
- **Impact**: If the underlying system contract `IContractDeployer.forceDeployOnAddresses` does **not** restrict its callers, any deployment of `ForceDeployUpgrader` as a live contract would allow arbitrary users to perform privileged “force deployments” on L2, potentially overwriting contracts or violating upgrade assumptions. Current deployments presumably rely on `IContractDeployer` itself enforcing strict authorization (e.g., only bootloader / upgrade system), but that contract is out of scope here.

**Details**

```solidity
contract ForceDeployUpgrader {
    /// @notice A function that performs force deploy
    /// @param _forceDeployments The force deployments to perform.
    function forceDeploy(ForceDeployment[] calldata _forceDeployments) external payable {
        IContractDeployer(DEPLOYER_SYSTEM_CONTRACT).forceDeployOnAddresses{value: msg.value}(_forceDeployments);
    }
}
```

There is:

- No `onlySystem` / `onlyGovernance` modifier.
- No inline access control; it is fully delegated to `IContractDeployer`.

The comment says this contract “is supposed to be used inherited by an implementation of the ComplexUpgrader (but it is not useful in itself)”, which suggests:

- It is intended as a mixin, not as a directly deployed contract.
- Access control is expected to be added in the inheriting contract **or** enforced by `DEPLOYER_SYSTEM_CONTRACT`.

Without seeing `DEPLOYER_SYSTEM_CONTRACT`’s implementation, we cannot confirm that arbitrary calls to `forceDeployOnAddresses` from non‑system contracts will revert.

**Recommendation**

- Treat this contract as **library‑only**: do not deploy it standalone.
- In any concrete upgrader that inherits `ForceDeployUpgrader`, add explicit access control (e.g., `onlyForceDeployer` or `onlyGovernance`).
- Optionally, make `forceDeploy` `internal` instead of `external` to prevent accidental direct deployment and use.
- Confirm (out of scope here) that `IContractDeployer.forceDeployOnAddresses` itself enforces the expected caller checks.

---

### 3. Permissionless L2 admin whitelisting in `PermanentRestriction.allowL2Admin` (storage bloat / governance hygiene)

- **Severity**: Informational  
- **Impact**: Anyone can call `allowL2Admin` to pre‑whitelist arbitrary numbers of *potential* L2 admin addresses (constrained to those derivable from `L2_ADMIN_FACTORY` and a nonce ≤ `MAX_ALLOWED_NONCE`). This does not break security invariants of `PermanentRestriction`, but it can grow the `allowedL2Admins` mapping unboundedly, slightly increasing state size and long‑term maintenance costs.

**Details**

```solidity
mapping(address adminAddress => bool isWhitelisted) public allowedL2Admins;

function allowL2Admin(uint256 deploymentNonce) external {
    if (deploymentNonce > MAX_ALLOWED_NONCE) {
        revert TooHighDeploymentNonce();
    }

    address expectedAddress = L2ContractHelper.computeCreateAddress(L2_ADMIN_FACTORY, deploymentNonce);

    if (allowedL2Admins[expectedAddress]) {
        revert AlreadyWhitelisted(expectedAddress);
    }

    allowedL2Admins[expectedAddress] = true;
    emit AllowL2Admin(expectedAddress);
}
```

Characteristics:

- No `onlyOwner` or other restriction: any address can whitelist L2 admins.
- The whitelisted admin must equal `computeCreateAddress(L2_ADMIN_FACTORY, deploymentNonce)`, which:
  - Strongly ties it to the L2 admin factory, and
  - Makes it computationally infeasible to whitelist an arbitrary unrelated address without breaking `CREATE` address derivation (Keccak collision).
- `MAX_ALLOWED_NONCE = 2**48` bounds the theoretical search space, but in practice an attacker could still spam many nonces.

Because lookup in a mapping is O(1), the primary impact is storage growth and archival bloat, not a direct security break.

**Recommendation**

- If you want stricter control over which L2 admins can ever be used, consider:
  - Adding an optional `onlyOwner` gate, or
  - Introducing a “whitelister” role.
- If permissionless registration is desired for decentralization, keep as‑is but be aware of the long‑term state growth implications.

---

## Safe‑by‑design notes

These are potentially sensitive areas that are implemented safely given the documented design:

1. **ChainAdmin modular access control**

   - `ChainAdmin.multicall` is intentionally *not* access‑controlled:
     ```solidity
     function multicall(Call[] calldata _calls, bool _requireSuccess) external payable nonReentrant {
         ...
         _validateCall(_calls[i]); // runs all active Restriction contracts via staticcall
         (bool success, bytes memory returnData) = _calls[i].target.call{value: _calls[i].value}(_calls[i].data);
         ...
     }
     ```
   - Access control is delegated to `Restriction` contracts (e.g., `AccessControlRestriction`, `PermanentRestriction`) which are statically called before each low‑level call.
   - Static calls mean restrictions cannot mutate state (including `activeRestrictions`) during validation, preventing dynamic bypass.

2. **Governance timelock & self‑upgrade invariants**

   - Operations must be scheduled via `scheduleTransparent` / `scheduleShadow` (`onlyOwner`) and must respect `minDelay` enforced in `_schedule`.
   - `updateDelay` and `updateSecurityCouncil` are `onlySelf`, meaning:
     ```solidity
     modifier onlySelf() {
         if (msg.sender != address(this)) {
             revert Unauthorized(msg.sender);
         }
         _;
     }
     ```
     They can only be invoked through a *governance operation* that calls the contract itself from within `_execute`, and thus still pass through the timelock.
   - Reentrancy into `execute`/`executeInstant` is prevented by access control: external calls inside `_execute` have `msg.sender == address(this)`, which does not satisfy `onlyOwnerOrSecurityCouncil` unless misconfigured (owner/securityCouncil set to the contract itself, which would be an explicit governance decision).

3. **PermanentRestriction immutability enforcement**

   - When changing the admin of a ZK chain, only implementations whose `codehash` is explicitly whitelisted in `allowedAdminImplementations` are accepted.
   - Additionally, the new admin must report this restriction as active:
     ```solidity
     if (!IChainAdmin(newChainAdmin).isRestrictionActive(address(this))) {
         revert RemovingPermanentRestriction();
     }
     ```
   - Attempts by a `ChainAdmin` to remove this restriction via `removeRestriction` are blocked by `_validateRemoveRestriction`, which keys off `msg.sender == _call.target == ChainAdmin` during validation. Because `validateCall` is invoked via `staticcall`, `msg.sender` is deterministically the calling `ChainAdmin` contract.

4. **Use of `onlyForceDeployer` in `L2ComplexUpgrader`**

   - All upgrade entrypoints are gated:
     ```solidity
     modifier onlyForceDeployer() {
         if (msg.sender != L2_FORCE_DEPLOYER_ADDR) {
             revert Unauthorized(msg.sender);
         }
         _;
     }
     ```
   - This ensures complex L2 upgrades (force deployments + delegatecalls) can only be triggered by the designated system `FORCE_DEPLOYER` contract, not by arbitrary user code.
   - Delegatecalls are checked for code presence (`_delegateTo.code.length != 0`), avoiding delegatecall to EOA/empty accounts.

5. **ETH/accounting behavior in `Governance` and admin contracts**

   - `Governance.execute` / `executeInstant`, `ChainAdmin.multicall`, and `ChainAdminOwnable.multicall` use explicit `{value: _calls[i].value}` for each subcall and propagate failures when required.
   - None of these tie per‑call `value` to `msg.value`; they spend from the contract’s total ETH balance, which is expected and consistent with typical admin/timelock patterns.
   - `AccessControlRestriction` explicitly documents that it does not protect ETH balances; callers with privileges can move ETH held by `ChainAdmin`, which is by design.

---

## Open issues / external dependencies

These are points that depend on contracts not included in the scope and should be confirmed separately:

1. **`ReentrancyGuard.reentrancyGuardInitializer` semantics**

   - Needed to fully confirm that `ServerNotifier.initialize` (and other upgradeable contracts using this pattern) are strictly single‑use initializers.
   - Source required: `l1-contracts/contracts/common/ReentrancyGuard.sol`.

2. **`IContractDeployer.forceDeployOnAddresses` authorization**

   - To determine whether `ForceDeployUpgrader` is safe even if deployed as a standalone contract, we need to know what caller checks `DEPLOYER_SYSTEM_CONTRACT` enforces.
   - Source required: implementation of `IContractDeployer` / the Deployer system contract from `@matterlabs/zksync-contracts` and the exact constant `DEPLOYER_SYSTEM_CONTRACT` in `L2ContractHelper.sol`.

3. **System contract behaviors during L2 upgrades**

   - Correctness of `L2GenesisForceDeploymentsHelper` and `L2GenesisUpgrade` also depends on:
     - `L2Bridgehub`, `L2AssetRouter`, `L2NativeTokenVault(ZKOS)`, `L2MessageRoot`, `L2AssetTracker`, `GWAssetTracker`, `L2ChainAssetHandler`, `InteropHandler`, and
     - The system contract addresses in `L2ContractAddresses`.
   - These are treated as trusted, but any deviation from the documented semantics (init/update/setAddresses behavior) could impact upgrade safety.

Within the provided sources and documentation, no concrete exploitable vulnerabilities in the L1/L2 governance and upgrade paths were identified.