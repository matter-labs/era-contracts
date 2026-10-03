// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {CTMUpgradeBase} from "../default-upgrade/CTMUpgradeBase.sol";
import {DeployCTMUtils} from "../../ctm/DeployCTMUtils.s.sol";
import {ChainCreationParamsConfig, StateTransitionDeployedAddresses} from "../../utils/Types.sol";
import {PublishFactoryDepsResult} from "../../utils/bytecode/BytecodePublisher.s.sol";

/// @notice Prepares the v34 upgrade: the default upgrade, with `V34UpgradeZKsyncOS` as the cut's per-chain
/// upgrade. The CTM default stays `DefaultUpgradeZKsyncOS`. See {protocol-docs/l1-transaction-gas-limit.md}.
// solhint-disable-next-line contract-name-capwords
contract CTMUpgrade_v34 is DefaultCTMUpgrade {
    address internal v34Upgrade;

    /// @inheritdoc DefaultCTMUpgrade
    function deployUsedUpgradeContract() internal override returns (address) {
        v34Upgrade = deploySimpleContract("V34UpgradeZKsyncOS");
        return super.deployUsedUpgradeContract();
    }

    /// @inheritdoc DeployCTMUtils
    function getCreationCalldata(string memory _contractName) internal view override returns (bytes memory) {
        if (compareStrings(_contractName, "V34UpgradeZKsyncOS")) {
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
        require(v34Upgrade != address(0), "v34 upgrade not deployed");
        upgradeCutData.initAddress = v34Upgrade;
    }
}
