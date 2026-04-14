// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SettlementLayerV31UpgradeBase} from "./SettlementLayerV31UpgradeBase.sol";
import {IComplexUpgrader} from "../state-transition/l2-deps/IComplexUpgrader.sol";
import {Bytes} from "../vendor/Bytes.sol";

/// @author Matter Labs
/// @title ZKsyncOSSettlementLayerV31Upgrade
/// @dev V31 upgrade for ZKsyncOS chains. Handles
/// IComplexUpgrader.forceDeployAndUpgradeUniversal(UniversalContractUpgradeInfo[], address, bytes).
/// @custom:security-contact security@matterlabs.dev
contract ZKsyncOSSettlementLayerV31Upgrade is SettlementLayerV31UpgradeBase {
    using Bytes for bytes;

    /// @inheritdoc SettlementLayerV31UpgradeBase
    function getL2UpgradeTxData(
        address _bridgehub,
        uint256 _chainId,
        bytes memory _existingTxData
    ) public view override returns (bytes memory) {
        (
            IComplexUpgrader.UniversalContractUpgradeInfo[] memory forceDeployments,
            address delegateTo,
            bytes memory existingUpgradeCalldata
        ) = abi.decode(_existingTxData.slice(4), (IComplexUpgrader.UniversalContractUpgradeInfo[], address, bytes));

        _validateWrappedUpgrade(existingUpgradeCalldata);
        bytes memory l2V31UpgradeCalldata = _buildL2V31UpgradeCalldata(_bridgehub, _chainId, existingUpgradeCalldata);

        return
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (forceDeployments, delegateTo, l2V31UpgradeCalldata)
            );
    }
}
