Project: contracts
Scope: L1/L2 misc (common, L2 aux) (l1l2_misc)

## Security issues

### 1. Unprotected `forceDeploy` allows unauthorized system contract upgrades
- **Title**: Missing Access Control in `ForceDeployUpgrader.forceDeploy`
- **Severity**: Critical
- **Impact**: If this contract is deployed as the `ComplexUpgrader` (or inherited without override), any user can call `forceDeploy` to overwrite any L2 system contract (via the `ContractDeployer`), effectively taking control of the L2 chain.
- **Description**: The contract `ForceDeployUpgrader` contains the function `forceDeploy` which is marked `external` and accepts an array of `ForceDeployment` instructions. It forwards these instructions to the `DEPLOYER_SYSTEM_CONTRACT` using `forceDeployOnAddresses`.
  
  ```solidity
  function forceDeploy(ForceDeployment[] calldata _forceDeployments) external payable {
      IContractDeployer(DEPLOYER_SYSTEM_CONTRACT).forceDeployOnAddresses{value: msg.value}(_forceDeployments);
  }
  ```

  The `DEPLOYER_SYSTEM_CONTRACT` typically restricts calls to `forceDeployOnAddresses` to specific privileged addresses (e.g., `FORCE_DEPLOYER` or `COMPLEX_UPGRADER`). If `ForceDeployUpgrader` is deployed at one of these privileged addresses (e.g., `L2_COMPLEX_UPGRADER_ADDR`), it acts as a proxy. However, `ForceDeployUpgrader.forceDeploy` lacks any access control (such as `onlyBootloader` or `onlyOwner`). Consequently, any user can call this function, which in turn calls the Deployer with the privileged identity of the `ForceDeployUpgrader` contract, bypassing the Deployer's security checks.

### 2. `TestnetPaymaster` Vulnerable to ETH Draining via Malicious Tokens
- **Title**: Arbitrary Token Validation in `TestnetPaymaster` allows ETH draining
- **Severity**: High
- **Impact**: An attacker can drain all ETH liquidity from the Paymaster, causing a Denial of Service for legitimate testnet users who rely on it for gas sponsorship.
- **Description**: The `TestnetPaymaster` is intended to pay for transaction fees (in ETH) in exchange for user tokens. However, the validation logic blindly trusts the token address provided in the `paymasterInput` without verifying if it is a supported or valuable token.
  
  ```solidity
  (address token, uint256 amount, ) = abi.decode(_transaction.paymasterInput[4:], (address, uint256, bytes));
  // ...
  // Pulling all the tokens from the user
  try IERC20(token).transferFrom(userAddress, thisAddress, amount) {} catch ...
  // ...
  (bool success, ) = payable(BOOTLOADER_ADDRESS).call{value: requiredETH}("");
  ```
  
  An attacker can:
  1. Create a malicious ERC20 token where `transferFrom` always returns true but transfers no value (or use a worthless token).
  2. Submit a transaction using this token as the fee token in `paymasterInput` with a sufficiently high `amount`.
  3. The Paymaster executes `transferFrom` (which succeeds).
  4. The Paymaster then pays real ETH to the `BOOTLOADER_ADDRESS` to cover the transaction gas.
  
  This allows the attacker to execute transactions for free at the expense of the Paymaster's ETH balance.

### 3. Potential DoS in `ConsensusRegistry` due to Unbounded Loop
- **Title**: Unbounded iteration in `getValidatorCommittee`
- **Severity**: Low
- **Impact**: Reading the validator committee may become gas-prohibitive if the number of historical validator owners grows significantly, potentially affecting off-chain monitoring or on-chain integrations that rely on this view.
- **Description**: The `ConsensusRegistry` contract maintains an array `validatorOwners`. The function `_getCommittee` (used by `getValidatorCommittee`) iterates over the entire `validatorOwners` array to filter active validators.
  
  ```solidity
  uint256 len = validatorOwners.length;
  for (uint256 i = 0; i < len; ++i) {
      // ... logic checks ...
  }
  ```
  
  While the `remove` function marks validators as removed, it does not immediately remove them from the array (cleanup only happens on subsequent modifications via `_getValidatorAndDeleteIfRequired`). If the owner (trusted multisig) adds many validators over time, this loop grows. Since it is a view function, the impact is limited, but it represents a scalability bottleneck.