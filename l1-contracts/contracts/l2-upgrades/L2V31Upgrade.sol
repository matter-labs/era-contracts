// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L2_BASE_TOKEN_SYSTEM_CONTRACT} from "../common/l2-helpers/L2ContractAddresses.sol";

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
    /// @param _isZkSyncOS Whether this chain is running zkSync OS (true) or Era VM (false).
    // solhint-disable-next-line no-unused-vars
    function upgrade(uint256 _baseTokenOriginChainId, address _baseTokenOriginAddress, bool _isZkSyncOS) external {
        // TODO: set baseTokenOriginChainId and baseTokenOriginAddress in some location.
        // TODO: add all setAddresses, initL2 and updateL2s from genesis upgrade.

        // Initialize the BaseTokenHolder balance in L2BaseToken.
        // This is only needed on zkSync OS chains where the BaseTokenHolder approach is used.
        // Era VM chains use a different mechanism and don't need this initialization.
        if (_isZkSyncOS) {
            L2_BASE_TOKEN_SYSTEM_CONTRACT.initializeBaseTokenHolderBalance();
        }
    }
}
