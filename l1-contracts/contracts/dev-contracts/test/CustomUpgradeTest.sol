// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "../../upgrades/BaseZkSyncUpgrade.sol";
import {IVerifier} from "../../state-transition/chain-interfaces/IVerifier.sol";
import {IChainTypeManager} from "../../state-transition/IChainTypeManager.sol";

contract CustomUpgradeTest is BaseZkSyncUpgrade {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    event Test();

    /// @notice Placeholder function for custom logic for upgrading L1 contract.
    /// Typically this function will never be used.
    /// @param _customCallDataForUpgrade Custom data for upgrade, which may be interpreted differently for each upgrade.
    function _upgradeL1Contract(bytes memory _customCallDataForUpgrade) internal override {
        keccak256(_customCallDataForUpgrade); // called to suppress compilation warning
        emit Test();
    }

    /// @notice placeholder function for custom logic for post-upgrade logic.
    /// Typically this function will never be used.
    /// @param _customCallDataForUpgrade Custom data for an upgrade, which may be interpreted differently for each
    /// upgrade.
    function _postUpgrade(bytes memory _customCallDataForUpgrade) internal override {}

    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public override returns (bytes32) {
        (uint32 newMinorVersion, bool isPatchOnly) = _setNewProtocolVersion(_proposedUpgrade.newProtocolVersion, true);
        _upgradeL1Contract(_proposedUpgrade.l1ContractsUpgradeCalldata);
        // Fetch verifier from CTM based on new protocol version
        address ctmVerifier = IChainTypeManager(s.chainTypeManager).protocolVersionVerifier(
            _proposedUpgrade.newProtocolVersion
        );
        if (ctmVerifier != address(0)) {
            _setVerifier(IVerifier(ctmVerifier));
        }
        _setBaseSystemContracts(
            _proposedUpgrade.bootloaderHash,
            _proposedUpgrade.defaultAccountHash,
            _proposedUpgrade.evmEmulatorHash,
            isPatchOnly
        );

        bytes32 txHash;
        txHash = _setL2SystemContractUpgrade(_proposedUpgrade.l2ProtocolUpgradeTx, newMinorVersion, isPatchOnly);

        _postUpgrade(_proposedUpgrade.postUpgradeCalldata);

        emit UpgradeComplete(_proposedUpgrade.newProtocolVersion, txHash, _proposedUpgrade);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
