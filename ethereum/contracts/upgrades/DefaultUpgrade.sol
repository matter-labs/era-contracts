// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../zksync/libraries/Diamond.sol";
import "./BaseZkSyncUpgrade.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract DefaultUpgrade is BaseZkSyncUpgrade {
    /// @notice Placeholder function for custom logic for upgrading L1 contract.
    /// Typically this function will never be used.
    /// @param _customCallDataForUpgrade Custom data for an upgrade, which may be interpreted differently for each
    /// upgrade.
    function _upgradeL1Contract(bytes calldata _customCallDataForUpgrade) internal virtual {}

    /// @notice placeholder function for custom logic for post-upgrade logic.
    /// Typically this function will never be used.
    /// @param _customCallDataForUpgrade Custom data for an upgrade, which may be interpreted differently for each
    /// upgrade.
    function _postUpgrade(bytes calldata _customCallDataForUpgrade) internal virtual {}

    /// @notice The main function that will be called by the upgrade proxy.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade calldata _proposedUpgrade) public override returns (bytes32) {
        super.upgrade(_proposedUpgrade);

        _setNewProtocolVersion(_proposedUpgrade.newProtocolVersion);
        _upgradeL1Contract(_proposedUpgrade.l1ContractsUpgradeCalldata);
        _upgradeVerifier(_proposedUpgrade.verifier, _proposedUpgrade.verifierParams);
        _setBaseSystemContracts(_proposedUpgrade.bootloaderHash, _proposedUpgrade.defaultAccountHash);

        bytes32 txHash;
        txHash = _setL2SystemContractUpgrade(
            _proposedUpgrade.l2ProtocolUpgradeTx,
            _proposedUpgrade.factoryDeps,
            _proposedUpgrade.newProtocolVersion
        );

        _setAllowList(IAllowList(_proposedUpgrade.newAllowList));
        _postUpgrade(_proposedUpgrade.postUpgradeCalldata);

        emit UpgradeComplete(_proposedUpgrade.newProtocolVersion, txHash, _proposedUpgrade);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
