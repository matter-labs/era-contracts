// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Diamond} from "../../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "../../upgrades/BaseZkSyncUpgrade.sol";

contract CustomUpgradeTest is BaseZkSyncUpgrade {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    event Test();

    /// @notice Placeholder function for custom logic for upgrading L1 contract.
    /// Typically this function will never be used.
    /// @param _customCallDataForUpgrade Custom data for upgrade, which may be interpreted differently for each upgrade.
    function _upgradeL1Contract(bytes calldata _customCallDataForUpgrade) internal override {
        keccak256(_customCallDataForUpgrade); // called to suppress compilation warning
        emit Test();
    }

    /// @notice placeholder function for custom logic for post-upgrade logic.
    /// Typically this function will never be used.
    /// @param _customCallDataForUpgrade Custom data for an upgrade, which may be interpreted differently for each
    /// upgrade.
    function _postUpgrade(bytes calldata _customCallDataForUpgrade) internal override {}

    /// @notice The main function that will be called by the upgrade proxy.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade calldata _proposedUpgrade) public override returns (bytes32) {
        (uint32 newMinorVersion, bool isPatchOnly) = _setNewProtocolVersion(_proposedUpgrade.newProtocolVersion);
        _upgradeL1Contract(_proposedUpgrade.l1ContractsUpgradeCalldata);
        _upgradeVerifier(_proposedUpgrade.verifier, _proposedUpgrade.verifierParams);
        _setBaseSystemContracts(_proposedUpgrade.bootloaderHash, _proposedUpgrade.defaultAccountHash, isPatchOnly);

        bytes32 txHash;
        txHash = _setL2SystemContractUpgrade(
            _proposedUpgrade.l2ProtocolUpgradeTx,
            _proposedUpgrade.factoryDeps,
            newMinorVersion,
            isPatchOnly
        );

        _postUpgrade(_proposedUpgrade.postUpgradeCalldata);

        emit UpgradeComplete(_proposedUpgrade.newProtocolVersion, txHash, _proposedUpgrade);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
