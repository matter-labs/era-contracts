// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {CTMUpgradeBase} from "../default-upgrade/CTMUpgradeBase.sol";
import {CTMUpgradeParams} from "../default-upgrade/UpgradeParams.sol";
import {DeployCTMUtils} from "../../ctm/DeployCTMUtils.s.sol";
import {ChainCreationParamsConfig, StateTransitionDeployedAddresses} from "../../utils/Types.sol";
import {PublishFactoryDepsResult} from "../../utils/bytecode/BytecodePublisher.s.sol";

/// @notice Prepares the ZKsync OS v34 upgrade. See {protocol-docs/chain-config.md}.
// solhint-disable-next-line contract-name-capwords
contract CTMUpgrade_v34 is DefaultCTMUpgrade {
    /// @inheritdoc DefaultCTMUpgrade
    function noGovernancePrepare(CTMUpgradeParams memory _params) public override {
        require(IChainTypeManager(_params.ctmProxy).isZKsyncOS(), "v34 requires a ZKsync OS CTM");
        super.noGovernancePrepare(_params);
    }

    /// @inheritdoc DeployCTMUtils
    function getCreationCalldata(string memory _contractName) internal view override returns (bytes memory) {
        if (compareStrings(_contractName, "ZKsyncOSSettlementLayerV34Upgrade")) {
            return abi.encode();
        }
        return super.getCreationCalldata(_contractName);
    }

    /// @inheritdoc CTMUpgradeBase
    function generateUpgradeCutData(
        StateTransitionDeployedAddresses memory _stateTransition,
        ChainCreationParamsConfig memory _chainCreationParams,
        PublishFactoryDepsResult memory _factoryDepsResult,
        address _registeredChainIdDiamondProxy
    ) public override returns (Diamond.DiamondCutData memory upgradeCutData) {
        upgradeCutData = super.generateUpgradeCutData(
            _stateTransition,
            _chainCreationParams,
            _factoryDepsResult,
            _registeredChainIdDiamondProxy
        );
        upgradeCutData.initAddress = deploySimpleContract("ZKsyncOSSettlementLayerV34Upgrade");
    }
}
