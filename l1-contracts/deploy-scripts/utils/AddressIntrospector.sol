// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {IL1Bridgehub} from "contracts/bridgehub/IL1Bridgehub.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IL1BaseTokenAssetHandler} from "contracts/bridge/interfaces/IL1BaseTokenAssetHandler.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {Utils} from "../utils/Utils.sol";

library AddressIntrospector {
    struct BridgehubAddresses {
        address bridgehubProxy;
        address assetRouter;
        address messageRoot;
        address l1CtmDeployer;
        address admin;
        address governance;
        address chainRegistrationSenderProxy;
        address transparentProxyAdmin;
        address chainAssetHandler;
        address interopCenterProxy;
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
        address governance;
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
    }

    function getBridgehubAddresses(IL1Bridgehub _bridgehub) public view returns (BridgehubAddresses memory info) {
        info.bridgehubProxy = address(_bridgehub);
        info.assetRouter = address(_bridgehub.assetRouter());
        info.messageRoot = address(_bridgehub.messageRoot());
        info.l1CtmDeployer = address(_bridgehub.l1CtmDeployer());
        info.admin = address(_bridgehub.admin());
        info.chainAssetHandler = _bridgehub.chainAssetHandler();
        if (info.assetRouter != address(0)) {
            info.assetRouterAddresses = getAssetRouterAddresses(IL1AssetRouter(info.assetRouter));
        }
        info.governance = IOwnable(info.bridgehubProxy).owner();
        info.transparentProxyAdmin = Utils.getProxyAdmin(info.bridgehubProxy);
    }

    function getCTMAddresses(ChainTypeManagerBase _ctm) public view returns (CTMAddresses memory info) {
        address ctmAddr = address(_ctm);
        info.ctmProxy = ctmAddr;
        info.l1GenesisUpgrade = _ctm.l1GenesisUpgrade();
        info.validatorTimelockPostV29 = _tryAddress(ctmAddr, "validatorTimelockPostV29()");
        info.legacyValidatorTimelock = _ctm.validatorTimelock();
        info.admin = _ctm.admin();
        info.governance = IOwnable(ctmAddr).owner();
        info.serverNotifier = _ctm.serverNotifierAddress();
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
        (uint256 major, uint256 minor, uint256 patch) = _zkChain.getSemverProtocolVersion();
        if (minor >= 29) {
            (info.l1DAValidator, info.l2DAValidatorScheme) = _zkChain.getDAValidatorPair();
        } else {
            (bool ok, bytes memory data) = address(_zkChain).staticcall(
                abi.encodeWithSignature("getDAValidatorPair()")
            );
            if (ok && data.length >= 32) {
                (info.l1DAValidator, ) = abi.decode(data, (address, address));
            }
        }
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
        info.assetHandlerAddress = IAssetRouterBase(_bridgehub.assetRouter()).assetHandlerAddress(
            info.baseTokenAssetId
        );
        if (info.assetHandlerAddress != address(0)) {
            info.baseTokenAddress = IL1BaseTokenAssetHandler(info.assetHandlerAddress).tokenAddress(
                info.baseTokenAssetId
            );
        }
    }

    function getZkChainFacetAddresses(IZKChain _zkChain) public view returns (address[] memory) {
        return _zkChain.facetAddresses();
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
        return _getAllForChainInternal(_bridgehub, _chainId);
    }

    function _getAllForChainInternal(
        IL1Bridgehub _bridgehub,
        uint256 _chainId
    )
        private
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
        ctm = getCTMAddresses(ChainTypeManagerBase(ctmAddr));

        address zkAddr = _bridgehub.getZKChain(_chainId);
        zk = getZkChainAddresses(IZKChain(zkAddr));

        ar = getAssetRouterAddresses(IL1AssetRouter(payable(address(_bridgehub.assetRouter()))));
        baseRoute = getBaseTokenRoute(_bridgehub, _chainId);
        zkFacets = getZkChainFacetAddresses(IZKChain(zkAddr));

        // Optional: if legacy ERC20 bridge is known/set on the asset router, caller can provide it separately.
    }

    function _tryAddress(address _target, string memory _sig) private view returns (address value) {
        (bool ok, bytes memory data) = _target.staticcall(abi.encodeWithSignature(_sig));
        if (ok && data.length >= 32) {
            return abi.decode(data, (address));
        }
        return address(0);
    }
}
