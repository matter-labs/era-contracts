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
    address internal v34Upgrade;

    /// @inheritdoc DefaultCTMUpgrade
    /// @dev Rejects an unsupported CTM before reading the input TOML.
    function noGovernancePrepare(CTMUpgradeParams memory _params) public override {
        require(IChainTypeManager(_params.ctmProxy).isZKsyncOS(), "v34 requires a ZKsync OS CTM");
        super.noGovernancePrepare(_params);
    }

    /// @inheritdoc DefaultCTMUpgrade
    function deployUsedUpgradeContract() internal override returns (address) {
        v34Upgrade = deploySimpleContract("V34UpgradeZKsyncOS");
        return super.deployUsedUpgradeContract();
    }

    /// @inheritdoc DefaultCTMUpgrade
    function serializeVersionSpecificStateTransition() internal override {
        require(v34Upgrade != address(0), "v34 initializer not deployed");
        vm.serializeAddress("state_transition", "v34_upgrade_addr", v34Upgrade);
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
        require(v34Upgrade != address(0), "v34 initializer not deployed");
        upgradeCutData.initAddress = v34Upgrade;
    }
}
