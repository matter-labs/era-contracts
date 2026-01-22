// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";

// It's required to disable lints to force the compiler to compile the contracts
// solhint-disable no-unused-import

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Utils} from "../utils/Utils.sol";

import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {GatewayTransactionFilterer} from "contracts/transactionFilterer/GatewayTransactionFilterer.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IAssetRouterBase, SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION, NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {CTM_DEPLOYMENT_TRACKER_ENCODING_VERSION} from "contracts/core/ctm-deployment/CTMDeploymentTracker.sol";
import {IL2AssetRouter, L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";

import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {Call} from "contracts/governance/Common.sol";

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

abstract contract GatewayGovernanceUtils is Script {
    struct GatewayGovernanceConfig {
        address bridgehubProxy;
        address l1AssetRouterProxy;
        address chainTypeManagerProxy;
        address ctmDeploymentTrackerProxy;
        uint256 gatewayChainId;
    }

    struct PrepareGatewayGovernanceCalls {
        uint256 _l1GasPrice;
        address _gatewayCTMAddress;
        address _gatewayRollupDAManager;
        address _gatewayValidatorTimelock;
        address _gatewayServerNotifier;
        address _refundRecipient;
        uint256 _ctmRepresentativeChainId;
    }

    GatewayGovernanceConfig internal _gatewayGovernanceConfig;

    function _initializeGatewayGovernanceConfig(GatewayGovernanceConfig memory config) internal {
        _gatewayGovernanceConfig = config;
    }

    function _getRegisterSettlementLayerCalls() internal view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({
            target: _gatewayGovernanceConfig.bridgehubProxy,
            value: 0,
            data: abi.encodeCall(IL1Bridgehub.registerSettlementLayer, (_gatewayGovernanceConfig.gatewayChainId, true))
        });
    }

    function _prepareGatewayGovernanceCalls(
        PrepareGatewayGovernanceCalls memory prepareGWGovCallsStruct
    ) internal returns (Call[] memory calls) {
        {
            if (prepareGWGovCallsStruct._ctmRepresentativeChainId == _gatewayGovernanceConfig.gatewayChainId) {
                calls = _getRegisterSettlementLayerCalls();
            }
        }

        // Registration of the new chain type manager inside the ZK Gateway chain
        {
            bytes memory data = abi.encodeCall(
                IBridgehubBase.addChainTypeManager,
                (prepareGWGovCallsStruct._gatewayCTMAddress)
            );

            calls = Utils.mergeCalls(
                calls,
                Utils.prepareGovernanceL1L2DirectTransaction(
                    prepareGWGovCallsStruct._l1GasPrice,
                    data,
                    Utils.MAX_PRIORITY_TX_GAS,
                    new bytes[](0),
                    L2_BRIDGEHUB_ADDR,
                    _gatewayGovernanceConfig.gatewayChainId,
                    _gatewayGovernanceConfig.bridgehubProxy,
                    _gatewayGovernanceConfig.l1AssetRouterProxy,
                    prepareGWGovCallsStruct._refundRecipient
                )
            );
        }

        // Registering an asset that corresponds to chains inside L1AssetRouter
        // as well as inside the CTMDeploymentTracker
        {
            calls = Utils.appendCall(
                calls,
                Call({
                    target: _gatewayGovernanceConfig.l1AssetRouterProxy,
                    data: abi.encodeCall(
                        L1AssetRouter.setAssetDeploymentTracker,
                        (
                            bytes32(uint256(uint160(_gatewayGovernanceConfig.chainTypeManagerProxy))),
                            _gatewayGovernanceConfig.ctmDeploymentTrackerProxy
                        )
                    ),
                    value: 0
                })
            );

            calls = Utils.appendCall(
                calls,
                Call({
                    target: _gatewayGovernanceConfig.ctmDeploymentTrackerProxy,
                    data: abi.encodeCall(
                        ICTMDeploymentTracker.registerCTMAssetOnL1,
                        (_gatewayGovernanceConfig.chainTypeManagerProxy)
                    ),
                    value: 0
                })
            );
        }

        // Confirmed that the L2 Bridgehub should be an asset handler for the assetId for chains.
        {
            // The CTM assetId has not yet been registered on production chains and so we need to calculate it manually.
            bytes32 chainAssetId = DataEncoding.encodeAssetId(
                block.chainid,
                bytes32(uint256(uint160(_gatewayGovernanceConfig.chainTypeManagerProxy))),
                _gatewayGovernanceConfig.ctmDeploymentTrackerProxy
            );

            bytes memory secondBridgeData = abi.encodePacked(
                SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION,
                abi.encode(chainAssetId, L2_CHAIN_ASSET_HANDLER_ADDR)
            );

            calls = Utils.mergeCalls(
                calls,
                Utils.prepareGovernanceL1L2TwoBridgesTransaction(
                    prepareGWGovCallsStruct._l1GasPrice,
                    Utils.MAX_PRIORITY_TX_GAS,
                    _gatewayGovernanceConfig.gatewayChainId,
                    _gatewayGovernanceConfig.bridgehubProxy,
                    _gatewayGovernanceConfig.l1AssetRouterProxy,
                    _gatewayGovernanceConfig.l1AssetRouterProxy,
                    0,
                    secondBridgeData,
                    prepareGWGovCallsStruct._refundRecipient
                )
            );
        }

        // Setting the address of the GW ChainTypeManager as the correct ChainTypeManager to handle
        // chains that migrate from L1.
        {
            bytes memory secondBridgeData = abi.encodePacked(
                NEW_ENCODING_VERSION,
                abi.encode(_gatewayGovernanceConfig.chainTypeManagerProxy, prepareGWGovCallsStruct._gatewayCTMAddress)
            );

            calls = Utils.mergeCalls(
                calls,
                Utils.prepareGovernanceL1L2TwoBridgesTransaction(
                    prepareGWGovCallsStruct._l1GasPrice,
                    Utils.MAX_PRIORITY_TX_GAS,
                    _gatewayGovernanceConfig.gatewayChainId,
                    _gatewayGovernanceConfig.bridgehubProxy,
                    _gatewayGovernanceConfig.l1AssetRouterProxy,
                    _gatewayGovernanceConfig.ctmDeploymentTrackerProxy,
                    0,
                    secondBridgeData,
                    prepareGWGovCallsStruct._refundRecipient
                )
            );
        }

        // Accept ownership calls
        {
            bytes memory data = abi.encodeCall(Ownable2Step.acceptOwnership, ());

            calls = Utils.mergeCalls(
                calls,
                Utils.prepareGovernanceL1L2DirectTransaction(
                    prepareGWGovCallsStruct._l1GasPrice,
                    data,
                    Utils.MAX_PRIORITY_TX_GAS,
                    new bytes[](0),
                    prepareGWGovCallsStruct._gatewayRollupDAManager,
                    _gatewayGovernanceConfig.gatewayChainId,
                    _gatewayGovernanceConfig.bridgehubProxy,
                    _gatewayGovernanceConfig.l1AssetRouterProxy,
                    prepareGWGovCallsStruct._refundRecipient
                )
            );
            // Todo: can probably delete since ValidatorTimelock is now TUPP.
            // calls = Utils.mergeCalls(
            //     calls,
            //     Utils.prepareGovernanceL1L2DirectTransaction(
            //         prepareGWGovCallsStruct._l1GasPrice,
            //         data,
            //         Utils.MAX_PRIORITY_TX_GAS,
            //         new bytes[](0),
            //         prepareGWGovCallsStruct._gatewayValidatorTimelock,
            //         _gatewayGovernanceConfig.gatewayChainId,
            //         _gatewayGovernanceConfig.bridgehubProxy,
            //         _gatewayGovernanceConfig.l1AssetRouterProxy,
            //         prepareGWGovCallsStruct._refundRecipient
            //     )
            // );
            calls = Utils.mergeCalls(
                calls,
                Utils.prepareGovernanceL1L2DirectTransaction(
                    prepareGWGovCallsStruct._l1GasPrice,
                    data,
                    Utils.MAX_PRIORITY_TX_GAS,
                    new bytes[](0),
                    prepareGWGovCallsStruct._gatewayServerNotifier,
                    _gatewayGovernanceConfig.gatewayChainId,
                    _gatewayGovernanceConfig.bridgehubProxy,
                    _gatewayGovernanceConfig.l1AssetRouterProxy,
                    prepareGWGovCallsStruct._refundRecipient
                )
            );
        }
    }
}
