// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V31AcrossRecovery} from "./V31AcrossRecovery.sol";
import {IL2V31Upgrade} from "../upgrades/IL2V31Upgrade.sol";
import {L2GenesisForceDeploymentsHelper} from "./L2GenesisForceDeploymentsHelper.sol";
import {
    FixedForceDeploymentsData,
    ZKChainSpecificForceDeploymentsData
} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";

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

        // V31-specific: initialize contracts that are new in v31
        // (AssetTracker, GWAssetTracker, InteropHandler, L2BaseToken, base token registration).
        FixedForceDeploymentsData memory fixedData = abi.decode(
            _fixedForceDeploymentsData,
            (FixedForceDeploymentsData)
        );
        ZKChainSpecificForceDeploymentsData memory additionalData = abi.decode(
            _additionalForceDeploymentsData,
            (ZKChainSpecificForceDeploymentsData)
        );
        // solhint-disable-next-line func-named-parameters
        L2GenesisForceDeploymentsHelper.initializeV31Contracts(
            _isZKsyncOS,
            false, // isGenesisUpgrade
            fixedData,
            additionalData
        );
    }
}
