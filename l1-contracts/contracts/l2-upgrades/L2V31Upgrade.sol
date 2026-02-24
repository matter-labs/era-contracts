// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {IL2BaseTokenBase} from "../l2-system/interfaces/IL2BaseTokenBase.sol";
import {V31AcrossRecovery} from "./V31AcrossRecovery.sol";
import {IL2V31Upgrade} from "../upgrades/IL2V31Upgrade.sol";

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @title L2V31Upgrade, contains v31 upgrade fixes.
/// @dev This contract is neither predeployed nor a system contract. It resides in this folder to facilitate code reuse.
/// @dev This contract is called during the forceDeployAndUpgrade function of the ComplexUpgrader system contract.
contract L2V31Upgrade is V31AcrossRecovery, IL2V31Upgrade {
    /// @inheritdoc IL2V31Upgrade
    function upgrade(uint256, address) external {
        acrossRecovery();
        // kl todo set baseTokenOriginChainId and baseTokenOriginAddress in some location.
        // kl todo add all setAddresses, initL2 and updateL2s from genesis upgrade.

        // Initialize the BaseTokenHolder balance in L2BaseToken.
        IL2BaseTokenBase(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).initializeBaseTokenHolderBalance();
    }
}
