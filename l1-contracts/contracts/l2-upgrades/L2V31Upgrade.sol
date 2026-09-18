// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V31AcrossRecovery} from "./V31AcrossRecovery.sol";
import {IL2V31Upgrade} from "../upgrades/IL2V31Upgrade.sol";
import {IL2NativeTokenVault} from "../bridge/ntv/IL2NativeTokenVault.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {ZeroAddress} from "../common/L1ContractErrors.sol";
import {
    FixedForceDeploymentsData,
    ZKChainSpecificForceDeploymentsData
} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";
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
        bytes memory additionalForceDeploymentsData = _additionalForceDeploymentsData;
        if (!_isZKsyncOS) {
            // EraSettlementLayerV31Upgrade leaves the old NTV code in place for this read.
            address wethToken = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).WETH_TOKEN();
            require(wethToken != address(0), ZeroAddress());
            FixedForceDeploymentsData memory fixedData = abi.decode(
                _fixedForceDeploymentsData,
                (FixedForceDeploymentsData)
            );
            ZKChainSpecificForceDeploymentsData memory chainData = abi.decode(
                additionalForceDeploymentsData,
                (ZKChainSpecificForceDeploymentsData)
            );
            chainData.predeployedL2WethAddress = wethToken;
            additionalForceDeploymentsData = abi.encode(chainData);
            L2GenesisForceDeploymentsHelper.forceDeployEra(fixedData.l2NtvBytecodeInfo, L2_NATIVE_TOKEN_VAULT_ADDR);
        }

        acrossRecovery();

        // Standard non-genesis initialization of all L2 system contracts.
        // This calls updateL2() on NTV, Bridgehub, AssetRouter, etc. with
        // the correct L1-provided values — no circular reads.
        // solhint-disable-next-line func-named-parameters
        L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
            _isZKsyncOS,
            _ctmDeployer,
            _fixedForceDeploymentsData,
            additionalForceDeploymentsData,
            false // isGenesisUpgrade
        );
    }
}
