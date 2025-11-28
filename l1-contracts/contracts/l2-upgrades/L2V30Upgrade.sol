// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Storage slot with the admin of the contract used for EIP‑1967 proxies (e.g., TUP, BeaconProxy, etc.).
bytes32 constant PROXY_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @title L2V31Upgrade, contains v31 upgrade fixes.
/// @dev This contract is neither predeployed nor a system contract. It resides in this folder to facilitate code reuse.
/// @dev This contract is called during the forceDeployAndUpgrade function of the ComplexUpgrader system contract.
contract L2V31Upgrade {
    /// @notice Executes the one‑time migration/patch.
    /// @dev Intended to be delegate‑called by the `ComplexUpgrader` contract.
    /// @param _baseTokenOriginChainId The chainId of the origin chain of the base token.
    /// @param _baseTokenOriginAddress The address of the base token on the origin chain.
    function upgrade(uint256 _baseTokenOriginChainId, address _baseTokenOriginAddress) external {
        // kl todo set baseTokenOriginChainId and baseTokenOriginAddress in some location.
        // kl todo add all setAddresses, initL2 and updateL2s from genesis upgrade.
    }
}
