// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";
// import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

// It's required to disable lints to force the compiler to compile the contracts
// solhint-disable no-unused-import
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {IBridgehub, BridgehubBurnCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehub.sol";
import {L2_BRIDGEHUB_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {StateTransitionDeployedAddresses, Utils, L2_BRIDGEHUB_ADDRESS, L2_CREATE2_FACTORY_ADDRESS} from "./Utils.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {GatewayTransactionFilterer} from "contracts/transactionFilterer/GatewayTransactionFilterer.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {CTM_DEPLOYMENT_TRACKER_ENCODING_VERSION} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {L2AssetRouter, IL2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {BridgehubMintCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {L2ContractsBytecodesLib} from "./L2ContractsBytecodesLib.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {Call} from "contracts/governance/Common.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";

import {Create2AndTransfer} from "./Create2AndTransfer.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";

import {DeployL1Script} from "./DeployL1.s.sol";

import {GatewayCTMDeployerHelper} from "./GatewayCTMDeployerHelper.sol";
import {DeployedContracts, GatewayCTMDeployerConfig} from "contracts/state-transition/chain-deps/GatewayCTMDeployer.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";

abstract contract GatewayGovernanceUtils is Script {
    struct GatewayGovernanceConfig {
        address bridgehubProxy;
        address l1AssetRouterProxy;
        address chainTypeManagerProxy;
        address ctmDeploymentTrackerProxy;
        uint256 gatewayChainId;
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
            data: abi.encodeCall(IBridgehub.registerSettlementLayer, (_gatewayGovernanceConfig.gatewayChainId, true))
        });
    }

    function _prepareGatewayGovernanceCalls(
        uint256 _l1GasPrice,
        address _gatewayCTMAddress,
        address _gatewayRollupDAManager,
        address _gatewayValidatorTimelock,
        address _gatewayServerNotifier,
        address _refundRecipient
    ) internal view returns (Call[] memory calls) {
        calls = _getRegisterSettlementLayerCalls();

        // Registration of the new chain type manager inside the ZK Gateway chain
        {
            bytes memory data = abi.encodeCall(IBridgehub.addChainTypeManager, (_gatewayCTMAddress));

            calls = Utils.mergeCalls(
                calls,
                Utils.prepareGovernanceL1L2DirectTransaction(
                    _l1GasPrice,
                    data,
                    Utils.MAX_PRIORITY_TX_GAS,
                    new bytes[](0),
                    L2_BRIDGEHUB_ADDR,
                    _gatewayGovernanceConfig.gatewayChainId,
                    _gatewayGovernanceConfig.bridgehubProxy,
                    _gatewayGovernanceConfig.l1AssetRouterProxy,
                    _refundRecipient
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
                abi.encode(chainAssetId, L2_BRIDGEHUB_ADDR)
            );

            calls = Utils.mergeCalls(
                calls,
                Utils.prepareGovernanceL1L2TwoBridgesTransaction(
                    _l1GasPrice,
                    Utils.MAX_PRIORITY_TX_GAS,
                    _gatewayGovernanceConfig.gatewayChainId,
                    _gatewayGovernanceConfig.bridgehubProxy,
                    _gatewayGovernanceConfig.l1AssetRouterProxy,
                    _gatewayGovernanceConfig.l1AssetRouterProxy,
                    0,
                    secondBridgeData,
                    _refundRecipient
                )
            );
        }

        // Setting the address of the GW ChainTypeManager as the correct ChainTypeManager to handle
        // chains that migrate from L1.
        {
            bytes memory secondBridgeData = abi.encodePacked(
                bytes1(0x01),
                abi.encode(_gatewayGovernanceConfig.chainTypeManagerProxy, _gatewayCTMAddress)
            );

            calls = Utils.mergeCalls(
                calls,
                Utils.prepareGovernanceL1L2TwoBridgesTransaction(
                    _l1GasPrice,
                    Utils.MAX_PRIORITY_TX_GAS,
                    _gatewayGovernanceConfig.gatewayChainId,
                    _gatewayGovernanceConfig.bridgehubProxy,
                    _gatewayGovernanceConfig.l1AssetRouterProxy,
                    _gatewayGovernanceConfig.ctmDeploymentTrackerProxy,
                    0,
                    secondBridgeData,
                    _refundRecipient
                )
            );
        }

        // Accept ownership calls
        {
            bytes memory data = abi.encodeCall(Ownable2Step.acceptOwnership, ());

            calls = Utils.mergeCalls(
                calls,
                Utils.prepareGovernanceL1L2DirectTransaction(
                    _l1GasPrice,
                    data,
                    Utils.MAX_PRIORITY_TX_GAS,
                    new bytes[](0),
                    _gatewayRollupDAManager,
                    _gatewayGovernanceConfig.gatewayChainId,
                    _gatewayGovernanceConfig.bridgehubProxy,
                    _gatewayGovernanceConfig.l1AssetRouterProxy,
                    _refundRecipient
                )
            );
            calls = Utils.mergeCalls(
                calls,
                Utils.prepareGovernanceL1L2DirectTransaction(
                    _l1GasPrice,
                    data,
                    Utils.MAX_PRIORITY_TX_GAS,
                    new bytes[](0),
                    _gatewayValidatorTimelock,
                    _gatewayGovernanceConfig.gatewayChainId,
                    _gatewayGovernanceConfig.bridgehubProxy,
                    _gatewayGovernanceConfig.l1AssetRouterProxy,
                    _refundRecipient
                )
            );
            calls = Utils.mergeCalls(
                calls,
                Utils.prepareGovernanceL1L2DirectTransaction(
                    _l1GasPrice,
                    data,
                    Utils.MAX_PRIORITY_TX_GAS,
                    new bytes[](0),
                    _gatewayServerNotifier,
                    _gatewayGovernanceConfig.gatewayChainId,
                    _gatewayGovernanceConfig.bridgehubProxy,
                    _gatewayGovernanceConfig.l1AssetRouterProxy,
                    _refundRecipient
                )
            );
        }
    }
}
