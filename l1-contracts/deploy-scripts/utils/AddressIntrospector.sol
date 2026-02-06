// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
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
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {Utils} from "../utils/Utils.sol";
import {L2_BRIDGEHUB_ADDR, L2_ASSET_ROUTER_ADDR, L2_MESSAGE_ROOT_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_ASSET_TRACKER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {CoreDeployedAddresses, BridgehubAddresses, BridgehubContracts, ZkChainAddresses, L2ERC20BridgeAddresses, StateTransitionDeployedAddresses, StateTransitionContracts, Verifiers, Facets, BridgesDeployedAddresses, BridgeContracts, CTMDeployedAddresses, CTMAdminAddresses, DataAvailabilityDeployedAddresses} from "./Types.sol";

library AddressIntrospector {
    function getBridgehubAddresses(IL1Bridgehub _bridgehub) public view returns (BridgehubAddresses memory info) {
        if (address(_bridgehub) == L2_BRIDGEHUB_ADDR) {
            return getL2BridgehubAddresses();
        }

        // Check if we should use v29-compatible introspection (no messageRoot)
        bool useV29 = shouldUseV29Introspection(address(_bridgehub));
        if (useV29) {
            return getBridgehubAddressesV29(_bridgehub);
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
            })
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
            })
        });
    }

    function _getUptoDateZkChainAddress(ChainTypeManagerBase _ctm) internal view returns (address) {
        address ctmAddr = address(_ctm);
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
            if (chainCTM != ctmAddr) {
                continue;
            }
            uint256 zkChainProtocolVersion = zkChain.getProtocolVersion();
            if (zkChainProtocolVersion == protocolVersion) {
                return address(zkChain);
            }
        }
        return address(0);
    }

    function _getVerifierFromUptoDateZkChain(ChainTypeManagerBase _ctm) private view returns (address verifier) {
        address zkChainAddr = _getUptoDateZkChainAddress(_ctm);
        if (zkChainAddr == address(0)) {
            return address(0);
        }
        return address(IZKChain(zkChainAddr).getVerifier());
    }

    function _getFacetsFromUptoDateZkChain(
        ChainTypeManagerBase _ctm
    ) private view returns (Facets memory facetsResult) {
        address zkChainAddr = _getUptoDateZkChainAddress(_ctm);
        if (zkChainAddr != address(0)) {
            IZKChain zkChain = IZKChain(zkChainAddr);
            // Get facets from the zkChain using the diamond loupe
            IGetters.Facet[] memory facets = zkChain.facets();

            address adminFacet = address(0);
            address mailboxFacet = address(0);
            address executorFacet = address(0);
            address gettersFacet = address(0);

            // Iterate through facets to identify each one by calling getName()
            for (uint256 j = 0; j < facets.length; j++) {
                address facetAddr = facets[j].addr;
                // Call getName() on the facet
                (bool success, bytes memory data) = facetAddr.staticcall(abi.encodeWithSignature("getName()"));
                if (success && data.length > 0) {
                    string memory name = abi.decode(data, (string));
                    if (keccak256(bytes(name)) == keccak256(bytes("AdminFacet"))) {
                        adminFacet = facetAddr;
                    } else if (keccak256(bytes(name)) == keccak256(bytes("MailboxFacet"))) {
                        mailboxFacet = facetAddr;
                    } else if (keccak256(bytes(name)) == keccak256(bytes("ExecutorFacet"))) {
                        executorFacet = facetAddr;
                    } else if (keccak256(bytes(name)) == keccak256(bytes("GettersFacet"))) {
                        gettersFacet = facetAddr;
                    }
                }
            }

            facetsResult = Facets({
                adminFacet: adminFacet,
                mailboxFacet: mailboxFacet,
                executorFacet: executorFacet,
                gettersFacet: gettersFacet,
                diamondInit: address(0) // Not available from CTM directly
            });
            return facetsResult;
        }

        // If no up-to-date zkChain is found, return empty facets
        facetsResult = Facets({
            adminFacet: address(0),
            mailboxFacet: address(0),
            executorFacet: address(0),
            gettersFacet: address(0),
            diamondInit: address(0)
        });
    }

    function getCTMAddresses(ChainTypeManagerBase _ctm) public view returns (CTMDeployedAddresses memory info) {
        address ctmAddr = address(_ctm);
        address validatorTimelockPostV29 = _tryAddress(ctmAddr, "validatorTimelockPostV29()");
        address bytecodesSupplier = _tryAddress(ctmAddr, "L1_BYTECODES_SUPPLIER()");

        // Try to get facet addresses and verifier from an up-to-date zkChain
        Facets memory facets = _getFacetsFromUptoDateZkChain(_ctm);
        address verifier = _getVerifierFromUptoDateZkChain(_ctm);

        info = CTMDeployedAddresses({
            stateTransition: StateTransitionDeployedAddresses({
                proxies: StateTransitionContracts({
                    chainTypeManager: ctmAddr,
                    serverNotifier: _ctm.serverNotifierAddress(),
                    validatorTimelock: validatorTimelockPostV29 != address(0)
                        ? validatorTimelockPostV29
                        : _ctm.validatorTimelock(),
                    bytecodesSupplier: bytecodesSupplier
                }),
                implementations: StateTransitionContracts({
                    chainTypeManager: Utils.getImplementation(ctmAddr),
                    serverNotifier: address(0), // Not available from CTM directly
                    validatorTimelock: address(0), // Not available from CTM directly
                    bytecodesSupplier: address(0) // Not available from CTM directly
                }),
                verifiers: Verifiers({
                    verifier: verifier,
                    verifierFflonk: address(0), // Not available from CTM directly
                    verifierPlonk: address(0) // Not available from CTM directly
                }),
                facets: facets,
                genesisUpgrade: _ctm.l1GenesisUpgrade(),
                defaultUpgrade: address(0), // Not available from CTM directly
                legacyValidatorTimelock: _ctm.validatorTimelock(),
                eraDiamondProxy: address(0), // Not available from CTM directly
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
                transparentProxyAdmin: Utils.getProxyAdminAddress(ctmAddr),
                governance: IOwnable(ctmAddr).owner(),
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

        // Get governance from bridgehub owner
        address governance = IOwnable(address(bridgehub)).owner();

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
            governance: governance,
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
            try zkChain.getChainTypeManager() returns (address result) {
                chainCTM = result;
            } catch {
                continue;
            }
            if (chainCTM != address(_ctm)) {
                continue;
            }
            uint256 zkChainProtocolVersion = zkChain.getProtocolVersion();
            if (zkChainProtocolVersion == protocolVersion) {
                return getZkChainAddresses(zkChain);
            }
        }
        revert NoUptoDateZkChainFound();
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

    function getCoreDeployedAddresses(
        address _bridgehubProxy
    ) public view returns (CoreDeployedAddresses memory coreAddresses) {
        // Get bridgehub addresses
        coreAddresses.bridgehub = getBridgehubAddresses(IL1Bridgehub(_bridgehubProxy));

        // Get bridges addresses
        address assetRouter = address(IL1Bridgehub(_bridgehubProxy).assetRouter());
        coreAddresses.bridges = getBridgesDeployedAddresses(assetRouter);

        // Populate shared admin addresses
        coreAddresses.shared.transparentProxyAdmin = Utils.getProxyAdminAddress(_bridgehubProxy);
        coreAddresses.shared.bridgehubAdmin = address(IL1Bridgehub(_bridgehubProxy).admin());
        coreAddresses.shared.governance = IOwnable(_bridgehubProxy).owner();
    }

    function getBridgehubAddressesV29(IL1Bridgehub _bridgehub) public view returns (BridgehubAddresses memory info) {
        address bridgehubProxy = address(_bridgehub);
        address ctmDeploymentTrackerProxy = address(_bridgehub.l1CtmDeployer());
        address chainAssetHandler = _bridgehub.chainAssetHandler();
        address messageRoot = address(_bridgehub.messageRoot());

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
            })
        });
    }

    function getBridgesDeployedAddressesV29(
        address _assetRouter
    ) public view returns (BridgesDeployedAddresses memory info) {
        // Asset router must exist for v29 bridge introspection
        require(_assetRouter != address(0), "AssetRouter address cannot be zero");

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

    function getCoreDeployedAddressesV29(
        address _bridgehubProxy
    ) public view returns (CoreDeployedAddresses memory coreAddresses) {
        // Verify bridgehub exists
        // If this fails, check: permanent-values.toml bridgehub address, L1 RPC URL in secrets.yaml
        require(_bridgehubProxy != address(0), "Bridgehub address is zero");
        require(_bridgehubProxy.code.length > 0, "Bridgehub has no code");

        // Get bridgehub addresses without calling messageRoot()
        coreAddresses.bridgehub = getBridgehubAddressesV29(IL1Bridgehub(_bridgehubProxy));

        // Get asset router address and verify it exists
        address assetRouter = address(IL1Bridgehub(_bridgehubProxy).assetRouter());
        require(assetRouter != address(0), "AssetRouter address is zero");
        require(assetRouter.code.length > 0, "AssetRouter has no code");

        coreAddresses.bridges = getBridgesDeployedAddressesV29(assetRouter);

        // Populate shared admin addresses
        coreAddresses.shared.transparentProxyAdmin = Utils.getProxyAdminAddress(_bridgehubProxy);
        coreAddresses.shared.bridgehubAdmin = address(IL1Bridgehub(_bridgehubProxy).admin());
        coreAddresses.shared.governance = IOwnable(_bridgehubProxy).owner();
    }

    /// @notice Determines whether to use v29-compatible introspection based on protocol version
    /// @param _bridgehubProxy The bridgehub proxy address
    /// @return useV29Introspection True if should use v29-compatible introspection, false otherwise
    function shouldUseV29Introspection(address _bridgehubProxy) public view returns (bool useV29Introspection) {
        // First check if the contract exists
        require(_bridgehubProxy != address(0) && _bridgehubProxy.code.length > 0, "Bridgehub contract does not exist");

        IL1Bridgehub bridgehub = IL1Bridgehub(_bridgehubProxy);

        // Get all registered chains to check protocol version
        address[] memory zkChains = bridgehub.getAllZKChains();

        // Protocol version v31 is the target version, so use v29 introspection for versions < v31
        uint256 v31Version = SemVer.packSemVer(0, 31, 0);

        // If there are any chains, check the protocol version of the first one
        if (zkChains.length > 0) {
            IZKChain zkChain = IZKChain(zkChains[0]);
            uint256 protocolVersion = zkChain.getProtocolVersion();
            useV29Introspection = protocolVersion < v31Version;
        } else {
            // No chains exist yet - this can happen during initial upgrade script generation
            useV29Introspection = false;
        }
    }

    function getCTMAddressesV29(address _ctmAddr) public view returns (CTMDeployedAddresses memory info) {
        // Return empty struct if CTM doesn't exist (not deployed yet)
        if (_ctmAddr == address(0) || _ctmAddr.code.length == 0) {
            return info;
        }

        // Cast to ChainTypeManagerBase to access v29 functions
        ChainTypeManagerBase ctm = ChainTypeManagerBase(_ctmAddr);

        // Get validator timelock - check post-v29 version first, then legacy
        address validatorTimelockPostV29 = _tryAddress(_ctmAddr, "validatorTimelockPostV29()");
        address validatorTimelock = validatorTimelockPostV29 != address(0)
            ? validatorTimelockPostV29
            : ctm.validatorTimelock();

        // Try to get facets and verifier from an up-to-date zkChain
        Facets memory facets = _getFacetsFromUptoDateZkChain(ctm);
        address verifier = _getVerifierFromUptoDateZkChain(ctm);

        info = CTMDeployedAddresses({
            stateTransition: StateTransitionDeployedAddresses({
                proxies: StateTransitionContracts({
                    chainTypeManager: _ctmAddr,
                    serverNotifier: ctm.serverNotifierAddress(),
                    validatorTimelock: validatorTimelock,
                    bytecodesSupplier: address(0) // Not available from CTM directly
                }),
                implementations: StateTransitionContracts({
                    chainTypeManager: Utils.getImplementation(_ctmAddr),
                    serverNotifier: address(0), // Not available from CTM directly
                    validatorTimelock: address(0), // Not available from CTM directly
                    bytecodesSupplier: address(0) // Not available from CTM directly
                }),
                verifiers: Verifiers({
                    verifier: verifier,
                    verifierFflonk: address(0), // Not available from CTM directly
                    verifierPlonk: address(0) // Not available from CTM directly
                }),
                facets: facets,
                genesisUpgrade: ctm.l1GenesisUpgrade(),
                defaultUpgrade: address(0), // Not available from CTM directly
                legacyValidatorTimelock: validatorTimelock,
                eraDiamondProxy: address(0), // Not available from CTM directly
                rollupDAManager: address(0), // Not available from CTM directly
                rollupSLDAValidator: address(0) // Not available from CTM directly
            }),
            daAddresses: DataAvailabilityDeployedAddresses({
                rollupDAManager: address(0),
                l1RollupDAValidator: address(0),
                noDAValidiumL1DAValidator: address(0),
                availBridge: address(0),
                availL1DAValidator: address(0),
                l1BlobsDAValidatorZKsyncOS: address(0)
            }),
            admin: CTMAdminAddresses({
                transparentProxyAdmin: Utils.getProxyAdminAddress(_ctmAddr),
                governance: IOwnable(_ctmAddr).owner(),
                accessControlRestrictionAddress: address(0),
                eip7702Checker: address(0),
                chainTypeManagerAdmin: address(0),
                chainTypeManagerOwner: address(0)
            }),
            chainAdmin: address(0)
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
