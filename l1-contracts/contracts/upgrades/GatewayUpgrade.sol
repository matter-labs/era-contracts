// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";

import {DataEncoding} from "../common/libraries/DataEncoding.sol";

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {PriorityQueue} from "../state-transition/libraries/PriorityQueue.sol";
import {PriorityTree} from "../state-transition/libraries/PriorityTree.sol";

import {IGatewayUpgrade} from "./IGatewayUpgrade.sol";
import {IL1SharedBridgeLegacy} from "../bridge/interfaces/IL1SharedBridgeLegacy.sol";
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This upgrade will be used to migrate Era to be part of the hyperchain ecosystem contracts.
contract GatewayUpgrade is BaseZkSyncUpgrade, Initializable {
    using PriorityQueue for PriorityQueue.Queue;
    using PriorityTree for PriorityTree.Tree;

    /// @notice The main function that will be called by the upgrade proxy.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade calldata _proposedUpgrade) public override returns (bytes32) {
        (address gatewayUpgradeAddress, bytes memory l2TxDataStart, bytes memory l2TxDataFinish) = abi.decode(
            _proposedUpgrade.postUpgradeCalldata,
            (address, bytes, bytes)
        );

        s.baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, s.baseToken);
        s.priorityTree.setup(s.priorityQueue.getTotalPriorityTxs());
        /// maybe set baseTokenAssetId in Bridgehub here

        ProposedUpgrade memory proposedUpgrade = _proposedUpgrade;
        address l2LegacyBridge = IL1SharedBridgeLegacy(s.baseTokenBridge).l2BridgeAddress(s.chainId);
        proposedUpgrade.l2ProtocolUpgradeTx.data = bytes.concat(
            l2TxDataStart,
            bytes32(bytes20(l2LegacyBridge)),
            l2TxDataFinish
        );
        // slither-disable-next-line unused-return, controlled-delegatecall, unchecked-low-level-calls
        gatewayUpgradeAddress.delegatecall(
            abi.encodeWithSelector(IGatewayUpgrade.upgradeExternal.selector, proposedUpgrade)
        );
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    function upgradeExternal(ProposedUpgrade calldata _proposedUpgrade) external {
        // solhint-disable-next-line gas-custom-errors
        require(msg.sender == address(this), "GatewayUpgrade: upgradeExternal");
        super.upgrade(_proposedUpgrade);
    }
}
