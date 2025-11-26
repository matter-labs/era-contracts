## Security issues

### 1. `PermanentRestriction.allowL2Admin` is permissionless, letting anyone whitelist L2 admins

- **Severity**: High  
- **Impact**: Any address (including a malicious/compromised chain admin) can unilaterally whitelist arbitrary future L2 admin contracts as valid migration targets. This bypasses the intended governance control around which L2 admins are acceptable when migrating a chain to an L2 settlement layer, and can undermine “permanent” security properties (e.g. rollup guarantees) after migration.

**Details**

In `PermanentRestriction`:

```solidity
/// @notice Whitelists a certain L2 admin.
/// @param deploymentNonce The deployment nonce of the `L2_ADMIN_FACTORY` used for the deployment.
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

This function is **not** restricted by `onlyOwner` or any other access control — it is fully permissionless.

However, the whitelist it populates is used to gate migrations to an L2 settlement layer:

```solidity
function validateCall(
    Call calldata _call,
    address // _invoker
) external view override {
    _validateAsChainAdmin(_call);
    _validateMigrationToL2(_call);
    _validateRemoveRestriction(_call);
}

function _validateMigrationToL2(Call calldata _call) private view {
    (address admin, bool isMigration) = _getNewAdminFromMigration(_call);
    if (isMigration) {
        if (!allowedL2Admins[admin]) {
            revert NotAllowed(admin);
        }
    }
}
```

So, any call detected as a “migration to L2” passes the restriction as long as `allowedL2Admins[admin] == true`, where `admin` is the new admin on the settlement layer, extracted from the encoded Bridgehub request.

Whitelisted addresses are not checked for code or contents here; the only property enforced is that the address must have been *computable* from `(L2_ADMIN_FACTORY, deploymentNonce)` via `L2ContractHelper.computeCreateAddress`. Since `L2AdminFactory.deployAdmin` is itself permissionless, any user can drive its nonce forward and deploy arbitrary admins (modulo the factory’s fixed `requiredRestrictions`).

**Attack scenario**

Assume a chain uses `PermanentRestriction` to constrain admin behavior and manage safe migrations:

1. Governance deploys a canonical `L2_ADMIN_FACTORY` and configures `PermanentRestriction` to point to it via `L2_ADMIN_FACTORY`. The intent is that governance (as `owner`) controls which L2 admins are acceptable migration targets.
2. A malicious chain admin or any external attacker:
   - On L2, calls `L2AdminFactory.deployAdmin(_additionalRestrictions)` as many times as desired, obtaining admin addresses deterministically derived from factory nonce.
   - On L1, calls `PermanentRestriction.allowL2Admin(deploymentNonce)` for the corresponding nonces. This succeeds because there is no access control.
3. Now `allowedL2Admins[admin] == true` for those admins, even though governance never approved them.
4. The chain admin initiates a migration to an L2 settlement layer, specifying one of these whitelisted admins as the new L2 admin.
5. `_validateMigrationToL2` sees the admin in `allowedL2Admins` and **does not revert**, so the migration proceeds using an L2 admin that governance did not explicitly approve.

Consequences:

- Governance loses control over which L2 admin contracts can be used on migration.
- A malicious chain admin can choose an L2 admin with configuration or additional restrictions that weaken or defeat the intended permanent security properties.
- This is particularly at odds with the documented goal of `PermanentRestriction` as a tool to “guarantee that certain security properties are preserved forever” and to constrain migrations.

Even if the `L2AdminFactory`’s `requiredRestrictions` are safe, governance is effectively sidelined from the approval process for specific L2 admin instances, which is not what the restriction appears to intend.

**Recommendation**

- Restrict `allowL2Admin` to the owner (governance):

  ```solidity
  function allowL2Admin(uint256 deploymentNonce) external onlyOwner {
      ...
  }
  ```

- Optionally, add a sanity check that the computed address is already deployed and looks like a `ChainAdmin` instance with the expected code hash, to avoid pre‑whitelisting undeployed addresses:

  ```solidity
  address expectedAddress = L2ContractHelper.computeCreateAddress(L2_ADMIN_FACTORY, deploymentNonce);
  require(expectedAddress.code.length != 0, "Admin not deployed yet");
  ```

- Consider adding a way for the owner to **revoke** an accidentally whitelisted L2 admin, e.g.,

  ```solidity
  function revokeL2Admin(address admin) external onlyOwner { ... }
  ```

This preserves the intended role of decentralized governance in controlling which L2 admins are acceptable migration targets, and restores the effectiveness of `PermanentRestriction` for chains that opt into using it.


---

### 2. `ForceDeployUpgrader` exposes unrestricted `forceDeploy` – dangerous if ever deployed as-is

- **Severity**: Informational  
- **Impact**: If this contract were deployed and used directly (instead of being inherited into a properly access‑controlled upgrader), *any* account could instruct the L2 `DEPLOYER_SYSTEM_CONTRACT` to force‑deploy arbitrary contracts at arbitrary addresses, compromising system integrity.

**Details**

`ForceDeployUpgrader` in `l2-contracts`:

```solidity
contract ForceDeployUpgrader {
    /// @notice A function that performs force deploy
    /// @param _forceDeployments The force deployments to perform.
    function forceDeploy(ForceDeployment[] calldata _forceDeployments) external payable {
        IContractDeployer(DEPLOYER_SYSTEM_CONTRACT).forceDeployOnAddresses{value: msg.value}(_forceDeployments);
    }
}
```

This function has **no** access control: any caller can trigger system-level forced deployments via `IContractDeployer.forceDeployOnAddresses`.

The file comment says:

> It is supposed to be used inherited by an implementation of the ComplexUpgrader. (but it is not useful in itself)

So the intention is that:

- A separate `ComplexUpgrader` contract inherits `ForceDeployUpgrader`.
- That `ComplexUpgrader` **adds authorization checks** (e.g. `onlyForceDeployer` or `onlyGovernance`) around calls to `forceDeploy`.

However, nothing in the code prevents a project or integrator from accidentally:

- Deploying `ForceDeployUpgrader` directly and assigning it a privileged system address, or
- Using it as a generic “upgrader” without wrapping it with access control.

In such a misconfiguration, any account could perform arbitrary force deployments, which is catastrophic for L2 security.

This is not an issue in the current code path as long as:

- `ForceDeployUpgrader` is never deployed at a privileged address, and
- Only a properly access‑controlled `ComplexUpgrader` is actually used in production (as is the case with `L2ComplexUpgrader` in the L1 contracts).

**Recommendation**

To make misuse harder and more obvious:

- Mark `ForceDeployUpgrader` as `abstract` so it cannot be deployed on its own:

  ```solidity
  abstract contract ForceDeployUpgrader { ... }
  ```

- Or, at minimum, add strong documentation comments stating that it must not be deployed or used directly, and that any concrete upgrader must wrap `forceDeploy` with strict access control.

This is a defensive design improvement to prevent accidental unsafe deployments by third parties reusing the code.


---

## Open issues / areas needing additional context

The following behaviors are assumed safe based on typical zkSync/system‑contract patterns, but cannot be fully validated from the provided snippets alone:

1. **System contracts guarding ComplexUpgrader usage**

   - `L2ComplexUpgrader` is restricted to `onlyForceDeployer` (`msg.sender == L2_FORCE_DEPLOYER_ADDR`), and many initialization flows rely on being called via delegatecall from it.
   - To be sure that arbitrary L2 users cannot trigger upgrades, we would need the implementations of:
     - The L2 **ForceDeployer system contract** at `L2_FORCE_DEPLOYER_ADDR`.
     - The L2 **ContractDeployer system contract** at `L2_DEPLOYER_SYSTEM_CONTRACT_ADDR` (implementing `IL2ContractDeployer`).

2. **Access control on `SystemContext.setChainId`**

   - `L2GenesisUpgrade.genesisUpgrade` calls `ISystemContext(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR).setChainId(_chainId)` without any local access control, relying on the system contract to enforce its own checks.
   - To confirm that only the intended upgrader path can change the chainId, we would need the code for `ISystemContext` at `L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR`.

3. **Internal access control of L2 system contracts**

   Several helper functions delegate into L2 system contracts that are assumed to be tightly access‑controlled, e.g.:

   - `SystemContractProxyAdmin.forceSetOwner` (`onlyUpgrader` → `msg.sender == L2_COMPLEX_UPGRADER_ADDR`).
   - `SystemContractProxy.forceInitAdmin`.
   - Various `initL2` / `updateL2` / `setAddresses` calls on `L2Bridgehub`, `L2NativeTokenVault`, `InteropCenter`, etc.

   From the snippets, calls to these are only made in contexts where `address(this)` is expected to be `L2_COMPLEX_UPGRADER_ADDR` via delegatecall, but to fully validate there’s no misuse from other callers, we would need the concrete implementations of those contracts.

4. **`ReentrancyGuard` initializer semantics**

   - `ServerNotifier.initialize` is guarded with `reentrancyGuardInitializer` instead of OZ’s `initializer`. We have assumed that `reentrancyGuardInitializer` enforces one‑time initialization semantics (e.g. `_status == 0` → `_status = _NOT_ENTERED`) so `initialize` cannot be called multiple times.
   - To confirm this, we would need `../common/ReentrancyGuard.sol`.

None of these open points look like direct vulnerabilities from the provided code, but they are important for end‑to‑end assurance of the governance and upgrade flows.