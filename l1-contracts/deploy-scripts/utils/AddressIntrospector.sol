// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";

import {SemVer} from "contracts/common/libraries/SemVer.sol";

import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IZKChainBase} from "contracts/state-transition/chain-interfaces/IZKChainBase.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IBaseTokenAssetHandler} from "contracts/bridge/interfaces/IBaseTokenAssetHandler.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {Utils} from "../utils/Utils.sol";
import {
    L2_BRIDGEHUB_ADDR,
    L2_MESSAGE_ROOT_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {GenesisFacet} from "contracts/upgrades/registry/RegistryTypes.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {NativeTokenVaultBase} from "contracts/bridge/ntv/NativeTokenVaultBase.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {
    CoreDeployedAddresses,
    BridgehubAddresses,
    BridgehubContracts,
    ZkChainAddresses,
    StateTransitionDeployedAddresses,
    BridgesDeployedAddresses,
    BridgeContracts,
    CTMDeployedAddresses,
    CTMAdminAddresses
} from "./Types.sol";
import {ProtocolVersionFeatures} from "./ProtocolVersionFeatures.sol";
import {StateTransitionContracts, Verifiers, Facets} from "contracts/common/StateTransitionTypes.sol";
import {DeployCTML1OrGateway} from "../ctm/DeployCTML1OrGateway.sol";

/// @dev `getDAValidatorPair()`'s second return value changed meaning when
/// `ZKChainStorage.l2DAValidator` (an address) was replaced by the packed
/// `l2DACommitmentScheme` enum: the getter went from returning `s.l2DAValidator` to
/// returning `s.l2DACommitmentScheme`. Declaring the second value as `uint256` lets both
/// layouts decode without reverting, so the caller can interpret it by release instead of
/// having the ABI decoder reject a live chain's real answer.
interface IZKChainDAValidatorPairRaw {
    function getDAValidatorPair() external view returns (address l1DAValidator, uint256 l2Value);
}

/// @dev The per-chain migration onto `l2DACommitmentScheme` happens at a different release
/// for each CTM flavour, so one boundary cannot describe both:
///   * ZKsync-OS chains are migrated by `L1ZKsyncOSV30Upgrade`, at v30;
///   * Era chains by `SettlementLayerV31UpgradeBase` (under `if (!s.zksyncOS)`), at v31.
/// Below its own boundary a chain still answers with an `l2DAValidator` address and has no
/// scheme at all. The chain cannot be asked which flavour it is — `getZKsyncOS()` was
/// introduced in v31 and reverts on every earlier diamond, as does `ctm.isZKsyncOS()` — so
/// v30, the one release where the two disagree, is resolved from the value itself.
uint256 constant ZKSYNC_OS_L2_DA_SCHEME_MINOR = 30;
uint256 constant ERA_L2_DA_SCHEME_MINOR = 31;

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
        L1AssetRouter assetRouter = L1AssetRouter(_assetRouter);

        address l1NullifierProxy = address(assetRouter.L1_NULLIFIER());
        address l1NativeTokenVaultProxy = address(assetRouter.nativeTokenVault());
        address l1InteropHandlerProxy = L1Nullifier(l1NullifierProxy).l1InteropHandler();

        require(l1NativeTokenVaultProxy != address(0), "NativeTokenVault address is zero");
        NativeTokenVaultBase ntv = NativeTokenVaultBase(l1NativeTokenVaultProxy);
        address bridgedTokenBeacon = address(ntv.bridgedTokenBeacon());
        address bridgedStandardERC20Implementation = bridgedTokenBeacon != address(0)
            ? UpgradeableBeacon(bridgedTokenBeacon).implementation()
            : address(0);

        BridgeContracts memory proxies = BridgeContracts({
            l1AssetRouter: _assetRouter,
            l1Nullifier: l1NullifierProxy,
            l1NativeTokenVault: l1NativeTokenVaultProxy,
            l1InteropHandler: l1InteropHandlerProxy
        });
        BridgeContracts memory implementations = BridgeContracts({
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

    // ============ CTM Addresses ============

    function getCTMAddresses(ChainTypeManager _ctm) public view returns (CTMDeployedAddresses memory info) {
        address ctmAddr = address(_ctm);
        ChainTypeManager ctm = ChainTypeManager(ctmAddr);

        address validatorTimelock = ctm.validatorTimelockPostV29();

        // The release registry only exists on the CTM from v35 on — every earlier
        // implementation has no `currentRelease` getter at all — so it is read only off a
        // registry-era CTM and reported as zero otherwise.
        address currentRelease = ctm.protocolVersion() >= SemVer.packSemVer(0, 35, 0)
            ? ctm.currentRelease()
            : address(0);
        Facets memory facets;
        address verifier;
        address genesisUpgrade;
        if (currentRelease != address(0)) {
            (facets, verifier, genesisUpgrade) = _getReleaseMembers(ICTMRelease(currentRelease));
        } else {
            facets = _getFacetsFromUptoDateZkChain(ctm);
            verifier = _getVerifierFromUptoDateZkChain(ctm);
            genesisUpgrade = ctm.l1GenesisUpgrade();
        }
        (address verifierFflonk, address verifierPlonk) = _getSubVerifiers(verifier);
        address bytecodesSupplier = ctm.L1_BYTECODES_SUPPLIER();

        // Note: daAddresses is left zero-initialized (Solidity default)
        info.stateTransition = StateTransitionDeployedAddresses({
            proxies: StateTransitionContracts({
                chainTypeManager: ctmAddr,
                serverNotifier: ctm.serverNotifierAddress(),
                validatorTimelock: validatorTimelock,
                bytecodesSupplier: bytecodesSupplier,
                permissionlessValidator: ctm.PERMISSIONLESS_VALIDATOR(),
                interopFeeManager: _getInteropFeeManager(ctm)
            }),
            implementations: StateTransitionContracts({
                chainTypeManager: Utils.getImplementation(ctmAddr),
                serverNotifier: address(0),
                validatorTimelock: address(0),
                bytecodesSupplier: address(0),
                permissionlessValidator: address(0),
                interopFeeManager: address(0)
            }),
            verifiers: Verifiers({verifier: verifier, verifierFflonk: verifierFflonk, verifierPlonk: verifierPlonk}),
            facets: facets,
            genesisUpgrade: genesisUpgrade,
            chainTypeManagerProxyAdmin: Utils.getProxyAdminAddress(ctmAddr),
            currentRelease: currentRelease
        });
        info.admin = CTMAdminAddresses({
            transparentProxyAdmin: Utils.getProxyAdminAddress(ctmAddr),
            governance: IOwnable(ctmAddr).owner(),
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
        (address l1DAValidator, L2DACommitmentScheme l2DAValidatorScheme) = readDAValidatorPair(_zkChain);

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
        address zkChain = getUptoDateZkChainAddress(_ctm);
        if (zkChain == address(0)) {
            revert NoUptoDateZkChainFound();
        }
        return getZkChainAddresses(IZKChain(zkChain));
    }

    /// @notice The first chain of `_ctm` at the CTM's protocol version.
    /// @param _ctm The CTM whose chains are searched.
    /// @return The chain's diamond, or `address(0)` when no chain of `_ctm` is at its version.
    function getUptoDateZkChainAddress(IChainTypeManager _ctm) public view returns (address) {
        IBridgehubBase bridgehub = IBridgehubBase(_ctm.BRIDGE_HUB());
        uint256 protocolVersion = _ctm.protocolVersion();
        address[] memory zkChains = bridgehub.getAllZKChains();

        for (uint256 i = 0; i < zkChains.length; i++) {
            IZKChain zkChain = IZKChain(zkChains[i]);
            address chainCTM;
            try zkChain.getChainTypeManager() returns (address result) {
                chainCTM = result;
            } catch {
                continue;
            }
            if (chainCTM == address(_ctm) && zkChain.getProtocolVersion() == protocolVersion) {
                return address(zkChain);
            }
        }
        return address(0);
    }

    /// @notice A registered chain to read ecosystem-wide values off (its rollup L1 DA validator and
    /// chain admin). Any registered chain will do; the first is taken. Returns `address(0)` for a chainless ecosystem.
    function getRepresentativeZkChain(address _bridgehubProxy) public view returns (address) {
        require(_bridgehubProxy != address(0) && _bridgehubProxy.code.length > 0, "Bridgehub contract does not exist");

        address[] memory zkChains = IL1Bridgehub(_bridgehubProxy).getAllZKChains();
        if (zkChains.length == 0) {
            return address(0);
        }
        return zkChains[0];
    }

    /// @notice `_zkChain.getDAValidatorPair()`, read so that it decodes on any release.
    /// @dev `getZkChainAddresses` is called on the bridgehub's first chain, whichever release it is on.
    /// @param _zkChain The chain to read.
    /// @return l1DAValidator The chain's L1 DA validator.
    /// @return l2DAValidatorScheme The chain's L2 DA commitment scheme, `NONE` before it has one.
    function readDAValidatorPair(
        IZKChain _zkChain
    ) internal view returns (address l1DAValidator, L2DACommitmentScheme l2DAValidatorScheme) {
        (, uint256 minor, ) = _zkChain.getSemverProtocolVersion();
        uint256 l2Value;
        (l1DAValidator, l2Value) = IZKChainDAValidatorPairRaw(address(_zkChain)).getDAValidatorPair();
        l2DAValidatorScheme = l2DACommitmentSchemeFromRaw(minor, l2Value);
    }

    /// @notice Interpret the second value of `getDAValidatorPair()` for a chain at protocol
    /// version minor `_minor`.
    /// @dev From `ERA_L2_DA_SCHEME_MINOR` on, every flavour has migrated, so the value is the
    /// scheme; an out-of-range value there means corrupt storage and the conversion reverts,
    /// which is what we want. Below it a chain may not have migrated yet (none has below
    /// `ZKSYNC_OS_L2_DA_SCHEME_MINOR`; at it, ZKsync-OS chains have and Era chains have not), and an
    /// un-migrated chain reports its `l2DAValidator` address. Those are separated by magnitude — a
    /// scheme is at most `type(L2DACommitmentScheme).max`, an address that low would have to be a
    /// precompile. An un-migrated chain has no scheme, so it is reported as `NONE`, which is also
    /// the value its v31 upgrade will write before the chain admin sets the pair again.
    /// @param _minor The chain's protocol version minor.
    /// @param _l2Value The second word `getDAValidatorPair()` returned.
    function l2DACommitmentSchemeFromRaw(
        uint256 _minor,
        uint256 _l2Value
    ) internal pure returns (L2DACommitmentScheme) {
        if (_minor >= ERA_L2_DA_SCHEME_MINOR || _l2Value <= uint256(type(L2DACommitmentScheme).max)) {
            return L2DACommitmentScheme(_l2Value);
        }
        return L2DACommitmentScheme.NONE;
    }

    // ============ Private Helpers ============

    /// @notice Returns the CTM's interop fee manager, so that a later release keeps the manager holding the chains'
    /// prepaid balances; zero before the release that introduced it.
    /// @param _ctm The CTM being introspected.
    function _getInteropFeeManager(ChainTypeManager _ctm) internal view returns (address) {
        if (!ProtocolVersionFeatures.has(_ctm.protocolVersion(), ProtocolVersionFeatures.CTM_INTEROP_FEE_MANAGER)) {
            return address(0);
        }
        return _ctm.L1_INTEROP_FEE_MANAGER();
    }

    function _getVerifierFromUptoDateZkChain(ChainTypeManager _ctm) private view returns (address) {
        address zkChainAddr = getUptoDateZkChainAddress(_ctm);
        if (zkChainAddr == address(0)) {
            return address(0);
        }
        return address(IZKChain(zkChainAddr).getVerifier());
    }

    /// @notice The members of a registry-era CTM's live release: its facets (by name), DiamondInit,
    ///         verifier and genesis engine. Read off the release rather than a chain, because the
    ///         release IS the CTM's state and a chain may lag behind it.
    function _getReleaseMembers(
        ICTMRelease _release
    ) private view returns (Facets memory facets, address verifier, address genesisUpgrade) {
        GenesisFacet[] memory rows = _release.genesisFacets();
        for (uint256 i = 0; i < rows.length; i++) {
            _setFacetByName(facets, rows[i].facet);
        }
        facets.diamondInit = _release.diamondInit();
        verifier = _release.verifier();
        // slither-disable-next-line unused-return
        (genesisUpgrade, , ) = _release.genesisParams();
    }

    function _getFacetsFromUptoDateZkChain(ChainTypeManager _ctm) private view returns (Facets memory facets) {
        address zkChainAddr = getUptoDateZkChainAddress(_ctm);
        if (zkChainAddr == address(0)) {
            return facets;
        }

        IGetters.Facet[] memory facetList = IZKChain(zkChainAddr).facets();

        for (uint256 j = 0; j < facetList.length; j++) {
            _setFacetByName(facets, facetList[j].addr);
        }
    }

    /// @notice Files `_facet` under the `Facets` field its self-reported name selects; a facet
    ///         with no field of its own is left out.
    function _setFacetByName(Facets memory _facets, address _facet) private view {
        bytes32 nameHash = keccak256(bytes(IZKChainBase(_facet).getName()));

        if (nameHash == keccak256(bytes("AdminFacet"))) {
            _facets.adminFacet = _facet;
        } else if (nameHash == keccak256(bytes("MailboxFacet"))) {
            _facets.mailboxFacet = _facet;
        } else if (nameHash == keccak256(bytes("ExecutorFacet"))) {
            _facets.executorFacet = _facet;
        } else if (nameHash == keccak256(bytes("GettersFacet"))) {
            _facets.gettersFacet = _facet;
        } else if (nameHash == keccak256(bytes("MigratorFacet"))) {
            _facets.migratorFacet = _facet;
        } else if (nameHash == keccak256(bytes("CommitterFacet"))) {
            _facets.committerFacet = _facet;
        }
    }

    /// @notice Get fflonk and plonk sub-verifiers from a ZKsyncOS dual verifier
    /// @param _verifier The verifier address
    function _getSubVerifiers(address _verifier) private view returns (address fflonk, address plonk) {
        return DeployCTML1OrGateway.getSubVerifiers(_verifier);
    }
}
