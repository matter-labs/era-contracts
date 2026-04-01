// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L2_ASSET_TRACKER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {L2AssetTracker} from "../bridge/asset-tracker/L2AssetTracker.sol";
import {IL2AssetTracker} from "../bridge/asset-tracker/IL2AssetTracker.sol";
import {IL2BaseTokenBase} from "../l2-system/interfaces/IL2BaseTokenBase.sol";
import {V31AcrossRecovery} from "./V31AcrossRecovery.sol";
import {IL2V31Upgrade} from "../upgrades/IL2V31Upgrade.sol";
import {L2GenesisForceDeploymentsHelper} from "./L2GenesisForceDeploymentsHelper.sol";

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @title L2V31Upgrade, contains v31 upgrade fixes.
/// @dev This contract is neither predeployed nor a system contract. It resides in this folder to facilitate code reuse.
/// @dev This contract is called during the forceDeployAndUpgrade function of the ComplexUpgrader system contract.
contract L2V31Upgrade is V31AcrossRecovery, IL2V31Upgrade {
    /// @inheritdoc IL2V31Upgrade
    function upgrade(
        bool _isZKsyncOS,
        address _ctmDeployer,
        bytes calldata _fixedForceDeploymentsData,
        bytes calldata _additionalForceDeploymentsData
    ) external {
        acrossRecovery();

        // Standard non-genesis initialization of all L2 system contracts.
        // This calls updateL2() on NTV, Bridgehub, AssetRouter, etc. with
        // the correct L1-provided values — no circular reads.
        // solhint-disable-next-line func-named-parameters
        L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
            _isZKsyncOS,
            _ctmDeployer,
            _fixedForceDeploymentsData,
            _additionalForceDeploymentsData,
            false // isGenesisUpgrade
        );

        // V31-specific: register base token in the new AssetTracker.
        IL2AssetTracker(L2_ASSET_TRACKER_ADDR).registerBaseTokenDuringUpgrade();

        // V31-specific: initialize BaseToken (sets L1_CHAIN_ID and BaseTokenHolder balance).
        // This is normally only called during genesis, but for v31 we need it for existing
        // chains because L2BaseToken is a new contract.
        IL2BaseTokenBase(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).initL2(
            L2AssetTracker(L2_ASSET_TRACKER_ADDR).L1_CHAIN_ID()
        );
    }
}
