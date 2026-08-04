// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";

import {SemVer} from "contracts/common/libraries/SemVer.sol";

import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IZKChainBase} from "contracts/state-transition/chain-interfaces/IZKChainBase.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IBaseTokenAssetHandler} from "contracts/bridge/interfaces/IBaseTokenAssetHandler.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {Utils} from "../utils/Utils.sol";
import {
    L2_BRIDGEHUB_ADDR,
    L2_ASSET_ROUTER_ADDR,
    L2_MESSAGE_ROOT_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {NativeTokenVaultBase} from "contracts/bridge/ntv/NativeTokenVaultBase.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {
    CoreDeployedAddresses,
    BridgehubAddresses,
    BridgehubContracts,
    ZkChainAddresses,
    L2ERC20BridgeAddresses,
    StateTransitionDeployedAddresses,
    StateTransitionContracts,
    Verifiers,
    Facets,
    BridgesDeployedAddresses,
    BridgeContracts,
    CTMDeployedAddresses,
    CTMAdminAddresses,
    DataAvailabilityDeployedAddresses,
    L1SpecificStateTransitionAddresses
} from "./Types.sol";
import {DeployCTML1OrGateway} from "../ctm/DeployCTML1OrGateway.sol";

library AddressIntrospector {
    error NoUptoDateZkChainFound();

    // ============ Bridgehub Addresses ============

    function getBridgehubAddresses(IL1Bridgehub _bridgehub) public view returns (BridgehubAddresses memory info) {
        if (address(_bridgehub) == L2_BRIDGEHUB_ADDR) {
            return _getL2BridgehubAddresses();
        }
        return _getL1BridgehubAddressesInternal(_bridgehub);
    }

    function _getL1BridgehubAddressesInternal(
        IL1Bridgehub _bridgehub
    ) private view returns (BridgehubAddresses memory info) {
        address bridgehubProxy = address(_bridgehub);
        address messageRoot = address(_bridgehub.messageRoot());
        address ctmDeploymentTrackerProxy = address(_bridgehub.l1CtmDeployer());
        address chainAssetHandler = _bridgehub.chainAssetHandler();

        // Present from v31 on; zero until the ecosystem registers it.
        address chainRegistrationSenderAddr = IBridgehubBase(bridgehubProxy).chainRegistrationSender();

        BridgehubContracts memory proxies = BridgehubContracts({
            bridgehub: bridgehubProxy,
            messageRoot: messageRoot,
            ctmDeploymentTracker: ctmDeploymentTrackerProxy,
            chainAssetHandler: chainAssetHandler,
            chainRegistrationSender: chainRegistrationSenderAddr
        });
        BridgehubContracts memory implementations = BridgehubContracts({
            bridgehub: Utils.getImplementation(bridgehubProxy),
            messageRoot: Utils.getImplementation(messageRoot),
            ctmDeploymentTracker: Utils.getImplementation(ctmDeploymentTrackerProxy),
            chainAssetHandler: Utils.getImplementation(chainAssetHandler),
            chainRegistrationSender: address(0)
        });
        info = BridgehubAddresses({proxies: proxies, implementations: implementations});
    }

    function _getL2BridgehubAddresses() private view returns (BridgehubAddresses memory info) {
        IL1Bridgehub _bridgehub = IL1Bridgehub(L2_BRIDGEHUB_ADDR);
        address ctmDeploymentTrackerProxy = address(_bridgehub.l1CtmDeployer());

        BridgehubContracts memory proxies = BridgehubContracts({
            bridgehub: L2_BRIDGEHUB_ADDR,
            messageRoot: L2_MESSAGE_ROOT_ADDR,
            ctmDeploymentTracker: ctmDeploymentTrackerProxy,
            chainAssetHandler: L2_CHAIN_ASSET_HANDLER_ADDR,
            chainRegistrationSender: address(0)
        });
        BridgehubContracts memory implementations;
        info = BridgehubAddresses({proxies: proxies, implementations: implementations});
    }

    // ============ Bridge Addresses ============

    function getBridgesDeployedAddresses(
        address _assetRouter
    ) public view returns (BridgesDeployedAddresses memory info) {
        return _getBridgesDeployedAddressesInternal(_assetRouter, false);
    }

    /// @notice Bridge discovery for a v31 ecosystem: the nullifier has no `l1InteropHandler()` yet, so the
    /// interop handler is reported as absent and the upgrade deploys it.
    function getBridgesDeployedAddressesV31(
        address _assetRouter
    ) public view returns (BridgesDeployedAddresses memory info) {
        if (_assetRouter == address(0) || _assetRouter.code.length == 0) {
            return info;
        }
        return _getBridgesDeployedAddressesInternal(_assetRouter, true);
    }

    function _getBridgesDeployedAddressesInternal(
        address _assetRouter,
        bool _isPreV32
    ) private view returns (BridgesDeployedAddresses memory info) {
        L1AssetRouter assetRouter = L1AssetRouter(_assetRouter);

        address erc20BridgeProxy = address(assetRouter.legacyBridge());
        address l1NullifierProxy = address(assetRouter.L1_NULLIFIER());
        address l1NativeTokenVaultProxy = address(assetRouter.nativeTokenVault());
        // `l1InteropHandler()` only exists on the nullifier from v32 onward; skip the call for pre-v32 deployments.
        address l1InteropHandlerProxy = _isPreV32 ? address(0) : L1Nullifier(l1NullifierProxy).l1InteropHandler();

        require(l1NativeTokenVaultProxy != address(0), "NativeTokenVault address is zero");
        NativeTokenVaultBase ntv = NativeTokenVaultBase(l1NativeTokenVaultProxy);
        address bridgedTokenBeacon = address(ntv.bridgedTokenBeacon());
        address bridgedStandardERC20Implementation = bridgedTokenBeacon != address(0)
            ? UpgradeableBeacon(bridgedTokenBeacon).implementation()
            : address(0);

        BridgeContracts memory proxies = BridgeContracts({
            erc20Bridge: erc20BridgeProxy,
            l1AssetRouter: _assetRouter,
            l1Nullifier: l1NullifierProxy,
            l1NativeTokenVault: l1NativeTokenVaultProxy,
            l1InteropHandler: l1InteropHandlerProxy
        });
        BridgeContracts memory implementations = BridgeContracts({
            erc20Bridge: Utils.getImplementation(erc20BridgeProxy),
            l1AssetRouter: Utils.getImplementation(_assetRouter),
            l1Nullifier: Utils.getImplementation(l1NullifierProxy),
            l1NativeTokenVault: Utils.getImplementation(l1NativeTokenVaultProxy),
            l1InteropHandler: l1InteropHandlerProxy == address(0)
                ? address(0)
                : Utils.getImplementation(l1InteropHandlerProxy)
        });

        info = BridgesDeployedAddresses({
            proxies: proxies,
            implementations: implementations,
            bridgedStandardERC20Implementation: bridgedStandardERC20Implementation,
            bridgedTokenBeacon: bridgedTokenBeacon,
            l1WethToken: assetRouter.L1_WETH_TOKEN(),
            ethTokenAssetId: assetRouter.ETH_TOKEN_ASSET_ID()
        });
    }

    // ============ Core Deployed Addresses ============

    function getCoreDeployedAddresses(
        address _bridgehubProxy
    ) public view returns (CoreDeployedAddresses memory coreAddresses) {
        coreAddresses.bridgehub = getBridgehubAddresses(IL1Bridgehub(_bridgehubProxy));
        address assetRouter = address(IL1Bridgehub(_bridgehubProxy).assetRouter());
        coreAddresses.bridges = getBridgesDeployedAddresses(assetRouter);
        coreAddresses.shared.transparentProxyAdmin = Utils.getProxyAdminAddress(_bridgehubProxy);
        coreAddresses.shared.bridgehubAdmin = address(IL1Bridgehub(_bridgehubProxy).admin());
        coreAddresses.shared.governance = IOwnable(_bridgehubProxy).owner();
    }

    /// @notice Discovery for a v31 ecosystem: the bridgehub already exposes `chainRegistrationSender`,
    /// but the nullifier has no `l1InteropHandler` yet — that arrives with the v32 implementations.
    /// @dev Calling `getCoreDeployedAddresses` on a v31 ecosystem reverts on the missing nullifier getter.
    function getCoreDeployedAddressesV31(
        address _bridgehubProxy
    ) public view returns (CoreDeployedAddresses memory coreAddresses) {
        require(_bridgehubProxy != address(0), "Bridgehub address is zero");
        require(_bridgehubProxy.code.length > 0, "Bridgehub has no code");

        coreAddresses.bridgehub = getBridgehubAddresses(IL1Bridgehub(_bridgehubProxy));

        address assetRouter = address(IL1Bridgehub(_bridgehubProxy).assetRouter());
        require(assetRouter != address(0), "AssetRouter address is zero");
        require(assetRouter.code.length > 0, "AssetRouter has no code");

        coreAddresses.bridges = getBridgesDeployedAddressesV31(assetRouter);
        coreAddresses.shared.transparentProxyAdmin = Utils.getProxyAdminAddress(_bridgehubProxy);
        coreAddresses.shared.bridgehubAdmin = address(IL1Bridgehub(_bridgehubProxy).admin());
        coreAddresses.shared.governance = IOwnable(_bridgehubProxy).owner();
    }

    // ============ CTM Addresses ============

    function getCTMAddresses(ChainTypeManagerBase _ctm) public view returns (CTMDeployedAddresses memory info) {
        return _getCTMAddressesInternal(address(_ctm), _ctm.isZKsyncOS(), false);
    }

    /// @notice CTM discovery for a v31 ecosystem.
    /// @dev The sub-verifier getters differ: a v31 ZKsync OS verifier exposes `fflonkVerifiers(i)` /
    /// `plonkVerifiers(i)`, while this release's exposes a single `PLONK_VERIFIER()`. Reading the v32 shape
    /// off a v31 verifier reverts, and the upgrade deploys fresh verifiers anyway, so the sub-verifiers are
    /// reported as absent — the same thing the v29 path used to do.
    function getCTMAddressesV31(
        address _ctmAddr,
        bool _isZKsyncOS
    ) public view returns (CTMDeployedAddresses memory info) {
        if (_ctmAddr == address(0) || _ctmAddr.code.length == 0) {
            return info;
        }
        return _getCTMAddressesInternal(_ctmAddr, _isZKsyncOS, true);
    }

    function _getCTMAddressesInternal(
        address _ctmAddr,
        bool _isZKsyncOS,
        bool _isPreV32
    ) private view returns (CTMDeployedAddresses memory info) {
        ChainTypeManagerBase ctm = ChainTypeManagerBase(_ctmAddr);

        address validatorTimelock = ctm.validatorTimelockPostV29();

        Facets memory facets = _getFacetsFromUptoDateZkChain(ctm);
        address verifier = _getVerifierFromUptoDateZkChain(ctm);
        // The bytecodes supplier and the permissionless validator exist from v31 on, which is the oldest
        // ecosystem this release can upgrade; the sub-verifier shape does not (see `getCTMAddressesV31`).
        (address verifierFflonk, address verifierPlonk) = _isPreV32
            ? (address(0), address(0))
            : _getSubVerifiers(verifier, _isZKsyncOS);
        address bytecodesSupplier = ctm.L1_BYTECODES_SUPPLIER();

        // Note: daAddresses is left zero-initialized (Solidity default)
        info.stateTransition = StateTransitionDeployedAddresses({
            proxies: StateTransitionContracts({
                chainTypeManager: _ctmAddr,
                serverNotifier: ctm.serverNotifierAddress(),
                validatorTimelock: validatorTimelock,
                bytecodesSupplier: bytecodesSupplier,
                permissionlessValidator: ctm.PERMISSIONLESS_VALIDATOR()
            }),
            implementations: StateTransitionContracts({
                chainTypeManager: Utils.getImplementation(_ctmAddr),
                serverNotifier: address(0),
                validatorTimelock: address(0),
                bytecodesSupplier: address(0),
                permissionlessValidator: address(0)
            }),
            verifiers: Verifiers({verifier: verifier, verifierFflonk: verifierFflonk, verifierPlonk: verifierPlonk}),
            facets: facets,
            genesisUpgrade: ctm.l1GenesisUpgrade(),
            defaultUpgrade: address(0),
            chainTypeManagerProxyAdmin: Utils.getProxyAdminAddress(_ctmAddr)
        });
        info.l1Specific = L1SpecificStateTransitionAddresses({
            legacyValidatorTimelock: ctm.validatorTimelock(),
            eraDiamondProxy: address(0)
        });
        info.admin = CTMAdminAddresses({
            transparentProxyAdmin: Utils.getProxyAdminAddress(_ctmAddr),
            governance: IOwnable(_ctmAddr).owner(),
            accessControlRestrictionAddress: address(0),
            eip7702Checker: address(0),
            chainTypeManagerAdmin: address(0),
            chainTypeManagerOwner: address(0)
        });
    }

    // ============ ZkChain Addresses ============

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

        (, uint256 minor, ) = _zkChain.getSemverProtocolVersion();
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

        IL1Bridgehub bridgehub = address(_bridgehub) == address(0) ? IL1Bridgehub(_zkChain.getBridgehub()) : _bridgehub;

        bytes32 baseTokenAssetId = bridgehub.baseTokenAssetId(chainId);
        address assetHandlerAddress = IAssetRouterBase(bridgehub.assetRouter()).assetHandlerAddress(baseTokenAssetId);
        address baseTokenAddress = IBaseTokenAssetHandler(assetHandlerAddress).tokenAddress(baseTokenAssetId);

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
            governance: IOwnable(address(bridgehub)).owner(),
            accessControlRestrictionAddress: address(0),
            diamondProxy: address(_zkChain),
            chainProxyAdmin: address(0),
            l2LegacySharedBridge: address(0)
        });
    }

    function getUptoDateZkChainAddresses(IChainTypeManager _ctm) public view returns (ZkChainAddresses memory info) {
        IBridgehubBase _bridgehub = IBridgehubBase(_ctm.BRIDGE_HUB());
        uint256 protocolVersion = _ctm.protocolVersion();
        address[] memory zkChains = _bridgehub.getAllZKChains();

        for (uint256 i = 0; i < zkChains.length; i++) {
            IZKChain zkChain = IZKChain(zkChains[i]);
            address chainCTM;
            try zkChain.getChainTypeManager() returns (address result) {
                chainCTM = result;
            } catch {
                continue;
            }
            if (chainCTM == address(_ctm) && zkChain.getProtocolVersion() == protocolVersion) {
                return getZkChainAddresses(zkChain);
            }
        }
        revert NoUptoDateZkChainFound();
    }

    // ============ Legacy Bridge Addresses ============

    function getLegacyBridgeAddress(address _assetRouter) public view returns (address legacyBridge) {
        IL1Nullifier nullifier = IL1AssetRouter(_assetRouter).L1_NULLIFIER();
        legacyBridge = address(nullifier.legacyBridge());
    }

    function getLegacyBridgeAddresses(address _assetRouter) public view returns (L2ERC20BridgeAddresses memory info) {
        address legacyBridge = getLegacyBridgeAddress(_assetRouter);
        if (legacyBridge == address(0)) {
            return info;
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

    /// @notice Whether the ecosystem predates v32, i.e. its nullifier has no `l1InteropHandler` getter and
    /// the upgrade still has to deploy and wire the interop handler.
    /// @dev Reverts on an ecosystem with no registered chains: there is nothing to read a protocol version
    /// from, and answering anyway would silently pick a discovery path. Callers decide what such an
    /// ecosystem means for them — see `hasRegisteredChains`.
    function shouldUsePreV32Introspection(address _bridgehubProxy) public view returns (bool) {
        require(_bridgehubProxy != address(0) && _bridgehubProxy.code.length > 0, "Bridgehub contract does not exist");

        address[] memory zkChains = IL1Bridgehub(_bridgehubProxy).getAllZKChains();
        require(zkChains.length != 0, "Ecosystem has no chain to read a protocol version from");

        return IZKChain(zkChains[0]).getProtocolVersion() < SemVer.packSemVer(0, 32, 0);
    }

    /// @notice Whether the ecosystem has at least one registered chain, i.e. whether its protocol version
    /// can be inspected at all.
    function hasRegisteredChains(address _bridgehubProxy) public view returns (bool) {
        require(_bridgehubProxy != address(0) && _bridgehubProxy.code.length > 0, "Bridgehub contract does not exist");
        return IL1Bridgehub(_bridgehubProxy).getAllZKChains().length != 0;
    }

    /// @notice Convenience method to fetch everything for a specific chainId
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

    // ============ Private Helpers ============

    function _getUptoDateZkChainAddress(ChainTypeManagerBase _ctm) internal view returns (address) {
        IBridgehubBase bridgehub = IBridgehubBase(_ctm.BRIDGE_HUB());
        uint256 protocolVersion = _ctm.protocolVersion();
        address[] memory zkChains = bridgehub.getAllZKChains();
        address ctmAddr = address(_ctm);

        for (uint256 i = 0; i < zkChains.length; i++) {
            IZKChain zkChain = IZKChain(zkChains[i]);
            address chainCTM;
            try zkChain.getChainTypeManager() returns (address result) {
                chainCTM = result;
            } catch {
                continue;
            }
            if (chainCTM == ctmAddr && zkChain.getProtocolVersion() == protocolVersion) {
                return address(zkChain);
            }
        }
        return address(0);
    }

    function _getVerifierFromUptoDateZkChain(ChainTypeManagerBase _ctm) private view returns (address) {
        address zkChainAddr = _getUptoDateZkChainAddress(_ctm);
        if (zkChainAddr == address(0)) {
            return address(0);
        }
        return address(IZKChain(zkChainAddr).getVerifier());
    }

    function _getFacetsFromUptoDateZkChain(ChainTypeManagerBase _ctm) private view returns (Facets memory facets) {
        address zkChainAddr = _getUptoDateZkChainAddress(_ctm);
        if (zkChainAddr == address(0)) {
            return facets;
        }

        IGetters.Facet[] memory facetList = IZKChain(zkChainAddr).facets();

        for (uint256 j = 0; j < facetList.length; j++) {
            address facetAddr = facetList[j].addr;
            string memory name = IZKChainBase(facetAddr).getName();
            bytes32 nameHash = keccak256(bytes(name));

            if (nameHash == keccak256(bytes("AdminFacet"))) {
                facets.adminFacet = facetAddr;
            } else if (nameHash == keccak256(bytes("MailboxFacet"))) {
                facets.mailboxFacet = facetAddr;
            } else if (nameHash == keccak256(bytes("ExecutorFacet"))) {
                facets.executorFacet = facetAddr;
            } else if (nameHash == keccak256(bytes("GettersFacet"))) {
                facets.gettersFacet = facetAddr;
            } else if (nameHash == keccak256(bytes("MigratorFacet"))) {
                facets.migratorFacet = facetAddr;
            } else if (nameHash == keccak256(bytes("CommitterFacet"))) {
                facets.committerFacet = facetAddr;
            }
        }
    }

    function _tryAddress(address _target, string memory _sig) private view returns (address) {
        (bool ok, bytes memory data) = _target.staticcall(abi.encodeWithSignature(_sig));
        if (ok && data.length >= 32) {
            return abi.decode(data, (address));
        }
        return address(0);
    }

    /// @notice Get the sub-verifiers used by the active verifier.
    /// @param _verifier The verifier address
    /// @param _isZKsyncOS If true, returns only the ZKsync OS PLONK verifier; otherwise both Era verifiers.
    function _getSubVerifiers(
        address _verifier,
        bool _isZKsyncOS
    ) private view returns (address fflonk, address plonk) {
        return DeployCTML1OrGateway.getSubVerifiers(_verifier, _isZKsyncOS);
    }
}
