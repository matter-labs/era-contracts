// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Utils} from "deploy-scripts/utils/Utils.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {FixedForceDeploymentsData, ZKChainSpecificForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {TokenMetadata, TokenBridgingData} from "contracts/common/Messaging.sol";
import {Vm} from "forge-std/Vm.sol";
import {ISystemContext} from "contracts/common/interfaces/ISystemContext.sol";
import {L2Bridgehub} from "contracts/core/bridgehub/L2Bridgehub.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2ChainAssetHandler} from "contracts/core/chain-asset-handler/L2ChainAssetHandler.sol";

struct BytecodeInfo {
    bytes messageRootBytecodeInfo;
    bytes l2NtvBytecodeInfo;
    bytes l2AssetRouterBytecodeInfo;
    bytes bridgehubBytecodeInfo;
    bytes chainAssetHandlerBytecodeInfo;
    bytes beaconDeployerBytecodeInfo;
    bytes interopCenterBytecodeInfo;
    bytes interopHandlerBytecodeInfo;
    bytes assetTrackerBytecodeInfo;
}

library L2GenesisUpgradeTestHelper {
    function getBytecodeInfo() public view returns (BytecodeInfo memory info) {
        bytes memory messageRootBytecode = Utils.readZKFoundryBytecodeL1("L2MessageRoot.sol", "L2MessageRoot");
        info.messageRootBytecodeInfo = abi.encode(L2ContractHelper.hashL2Bytecode(messageRootBytecode));

        bytes memory l2NativeTokenVaultBytecode = Utils.readZKFoundryBytecodeL1(
            "L2NativeTokenVault.sol",
            "L2NativeTokenVault"
        );
        info.l2NtvBytecodeInfo = abi.encode(L2ContractHelper.hashL2Bytecode(l2NativeTokenVaultBytecode));

        info.l2AssetRouterBytecodeInfo = abi.encode(
            L2ContractHelper.hashL2Bytecode(Utils.readZKFoundryBytecodeL1("L2AssetRouter.sol", "L2AssetRouter"))
        );

        info.bridgehubBytecodeInfo = abi.encode(
            L2ContractHelper.hashL2Bytecode(Utils.readZKFoundryBytecodeL1("L2Bridgehub.sol", "L2Bridgehub"))
        );

        info.chainAssetHandlerBytecodeInfo = abi.encode(
            L2ContractHelper.hashL2Bytecode(
                Utils.readZKFoundryBytecodeL1("L2ChainAssetHandler.sol", "L2ChainAssetHandler")
            )
        );

        info.beaconDeployerBytecodeInfo = abi.encode(
            L2ContractHelper.hashL2Bytecode(
                Utils.readZKFoundryBytecodeL1("UpgradeableBeaconDeployer.sol", "UpgradeableBeaconDeployer")
            )
        );

        info.interopCenterBytecodeInfo = abi.encode(
            L2ContractHelper.hashL2Bytecode(Utils.readZKFoundryBytecodeL1("InteropCenter.sol", "InteropCenter"))
        );

        info.interopHandlerBytecodeInfo = abi.encode(
            L2ContractHelper.hashL2Bytecode(Utils.readZKFoundryBytecodeL1("InteropHandler.sol", "InteropHandler"))
        );

        info.assetTrackerBytecodeInfo = abi.encode(
            L2ContractHelper.hashL2Bytecode(Utils.readZKFoundryBytecodeL1("L2AssetTracker.sol", "L2AssetTracker"))
        );
    }

    function getAdditionalForceDeploymentsData() public pure returns (bytes memory) {
        return
            abi.encode(
                ZKChainSpecificForceDeploymentsData({
                    baseTokenBridgingData: TokenBridgingData({
                        assetId: bytes32(0x0100056f53fd9e940906d998a80ed53392e5c50a8eb198baf9f78fd84ce7ec70),
                        originChainId: 1,
                        originToken: address(1)
                    }),
                    l2LegacySharedBridge: address(0),
                    predeployedL2WethAddress: address(1),
                    baseTokenL1Address: address(1),
                    baseTokenMetadata: TokenMetadata({name: "Ether", symbol: "ETH", decimals: 18})
                })
            );
    }

    function getFixedForceDeploymentsData(
        uint256 _chainId,
        BytecodeInfo memory _bytecodeInfo
    ) public pure returns (bytes memory) {
        return
            abi.encode(
                FixedForceDeploymentsData({
                    l1ChainId: 1,
                    gatewayChainId: 1,
                    eraChainId: _chainId,
                    l1AssetRouter: address(1),
                    l2TokenProxyBytecodeHash: bytes32(
                        0x0100056f53fd9e940906d998a80ed53392e5c50a8eb198baf9f78fd84ce7ec70
                    ),
                    aliasedL1Governance: address(1),
                    maxNumberOfZKChains: 100,
                    bridgehubBytecodeInfo: _bytecodeInfo.bridgehubBytecodeInfo,
                    l2AssetRouterBytecodeInfo: _bytecodeInfo.l2AssetRouterBytecodeInfo,
                    l2NtvBytecodeInfo: _bytecodeInfo.l2NtvBytecodeInfo,
                    messageRootBytecodeInfo: _bytecodeInfo.messageRootBytecodeInfo,
                    chainAssetHandlerBytecodeInfo: _bytecodeInfo.chainAssetHandlerBytecodeInfo,
                    interopCenterBytecodeInfo: _bytecodeInfo.interopCenterBytecodeInfo,
                    interopHandlerBytecodeInfo: _bytecodeInfo.interopHandlerBytecodeInfo,
                    assetTrackerBytecodeInfo: _bytecodeInfo.assetTrackerBytecodeInfo,
                    beaconDeployerInfo: _bytecodeInfo.beaconDeployerBytecodeInfo,
                    l2SharedBridgeLegacyImpl: address(0),
                    l2BridgedStandardERC20Impl: address(0),
                    aliasedChainRegistrationSender: address(1),
                    dangerousTestOnlyForcedBeacon: address(0),
                    zkTokenAssetId: bytes32(0)
                })
            );
    }

    function setupMockCalls(
        Vm _vm,
        address _systemContext,
        address _bridgehub,
        address _assetRouter,
        address _chainAssetHandler,
        address _interopCenter,
        address _knownCodeStorage,
        address _proxyAdmin,
        address _complexUpgrader
    ) public {
        _vm.mockCall(_systemContext, abi.encodeWithSelector(ISystemContext.setChainId.selector), "");
        _vm.mockCall(_bridgehub, abi.encodeWithSelector(L2Bridgehub.initL2.selector), "");
        _vm.mockCall(_assetRouter, abi.encodeWithSelector(L2AssetRouter.initL2.selector), "");
        _vm.mockCall(_chainAssetHandler, abi.encodeWithSelector(L2ChainAssetHandler.initL2.selector), "");
        _vm.mockCall(_interopCenter, abi.encodeWithSelector(bytes4(keccak256("initL2(uint256,address)"))), "");
        _vm.mockCall(_knownCodeStorage, abi.encodeWithSelector(bytes4(keccak256("getMarker(bytes32)"))), abi.encode(1));
        _vm.mockCall(_proxyAdmin, abi.encodeWithSignature("owner()"), abi.encode(_complexUpgrader));
    }
}
