// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IMessageRoot} from "contracts/core/message-root/IMessageRoot.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IL1BaseTokenAssetHandler} from "contracts/bridge/interfaces/IL1BaseTokenAssetHandler.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {Utils} from "../utils/Utils.sol";
import {L2_BRIDGEHUB_ADDR, L2_ASSET_ROUTER_ADDR, L2_MESSAGE_ROOT_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_ASSET_TRACKER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {BridgehubAddresses, BridgehubContracts, ZkChainAddresses, L2ERC20BridgeAddresses, StateTransitionDeployedAddresses, StateTransitionContracts, Verifiers, Facets, BridgesDeployedAddresses, BridgeContracts, CTMDeployedAddresses, CTMAdminAddresses, DataAvailabilityDeployedAddresses} from "./Types.sol";

library AddressIntrospector {
    function getBridgehubAddresses(IL1Bridgehub _bridgehub) public view returns (BridgehubAddresses memory info) {
        if (address(_bridgehub) == L2_BRIDGEHUB_ADDR) {
            return getL2BridgehubAddresses();
        }
        return getL1BridgehubAddress(_bridgehub);
    }

    function getL1BridgehubAddress(IL1Bridgehub _bridgehub) public view returns (BridgehubAddresses memory info) {
        address bridgehubProxy = address(_bridgehub);
        address messageRoot = address(_bridgehub.messageRoot());
        address ctmDeploymentTrackerProxy = address(_bridgehub.l1CtmDeployer());
        address chainAssetHandler = _bridgehub.chainAssetHandler();

        info = BridgehubAddresses({
            proxies: BridgehubContracts({
                bridgehub: bridgehubProxy,
                messageRoot: messageRoot,
                ctmDeploymentTracker: ctmDeploymentTrackerProxy,
                chainAssetHandler: chainAssetHandler,
                chainRegistrationSender: address(0),
                assetTracker: address(0)
            }),
            implementations: BridgehubContracts({
                bridgehub: Utils.getImplementation(bridgehubProxy),
                messageRoot: Utils.getImplementation(messageRoot),
                ctmDeploymentTracker: Utils.getImplementation(ctmDeploymentTrackerProxy),
                chainAssetHandler: Utils.getImplementation(chainAssetHandler),
                chainRegistrationSender: address(0),
                assetTracker: address(0)
            }),
            bridgehubAdmin: address(_bridgehub.admin()),
            governance: IOwnable(bridgehubProxy).owner(),
            transparentProxyAdmin: Utils.getProxyAdmin(bridgehubProxy)
        });
    }

    function getL2BridgehubAddresses() public view returns (BridgehubAddresses memory info) {
        IL1Bridgehub _bridgehub = IL1Bridgehub(L2_BRIDGEHUB_ADDR);
        address ctmDeploymentTrackerProxy = address(_bridgehub.l1CtmDeployer());

        info = BridgehubAddresses({
            proxies: BridgehubContracts({
                bridgehub: L2_BRIDGEHUB_ADDR,
                messageRoot: L2_MESSAGE_ROOT_ADDR,
                ctmDeploymentTracker: ctmDeploymentTrackerProxy,
                chainAssetHandler: L2_CHAIN_ASSET_HANDLER_ADDR,
                chainRegistrationSender: address(0),
                assetTracker: L2_ASSET_TRACKER_ADDR
            }),
            implementations: BridgehubContracts({
                bridgehub: address(0),
                messageRoot: address(0),
                ctmDeploymentTracker: address(0),
                chainAssetHandler: address(0),
                chainRegistrationSender: address(0),
                assetTracker: address(0)
            }),
            bridgehubAdmin: address(_bridgehub.admin()),
            governance: IOwnable(L2_BRIDGEHUB_ADDR).owner(),
            transparentProxyAdmin: Utils.getProxyAdmin(L2_BRIDGEHUB_ADDR)
        });
    }

    function getCTMAddresses(ChainTypeManagerBase _ctm) public view returns (CTMDeployedAddresses memory info) {
        address ctmAddr = address(_ctm);
        address validatorTimelockPostV29 = _tryAddress(ctmAddr, "validatorTimelockPostV29()");

        info = CTMDeployedAddresses({
            stateTransition: StateTransitionDeployedAddresses({
                proxies: StateTransitionContracts({
                    chainTypeManager: ctmAddr,
                    serverNotifier: _ctm.serverNotifierAddress(),
                    validatorTimelock: validatorTimelockPostV29 != address(0)
                        ? validatorTimelockPostV29
                        : _ctm.validatorTimelock()
                }),
                implementations: StateTransitionContracts({
                    chainTypeManager: Utils.getImplementation(ctmAddr),
                    serverNotifier: address(0), // Not available from CTM directly
                    validatorTimelock: address(0) // Not available from CTM directly
                }),
                verifiers: Verifiers({
                    verifier: address(0), // Not available from CTM directly
                    verifierFflonk: address(0), // Not available from CTM directly
                    verifierPlonk: address(0) // Not available from CTM directly
                }),
                facets: Facets({
                    adminFacet: address(0), // Not available from CTM directly
                    mailboxFacet: address(0), // Not available from CTM directly
                    executorFacet: address(0), // Not available from CTM directly
                    gettersFacet: address(0), // Not available from CTM directly
                    diamondInit: address(0) // Not available from CTM directly
                }),
                genesisUpgrade: _ctm.l1GenesisUpgrade(),
                defaultUpgrade: address(0), // Not available from CTM directly
                legacyValidatorTimelock: _ctm.validatorTimelock(),
                eraDiamondProxy: address(0), // Not available from CTM directly
                bytecodesSupplier: address(0), // Not available from CTM directly
                rollupDAManager: address(0), // Not available from CTM directly
                rollupSLDAValidator: address(0) // Not available from CTM directly
            }),
            daAddresses: DataAvailabilityDeployedAddresses({
                rollupDAManager: address(0), // Not available from CTM directly
                l1RollupDAValidator: address(0), // Not available from CTM directly
                noDAValidiumL1DAValidator: address(0), // Not available from CTM directly
                availBridge: address(0), // Not available from CTM directly
                availL1DAValidator: address(0), // Not available from CTM directly
                l1BlobsDAValidatorZKsyncOS: address(0) // Not available from CTM directly
            }),
            admin: CTMAdminAddresses({
                transparentProxyAdmin: address(0), // Not available from CTM directly
                governance: address(0), // Not available from CTM directly
                accessControlRestrictionAddress: address(0), // Not available from CTM directly
                eip7702Checker: address(0), // Not available from CTM directly
                chainTypeManagerAdmin: address(0), // Not available from CTM directly
                chainTypeManagerOwner: address(0) // Not available from CTM directly
            }),
            chainAdmin: address(0) // Not available from CTM directly
        });
    }

    function getZkChainAddresses(IZKChain _zkChain) public view returns (ZkChainAddresses memory info) {
        return getZkChainAddresses(_zkChain, IL1Bridgehub(address(0)));
    }

    function getZkChainAddresses(
        IZKChain _zkChain,
        IL1Bridgehub _bridgehub
    ) public view returns (ZkChainAddresses memory info) {
        uint256 chainId = _zkChain.getChainId();
        address l1DAValidator = address(0);
        L2DACommitmentScheme l2DAValidatorScheme = L2DACommitmentScheme.NONE;

        (uint256 major, uint256 minor, uint256 patch) = _zkChain.getSemverProtocolVersion();
        if (minor > 29) {
            (l1DAValidator, l2DAValidatorScheme) = _zkChain.getDAValidatorPair();
        } else {
            (bool ok, bytes memory data) = address(_zkChain).staticcall(
                abi.encodeWithSignature("getDAValidatorPair()")
            );
            if (ok && data.length >= 32) {
                (l1DAValidator, ) = abi.decode(data, (address, address));
            }
        }

        // Get bridgehub if not provided
        IL1Bridgehub bridgehub = _bridgehub;
        if (address(_bridgehub) == address(0)) {
            bridgehub = IL1Bridgehub(_zkChain.getBridgehub());
        }

        bytes32 baseTokenAssetId = bridgehub.baseTokenAssetId(chainId);
        address assetHandlerAddress = IAssetRouterBase(bridgehub.assetRouter()).assetHandlerAddress(baseTokenAssetId);
        address baseTokenAddress = IL1BaseTokenAssetHandler(assetHandlerAddress).tokenAddress(baseTokenAssetId);

        info = ZkChainAddresses({
            chainId: chainId,
            zkChainProxy: address(_zkChain),
            chainAdmin: _zkChain.getAdmin(),
            pendingChainAdmin: _zkChain.getPendingAdmin(),
            chainTypeManager: _zkChain.getChainTypeManager(),
            baseToken: _zkChain.getBaseToken(),
            transactionFilterer: _zkChain.getTransactionFilterer(),
            settlementLayer: _zkChain.getSettlementLayer(),
            l1DAValidator: l1DAValidator,
            l2DAValidatorScheme: l2DAValidatorScheme,
            baseTokenAssetId: baseTokenAssetId,
            baseTokenAddress: baseTokenAddress,
            governance: address(0),
            accessControlRestrictionAddress: address(0),
            diamondProxy: address(_zkChain),
            chainProxyAdmin: address(0),
            l2LegacySharedBridge: address(0)
        });
    }

    error NoUptoDateZkChainFound();

    function getUptoDateZkChainAddresses(IChainTypeManager _ctm) public view returns (ZkChainAddresses memory info) {
        IBridgehubBase _bridgehub = IBridgehubBase(_ctm.BRIDGE_HUB());
        uint256 protocolVersion = _ctm.protocolVersion();
        address[] memory zkChains = _bridgehub.getAllZKChains();
        for (uint256 i = 0; i < zkChains.length; i++) {
            IZKChain zkChain = IZKChain(zkChains[i]);
            address chainCTM;
            try zkChain.getChainTypeManager() {
                chainCTM = zkChain.getChainTypeManager();
            } catch {
                continue;
            }
            if (zkChain.getChainTypeManager() != address(_ctm)) {
                continue;
            }
            uint256 zkChainProtocolVersion = zkChain.getProtocolVersion();
            if (zkChainProtocolVersion == protocolVersion) {
                return getZkChainAddresses(zkChain);
            }
        }
        revert NoUptoDateZkChainFound();
        return info;
    }

    function getBridgesDeployedAddresses(
        address _assetRouter
    ) public view returns (BridgesDeployedAddresses memory info) {
        L1AssetRouter assetRouter = L1AssetRouter(_assetRouter);

        // First get all proxy addresses
        address erc20BridgeProxy = address(assetRouter.legacyBridge());
        address l1AssetRouterProxy = _assetRouter;
        address l1NullifierProxy = address(assetRouter.L1_NULLIFIER());
        address l1NativeTokenVaultProxy = address(assetRouter.nativeTokenVault());

        info = BridgesDeployedAddresses({
            proxies: BridgeContracts({
                erc20Bridge: erc20BridgeProxy,
                l1AssetRouter: l1AssetRouterProxy,
                l1Nullifier: l1NullifierProxy,
                l1NativeTokenVault: l1NativeTokenVaultProxy
            }),
            implementations: BridgeContracts({
                erc20Bridge: Utils.getImplementation(erc20BridgeProxy),
                l1AssetRouter: Utils.getImplementation(l1AssetRouterProxy),
                l1Nullifier: Utils.getImplementation(l1NullifierProxy),
                l1NativeTokenVault: Utils.getImplementation(l1NativeTokenVaultProxy)
            }),
            bridgedStandardERC20Implementation: address(0), // Not available from asset router
            bridgedTokenBeacon: address(0), // Not available from asset router
            l1WethToken: address(0), // Not available from asset router
            ethTokenAssetId: bytes32(0) // Not available from asset router
        });
    }

    function getLegacyBridgeAddress(address _assetRouter) public view returns (address legacyBridge) {
        IL1Nullifier nullifier = IL1AssetRouter(_assetRouter).L1_NULLIFIER();
        legacyBridge = address(nullifier.legacyBridge());
    }

    function getLegacyBridgeAddresses(address _assetRouter) public view returns (L2ERC20BridgeAddresses memory info) {
        address legacyBridge = getLegacyBridgeAddress(_assetRouter);
        if (legacyBridge == address(0)) {
            return info; // Return empty struct if no legacy bridge
        }

        IL1ERC20Bridge bridge = IL1ERC20Bridge(legacyBridge);
        info = L2ERC20BridgeAddresses({
            l2TokenBeacon: bridge.l2TokenBeacon(),
            l2Bridge: bridge.l2Bridge(),
            l2TokenProxyBytecodeHash: bridge.l2TokenProxyBytecodeHash()
        });
    }

    function getEraChainId(address _assetRouter) public view returns (uint256 eraChainId) {
        return IL1AssetRouter(_assetRouter).ERA_CHAIN_ID();
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
            StateTransitionDeployedAddresses memory ctm,
            ZkChainAddresses memory zk,
            address[] memory zkFacets,
            L2ERC20BridgeAddresses memory legacyBridge,
            BridgesDeployedAddresses memory bridges
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
            StateTransitionDeployedAddresses memory ctm,
            ZkChainAddresses memory zk,
            address[] memory zkFacets,
            L2ERC20BridgeAddresses memory legacyBridge,
            BridgesDeployedAddresses memory bridges
        )
    {
        bh = getBridgehubAddresses(_bridgehub);

        address ctmAddr = _bridgehub.chainTypeManager(_chainId);
        ctm = getCTMAddresses(ChainTypeManagerBase(ctmAddr)).stateTransition;

        address zkAddr = _bridgehub.getZKChain(_chainId);
        zk = getZkChainAddresses(IZKChain(zkAddr), _bridgehub);

        zkFacets = getZkChainFacetAddresses(IZKChain(zkAddr));

        address assetRouter = address(_bridgehub.assetRouter());
        bridges = getBridgesDeployedAddresses(assetRouter);

        address legacyBridgeAddress = getLegacyBridgeAddress(assetRouter);
        if (legacyBridgeAddress != address(0)) {
            legacyBridge = getLegacyBridgeAddresses(assetRouter);
        }
    }

    function _tryAddress(address _target, string memory _sig) private view returns (address value) {
        (bool ok, bytes memory data) = _target.staticcall(abi.encodeWithSignature(_sig));
        if (ok && data.length >= 32) {
            return abi.decode(data, (address));
        }
        return address(0);
    }
}
