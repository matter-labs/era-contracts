// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SettlementLayerV31UpgradeBase} from "./SettlementLayerV31UpgradeBase.sol";
import {IL2ContractDeployer} from "../common/interfaces/IL2ContractDeployer.sol";
import {IComplexUpgrader} from "../state-transition/l2-deps/IComplexUpgrader.sol";
import {L2UpgradeTxLib} from "./L2UpgradeTxLib.sol";
import {Bytes} from "../vendor/Bytes.sol";

/// @author Matter Labs
/// @title EraSettlementLayerV31Upgrade
/// @dev V31 upgrade for Era (EraVM) chains. Handles the Era-style
/// ComplexUpgrader.forceDeployAndUpgrade(ForceDeployment[], address, bytes) format.
/// @custom:security-contact security@matterlabs.dev
contract EraSettlementLayerV31Upgrade is SettlementLayerV31UpgradeBase {
    using Bytes for bytes;

    /// @inheritdoc SettlementLayerV31UpgradeBase
    function getL2UpgradeTxData(
        address _bridgehub,
        uint256 _chainId,
        bytes memory _existingTxData
    ) public view override returns (bytes memory) {
        (
            IL2ContractDeployer.ForceDeployment[] memory forceDeployments,
            address delegateTo,
            bytes memory existingUpgradeCalldata
        ) = abi.decode(_existingTxData.slice(4), (IL2ContractDeployer.ForceDeployment[], address, bytes));

        L2UpgradeTxLib.validateWrappedUpgrade(existingUpgradeCalldata);
        bytes memory l2V31UpgradeCalldata = L2UpgradeTxLib.buildL2V31UpgradeCalldata(
            _bridgehub,
            _chainId,
            existingUpgradeCalldata
        );

        return
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgrade,
                (forceDeployments, delegateTo, l2V31UpgradeCalldata)
            );
    }
}
