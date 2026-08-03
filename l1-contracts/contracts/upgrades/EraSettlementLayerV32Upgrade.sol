// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SettlementLayerV32UpgradeBase} from "./SettlementLayerV32UpgradeBase.sol";
import {IL2ContractDeployer} from "../common/interfaces/IL2ContractDeployer.sol";
import {IComplexUpgrader} from "../state-transition/l2-deps/IComplexUpgrader.sol";
import {L2UpgradeTxLib} from "./L2UpgradeTxLib.sol";
import {Bytes} from "../vendor/Bytes.sol";

/// @author Matter Labs
/// @title EraSettlementLayerV32Upgrade
/// @dev This release's upgrade for Era (EraVM) chains, i.e. for a chain moving from v31. Handles the
/// Era-style ComplexUpgrader.forceDeployAndUpgrade(ForceDeployment[], address, bytes) format; the L1-side
/// work it does (and deliberately does not do) lives in {SettlementLayerV32UpgradeBase}.
/// @custom:security-contact security@matterlabs.dev
contract EraSettlementLayerV32Upgrade is SettlementLayerV32UpgradeBase {
    using Bytes for bytes;

    /// @inheritdoc SettlementLayerV32UpgradeBase
    function getL2UpgradeTxData(
        address _bridgehub,
        uint256 _chainId,
        bool _zksyncOS,
        bytes memory _existingTxData
    ) public view override returns (bytes memory) {
        L2UpgradeTxLib.validateZKsyncOSFlag(_zksyncOS, false);
        L2UpgradeTxLib.validateUpgradeSelector(_existingTxData, IComplexUpgrader.forceDeployAndUpgrade.selector);

        (
            IL2ContractDeployer.ForceDeployment[] memory forceDeployments,
            address delegateTo,
            bytes memory existingUpgradeCalldata
        ) = abi.decode(_existingTxData.slice(4), (IL2ContractDeployer.ForceDeployment[], address, bytes));

        L2UpgradeTxLib.validateWrappedUpgrade(existingUpgradeCalldata);
        bytes memory l2V31UpgradeCalldata = L2UpgradeTxLib.buildL2V31UpgradeCalldata(
            _bridgehub,
            _chainId,
            _zksyncOS,
            existingUpgradeCalldata
        );

        return
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgrade,
                (forceDeployments, delegateTo, l2V31UpgradeCalldata)
            );
    }
}
