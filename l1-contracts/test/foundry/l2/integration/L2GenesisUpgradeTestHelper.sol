// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

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

struct ContractName {
    string file;
    string name;
}

struct BytecodeNames {
    // For force deployments data
    ContractName messageRoot;
    ContractName l2Ntv;
    ContractName l2AssetRouter;
    ContractName bridgehub;
    ContractName chainAssetHandler;
    ContractName beaconDeployer;
    ContractName interopCenter;
    ContractName interopHandler;
    ContractName assetTracker;
    // For setUp etching
    ContractName complexUpgrader;
    ContractName genesisUpgrade;
    ContractName systemContext;
    ContractName wrappedBaseToken;
    ContractName systemContractProxyAdmin;
}

contract L2GenesisUpgradeTestHelper {
    function getBytecodeNames() public pure returns (BytecodeNames memory names) {
        // For force deployments data
        names.messageRoot = ContractName("L2MessageRoot.sol", "L2MessageRoot");
        names.l2Ntv = ContractName("L2NativeTokenVault.sol", "L2NativeTokenVault");
        names.l2AssetRouter = ContractName("L2AssetRouter.sol", "L2AssetRouter");
        names.bridgehub = ContractName("L2Bridgehub.sol", "L2Bridgehub");
        names.chainAssetHandler = ContractName("L2ChainAssetHandler.sol", "L2ChainAssetHandler");
        names.beaconDeployer = ContractName("UpgradeableBeaconDeployer.sol", "UpgradeableBeaconDeployer");
        names.interopCenter = ContractName("InteropCenter.sol", "InteropCenter");
        names.interopHandler = ContractName("InteropHandler.sol", "InteropHandler");
        names.assetTracker = ContractName("L2AssetTracker.sol", "L2AssetTracker");
        // For setUp etching
        names.complexUpgrader = ContractName("L2ComplexUpgrader.sol", "L2ComplexUpgrader");
        names.genesisUpgrade = ContractName("L2GenesisUpgrade.sol", "L2GenesisUpgrade");
        names.systemContext = ContractName("SystemContext.sol", "SystemContext");
        names.wrappedBaseToken = ContractName("L2WrappedBaseToken.sol", "L2WrappedBaseToken");
        names.systemContractProxyAdmin = ContractName("SystemContractProxyAdmin.sol", "SystemContractProxyAdmin");
    }

    /// @notice Builds BytecodeInfo from an array of encoded bytecode hashes
    /// @param bytecodeHashes Array of 9 elements in order: messageRoot, l2Ntv, l2AssetRouter, bridgehub,
    ///        chainAssetHandler, beaconDeployer, interopCenter, interopHandler, assetTracker
    function buildBytecodeInfo(bytes[9] memory bytecodeHashes) public pure returns (BytecodeInfo memory info) {
        info.messageRootBytecodeInfo = bytecodeHashes[0];
        info.l2NtvBytecodeInfo = bytecodeHashes[1];
        info.l2AssetRouterBytecodeInfo = bytecodeHashes[2];
        info.bridgehubBytecodeInfo = bytecodeHashes[3];
        info.chainAssetHandlerBytecodeInfo = bytecodeHashes[4];
        info.beaconDeployerBytecodeInfo = bytecodeHashes[5];
        info.interopCenterBytecodeInfo = bytecodeHashes[6];
        info.interopHandlerBytecodeInfo = bytecodeHashes[7];
        info.assetTrackerBytecodeInfo = bytecodeHashes[8];
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
