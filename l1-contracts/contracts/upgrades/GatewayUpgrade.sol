// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable-v4/proxy/utils/Initializable.sol";

import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";

import {DataEncoding} from "../common/libraries/DataEncoding.sol";

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {PriorityQueue} from "../state-transition/libraries/PriorityQueue.sol";
import {PriorityTree} from "../state-transition/libraries/PriorityTree.sol";
import {GatewayUpgradeInvalidMsgSender, GatewayUpgradeFailed} from "./ZkSyncUpgradeErrors.sol";

import {IGatewayUpgrade} from "./IGatewayUpgrade.sol";
import {IL1SharedBridgeLegacy} from "../bridge/interfaces/IL1SharedBridgeLegacy.sol";

import {IBridgehub} from "../bridgehub/IBridgehub.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This upgrade will be used to migrate Era to be part of the ZK chain ecosystem contracts.
contract GatewayUpgrade is BaseZkSyncUpgrade, Initializable {
    using PriorityQueue for PriorityQueue.Queue;
    using PriorityTree for PriorityTree.Tree;

    address public immutable THIS_ADDRESS;

    constructor() {
        THIS_ADDRESS = address(this);
    }

    /// @notice The main function that will be called by the upgrade proxy.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade calldata _proposedUpgrade) public override returns (bytes32) {
        (bytes memory l2TxDataStart, bytes memory l2TxDataFinish) = abi.decode(
            _proposedUpgrade.postUpgradeCalldata,
            (bytes, bytes)
        );

        s.baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, s.__DEPRECATED_baseToken);
        s.priorityTree.setup(s.priorityQueue.getTotalPriorityTxs());
        IBridgehub(s.bridgehub).setLegacyBaseTokenAssetId(s.chainId);
        ProposedUpgrade memory proposedUpgrade = _proposedUpgrade;
        address l2LegacyBridge = IL1SharedBridgeLegacy(s.baseTokenBridge).l2BridgeAddress(s.chainId);
        proposedUpgrade.l2ProtocolUpgradeTx.data = bytes.concat(
            l2TxDataStart,
            bytes32(uint256(uint160(l2LegacyBridge))),
            l2TxDataFinish
        );
        // slither-disable-next-line controlled-delegatecall
        (bool success, ) = THIS_ADDRESS.delegatecall(
            abi.encodeWithSelector(IGatewayUpgrade.upgradeExternal.selector, proposedUpgrade)
        );
        if (!success) {
            revert GatewayUpgradeFailed();
        }
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    /// @notice The function that will be called from this same contract, we need an external call to be able to modify _proposedUpgrade (memory/calldata).
    function upgradeExternal(ProposedUpgrade calldata _proposedUpgrade) external {
        if (msg.sender != address(this)) {
            revert GatewayUpgradeInvalidMsgSender();
        }
        super.upgrade(_proposedUpgrade);
    }
}
