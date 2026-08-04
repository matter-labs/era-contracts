// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SettlementLayerV31UpgradeBase} from "./SettlementLayerV31UpgradeBase.sol";
import {L2UpgradeTxLib} from "./L2UpgradeTxLib.sol";

/// @author Matter Labs
/// @title ZKsyncOSSettlementLayerV31Upgrade
/// @dev V31 upgrade for ZKsyncOS chains. Handles
/// IComplexUpgrader.forceDeployAndUpgradeUniversal(UniversalContractUpgradeInfo[], address, bytes).
/// @custom:security-contact security@matterlabs.dev
contract ZKsyncOSSettlementLayerV31Upgrade is SettlementLayerV31UpgradeBase {
    /// @inheritdoc SettlementLayerV31UpgradeBase
    function getL2UpgradeTxData(
        address _bridgehub,
        uint256 _chainId,
        bool _zksyncOS,
        bytes memory _existingTxData
    ) public view override returns (bytes memory) {
        return L2UpgradeTxLib.rewriteZKsyncOSUpgradeTxData(_bridgehub, _chainId, _zksyncOS, _existingTxData);
    }
}
