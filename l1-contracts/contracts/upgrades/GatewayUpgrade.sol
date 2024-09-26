// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable-v4/proxy/utils/Initializable.sol";

import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";

import {DataEncoding} from "../common/libraries/DataEncoding.sol";

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {PriorityQueue} from "../state-transition/libraries/PriorityQueue.sol";
import {PriorityTree} from "../state-transition/libraries/PriorityTree.sol";

import {IGatewayUpgrade} from "./IGatewayUpgrade.sol";
import {IL1SharedBridgeLegacy} from "../bridge/interfaces/IL1SharedBridgeLegacy.sol";
import {IComplexUpgrader} from "../state-transition/l2-deps/IComplexUpgrader.sol";
import {IL2GatewayUpgrade} from "../state-transition/l2-deps/IL2GatewayUpgrade.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {ZKChainSpecificForceDeploymentsData} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";

import {IL2ContractDeployer} from "../common/interfaces/IL2ContractDeployer.sol";

import {GatewayHelper} from "./GatewayHelper.sol";

struct GatewayUpgradeEncodedInput {
    IL2ContractDeployer.ForceDeployment[] baseForceDeployments;
    address ctmDeployer;
    bytes fixedForceDeploymentsData;
    address l2GatewayUpgrade;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This upgrade will be used to migrate Era to be part of the ZK chain ecosystem contracts.
contract GatewayUpgrade is BaseZkSyncUpgrade {
    using PriorityQueue for PriorityQueue.Queue;
    using PriorityTree for PriorityTree.Tree;

    address public immutable THIS_ADDRESS;

    constructor() {
        THIS_ADDRESS = address(this);
    }

    /// @notice The main function that will be called by the upgrade proxy.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade calldata _proposedUpgrade) public override returns (bytes32) {
        GatewayUpgradeEncodedInput memory encodedInput = abi.decode(_proposedUpgrade.postUpgradeCalldata, (GatewayUpgradeEncodedInput));

        bytes32 baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, s.__DEPRECATED_baseToken);

        s.baseTokenAssetId = baseTokenAssetId;
        s.priorityTree.setup(s.priorityQueue.getTotalPriorityTxs());
        IBridgehub bridgehub = IBridgehub(s.bridgehub);
        address sharedBridge = bridgehub.sharedBridge();
        ProposedUpgrade memory proposedUpgrade = _proposedUpgrade;
        address l2LegacyBridge = IL1SharedBridgeLegacy(sharedBridge).l2BridgeAddress(s.chainId);

        bytes memory gatewayUpgradeCalldata = abi.encodeCall(
            IL2GatewayUpgrade.upgrade,
            (
                encodedInput.baseForceDeployments,
                encodedInput.ctmDeployer,
                encodedInput.fixedForceDeploymentsData,
                GatewayHelper.getZKChainSpecificForceDeploymentsData(s)
            )
        );

        proposedUpgrade.l2ProtocolUpgradeTx.data = abi.encodeCall(IComplexUpgrader.upgrade, (
            encodedInput.l2GatewayUpgrade,
            gatewayUpgradeCalldata
        ));
        
        // slither-disable-next-line controlled-delegatecall
        (bool success, ) = THIS_ADDRESS.delegatecall(
            abi.encodeWithSelector(IGatewayUpgrade.upgradeExternal.selector, proposedUpgrade)
        );
        // solhint-disable-next-line gas-custom-errors
        require(success, "GatewayUpgrade: upgrade failed");
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    /// @notice The function that will be called from this same contract, we need an external call to be able to modify _proposedUpgrade (memory/calldata).
    function upgradeExternal(ProposedUpgrade calldata _proposedUpgrade) external {
        super.upgrade(_proposedUpgrade);
    }
}
