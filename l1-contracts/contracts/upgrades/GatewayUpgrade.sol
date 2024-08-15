// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";

import {DataEncoding} from "../common/libraries/DataEncoding.sol";

import {AdminFacet} from "../state-transition/chain-deps/facets/Admin.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This upgrade will be used to migrate Era to be part of the hyperchain ecosystem contracts.
contract GatewayUpgrade is BaseZkSyncUpgrade, AdminFacet {
    /// @notice The main function that will be called by the upgrade proxy.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade calldata _proposedUpgrade) public override returns (bytes32) {
        (
            address l1DAValidator,
            address l2DAValidator,
            address l2LegacyBridge,
            bytes memory l2TxDataStart,
            bytes memory l2TxDataFinish
        ) = abi.decode(_proposedUpgrade.postUpgradeCalldata, (address, address, address, bytes, bytes));

        s.baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, s.baseToken);
        /// maybe set baseTokenAssetId in Bridgehub here
        _setDAValidatorPair(l1DAValidator, l2DAValidator);

        ProposedUpgrade memory proposedUpgrade = _proposedUpgrade;
        /// We might want to read the l2LegacyBridge address from a specific contract based on chainId.
        proposedUpgrade.l2ProtocolUpgradeTx.data = bytes.concat(l2TxDataStart, bytes20(l2LegacyBridge), l2TxDataFinish);
        this.upgradeExternal(proposedUpgrade);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    function upgradeExternal(ProposedUpgrade calldata _proposedUpgrade) external {
        // solhint-disable-next-line gas-custom-errors
        require(msg.sender == address(this), "GatewayUpgrade: upgradeExternal");
        super.upgrade(_proposedUpgrade);
    }
}
