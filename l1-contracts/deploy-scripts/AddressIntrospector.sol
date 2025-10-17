// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {IL1Bridgehub} from "contracts/bridgehub/IL1Bridgehub.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IL1BaseTokenAssetHandler} from "contracts/bridge/interfaces/IL1BaseTokenAssetHandler.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {Utils} from "./Utils.sol";

library AddressIntrospector {
    struct BridgehubAddresses {
        address bridgehubProxy;
        address assetRouter;
        address messageRoot;
        address l1CtmDeployer;
        address admin;
        address governance;
        address transparentProxyAdmin;
        address chainAssetHandler;
        address sharedBridgeLegacy; // optional legacy alias, if present on implementation
        AssetRouterAddresses assetRouterAddresses;
    }

    struct CTMAddresses {
        address ctmProxy;
        address l1GenesisUpgrade;
        address validatorTimelockPostV29;
        address legacyValidatorTimelock;
        address admin;
        address serverNotifier;
    }

    struct ZkChainAddresses {
        address zkChainProxy;
        address verifier;
        address admin;
        address pendingAdmin;
        address chainTypeManager;
        address baseToken;
        address transactionFilterer;
        address settlementLayer;
        address l1DAValidator;
        L2DACommitmentScheme l2DAValidatorScheme;
    }

    struct AssetRouterAddresses {
        address l1Nullifier;
        address l1WethToken;
        address nativeTokenVault;
        bytes32 ethTokenAssetId;
    }

    struct BaseTokenRoute {
        bytes32 baseTokenAssetId;
        address assetHandlerAddress;
        address baseTokenAddress;
    }

    struct L1ERC20BridgeAddresses {
        address l1Nullifier;
        address l1AssetRouter;
        address l1NativeTokenVault;
        address l2TokenBeacon;
        address l2Bridge;
        uint256 eraChainId;
        bytes32 l2TokenProxyBytecodeHash;
    }

    struct NonDisoverable {
        address rollupDAManager;
        address bytecodesSupplier;
        address l1RollupDAValidator;
    }

    function getBridgehubAddresses(IL1Bridgehub _bridgehub) public view returns (BridgehubAddresses memory info) {
        info.bridgehubProxy = address(_bridgehub);
        info.assetRouter = _bridgehub.assetRouter();
        info.messageRoot = address(_bridgehub.messageRoot());
        info.l1CtmDeployer = address(_bridgehub.l1CtmDeployer());
        info.admin = _getBridgehubAdmin(_bridgehub);
        info.chainAssetHandler = _bridgehub.chainAssetHandler();
        info.sharedBridgeLegacy = _tryGetSharedBridgeLegacy(address(_bridgehub));
        info.assetRouterAddresses = getAssetRouterAddresses(IL1AssetRouter(info.assetRouter));
        info.governance = IOwnable(info.bridgehubProxy).owner();
        info.transparentProxyAdmin = Utils.getProxyAdmin(info.bridgehubProxy);
    }

    function getCTMAddresses(IChainTypeManager _ctm) public view returns (CTMAddresses memory info) {
        address ctmAddr = address(_ctm);
        info.ctmProxy = ctmAddr;
        info.l1GenesisUpgrade = _ctm.l1GenesisUpgrade();
        info.validatorTimelockPostV29 = _tryAddress(ctmAddr, "validatorTimelockPostV29()");
        info.legacyValidatorTimelock = _tryAddress(ctmAddr, "validatorTimelock()");
        info.admin = _tryAddress(ctmAddr, "admin()");
        info.serverNotifier = _tryAddress(ctmAddr, "serverNotifierAddress()");
    }

    function getZkChainAddresses(IZKChain _zkChain) public view returns (ZkChainAddresses memory info) {
        info.zkChainProxy = address(_zkChain);
        info.verifier = _zkChain.getVerifier();
        info.admin = _zkChain.getAdmin();
        info.pendingAdmin = _zkChain.getPendingAdmin();
        info.chainTypeManager = _zkChain.getChainTypeManager();
        info.baseToken = _zkChain.getBaseToken();
        info.transactionFilterer = _zkChain.getTransactionFilterer();
        info.settlementLayer = _zkChain.getSettlementLayer();
        (info.l1DAValidator, info.l2DAValidatorScheme) = _zkChain.getDAValidatorPair();
    }

    function getAssetRouterAddresses(
        IL1AssetRouter _assetRouter
    ) public view returns (AssetRouterAddresses memory info) {
        info.l1Nullifier = address(_assetRouter.L1_NULLIFIER());
        info.l1WethToken = _assetRouter.L1_WETH_TOKEN();
        info.nativeTokenVault = address(_assetRouter.nativeTokenVault());
        info.ethTokenAssetId = _assetRouter.ETH_TOKEN_ASSET_ID();
    }

    function getBaseTokenRoute(
        IL1Bridgehub _bridgehub,
        uint256 _chainId
    ) public view returns (BaseTokenRoute memory info) {
        info.baseTokenAssetId = _bridgehub.baseTokenAssetId(_chainId);
        address ar = _bridgehub.assetRouter();
        info.assetHandlerAddress = IAssetRouterBase(ar).assetHandlerAddress(info.baseTokenAssetId);
        if (info.assetHandlerAddress != address(0)) {
            info.baseTokenAddress = IL1BaseTokenAssetHandler(info.assetHandlerAddress).tokenAddress(
                info.baseTokenAssetId
            );
        }
    }

    function getZkChainFacetAddresses(IZKChain _zkChain) public view returns (address[] memory) {
        return _zkChain.facetAddresses();
    }

    function getL1ERC20BridgeAddresses(
        IL1ERC20Bridge _bridge
    ) public view returns (L1ERC20BridgeAddresses memory info) {
        info.l1Nullifier = address(_bridge.L1_NULLIFIER());
        info.l1AssetRouter = address(_bridge.L1_ASSET_ROUTER());
        info.l1NativeTokenVault = address(_bridge.L1_NATIVE_TOKEN_VAULT());
        info.l2TokenBeacon = _bridge.l2TokenBeacon();
        info.l2Bridge = _bridge.l2Bridge();
        info.eraChainId = _tryUint256(address(_bridge), "ERA_CHAIN_ID()");
        info.l2TokenProxyBytecodeHash = _tryBytes32(address(_bridge), "l2TokenProxyBytecodeHash()");
    }

    /// @notice Convenience method to fetch everything for a specific chainId via a Bridgehub instance
    function getAllForChain(
        IL1Bridgehub _bridgehub,
        uint256 _chainId
    )
    external
    view
    returns (
        BridgehubAddresses memory bh,
        CTMAddresses memory ctm,
        ZkChainAddresses memory zk,
        AssetRouterAddresses memory ar,
        BaseTokenRoute memory baseRoute,
        address[] memory zkFacets,
        L1ERC20BridgeAddresses memory legacyBridge
    )
    {
        bh = getBridgehubAddresses(_bridgehub);

        address ctmAddr = _bridgehub.chainTypeManager(_chainId);
        ctm = getCTMAddresses(IChainTypeManager(ctmAddr));

        address zkAddr = _bridgehub.getZKChain(_chainId);
        zk = getZkChainAddresses(IZKChain(zkAddr));

        ar = getAssetRouterAddresses(IL1AssetRouter(payable(_bridgehub.assetRouter())));
        baseRoute = getBaseTokenRoute(_bridgehub, _chainId);
        zkFacets = getZkChainFacetAddresses(IZKChain(zkAddr));

        // Optional: if legacy ERC20 bridge is known/set on the asset router, caller can provide it separately.
    }

    function _getBridgehubAdmin(IL1Bridgehub _bridgehub) private view returns (address) {
        // Bridgehub exposes `admin()` as public variable; access via staticcall interface-less
        (bool ok, bytes memory data) = address(_bridgehub).staticcall(abi.encodeWithSignature("admin()"));
        if (ok && data.length >= 32) {
            return abi.decode(data, (address));
        }
        return address(0);
    }

    function _tryGetSharedBridgeLegacy(address _bridgehub) private view returns (address) {
        (bool ok, bytes memory data) = _bridgehub.staticcall(abi.encodeWithSignature("sharedBridge()"));
        if (ok && data.length >= 32) {
            return abi.decode(data, (address));
        }
        return address(0);
    }

    function _tryUint256(address _target, string memory _sig) private view returns (uint256 value) {
        (bool ok, bytes memory data) = _target.staticcall(abi.encodeWithSignature(_sig));
        if (ok && data.length >= 32) {
            return abi.decode(data, (uint256));
        }
        return 0;
    }

    function _tryBytes32(address _target, string memory _sig) private view returns (bytes32 value) {
        (bool ok, bytes memory data) = _target.staticcall(abi.encodeWithSignature(_sig));
        if (ok && data.length >= 32) {
            return abi.decode(data, (bytes32));
        }
        return bytes32(0);
    }

    function _tryAddress(address _target, string memory _sig) private view returns (address value) {
        (bool ok, bytes memory data) = _target.staticcall(abi.encodeWithSignature(_sig));
        if (ok && data.length >= 32) {
            return abi.decode(data, (address));
        }
        return address(0);
    }
}
