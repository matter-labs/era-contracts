// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../libraries/Diamond.sol";
import {ZKChainBase} from "./facets/ZKChainBase.sol";
import {
    DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH,
    L2_TO_L1_LOG_SERIALIZE_SIZE,
    DEFAULT_BATCH_OVERHEAD_L1_GAS,
    DEFAULT_MAX_PUBDATA_PER_BATCH,
    DEFAULT_MAX_L2_GAS_PER_BATCH,
    DEFAULT_PRIORITY_TX_MAX_PUBDATA,
    DEFAULT_MINIMAL_L2_GAS_PRICE,
    DEFAULT_PUBDATA_PRICING_MODE,
    DEFAULT_PRIORITY_TX_MAX_GAS_LIMIT
} from "../../common/Config.sol";
import {
    FacetInstallation,
    IDiamondInit,
    InitializeData,
    InitializeDataNewChain
} from "../chain-interfaces/IDiamondInit.sol";
import {ISelfDescribingFacet} from "../chain-interfaces/ISelfDescribingFacet.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {IChainTypeManager} from "../IChainTypeManager.sol";
import {IGenesisFacetRegistry} from "../../upgrades/registry/IGenesisFacetRegistry.sol";
import {RegistryFacetReader} from "../../upgrades/registry/RegistryFacetReader.sol";
import {PriorityQueue} from "../libraries/PriorityQueue.sol";
import {PriorityTree} from "../libraries/PriorityTree.sol";
import {EmptyAssetId, EmptyBytes32, ZeroAddress} from "../../common/L1ContractErrors.sol";
import {
    L2_ASSET_TRACKER_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR
} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {IL1AssetRouter} from "../../bridge/asset-router/IL1AssetRouter.sol";
import {IL1NativeTokenVault} from "../../bridge/ntv/IL1NativeTokenVault.sol";
import {IBridgehubBase} from "../../core/bridgehub/IBridgehubBase.sol";
import {FeeParams} from "../../state-transition/chain-deps/ZKChainStorage.sol";

/// @author Matter Labs
/// @dev The contract is used only once to initialize the diamond proxy.
/// @dev The deployment process takes care of this contract's initialization.
contract DiamondInit is ZKChainBase, IDiamondInit {
    using PriorityTree for PriorityTree.Tree;
    using PriorityQueue for PriorityQueue.Queue;

    bool public immutable IS_ZKSYNC_OS;

    /// @dev Initialize the implementation to prevent any possibility of a Parity hack.
    constructor(bool _isZKOS) reentrancyGuardInitializer {
        IS_ZKSYNC_OS = _isZKOS;
    }

    /// @notice ZK chain diamond contract initialization
    /// @return Magic 32 bytes, which indicates that the contract logic is expected to be used as a diamond proxy
    /// initializer
    function initialize(
        InitializeData calldata _initializeData,
        bytes calldata _newChainData
    ) public virtual reentrancyGuardInitializer returns (bytes32) {
        // The chain-independent half, committed in the chain-creation cut and passed through by
        // the CTM as opaque bytes: decoding it here keeps the (size-constrained) CTM free of the
        // nested-type codecs.
        InitializeDataNewChain memory newChainData = abi.decode(_newChainData, (InitializeDataNewChain));

        if (_initializeData.admin == address(0)) {
            revert ZeroAddress();
        }
        if (_initializeData.validatorTimelock == address(0)) {
            revert ZeroAddress();
        }
        if (_initializeData.bridgehub == address(0)) {
            revert ZeroAddress();
        }
        if (_initializeData.chainTypeManager == address(0)) {
            revert ZeroAddress();
        }
        if (_initializeData.baseTokenAssetId == bytes32(0)) {
            revert EmptyAssetId();
        }

        // Facets are installed here, by the init itself. Their addresses are NOT in the committed
        // cut — they are read from the CTM by protocol version, mirroring how the verifier is
        // fetched below. Selector lists come from each facet's own bytecode at execution time.
        // Facets are installed here, by the init itself. Their addresses are NOT in the committed
        // cut — the CTM pins the genesis registry (like the verifier, fetched below), and the
        // facet set is read straight from that registry. Selector lists come from each facet's own
        // bytecode at execution time.
        address genesisRegistry = IChainTypeManager(_initializeData.chainTypeManager).genesisRegistry();
        if (genesisRegistry != address(0)) {
            _installFacets(RegistryFacetReader.newChainInstallations(IGenesisFacetRegistry(genesisRegistry)));
        }

        if (!IS_ZKSYNC_OS) {
            if (newChainData.l2BootloaderBytecodeHash == bytes32(0)) {
                revert EmptyBytes32();
            }

            if (newChainData.l2DefaultAccountBytecodeHash == bytes32(0)) {
                revert EmptyBytes32();
            }

            if (newChainData.l2EvmEmulatorBytecodeHash == bytes32(0)) {
                revert EmptyBytes32();
            }
        }

        s.chainId = _initializeData.chainId;
        s.bridgehub = _initializeData.bridgehub;
        s.chainTypeManager = _initializeData.chainTypeManager;
        if (_initializeData.bridgehub == L2_BRIDGEHUB_ADDR) {
            s.nativeTokenVault = L2_NATIVE_TOKEN_VAULT_ADDR;
            s.assetTracker = L2_ASSET_TRACKER_ADDR;
        } else {
            address nativeTokenVault = address(
                IL1AssetRouter(address(IBridgehubBase(_initializeData.bridgehub).assetRouter())).nativeTokenVault()
            );
            s.nativeTokenVault = nativeTokenVault;
            s.assetTracker = address(IL1NativeTokenVault(nativeTokenVault).l1AssetTracker());
        }
        s.baseTokenAssetId = _initializeData.baseTokenAssetId;
        s.protocolVersion = _initializeData.protocolVersion;

        // Fetch verifier from CTM based on protocol version to keep CTM as the single source of truth
        // and avoid including the verifier address in the diamond cut init calldata.
        address verifier = IChainTypeManager(_initializeData.chainTypeManager).protocolVersionVerifier(
            _initializeData.protocolVersion
        );
        if (verifier == address(0)) {
            revert ZeroAddress();
        }
        s.verifier = IVerifier(verifier);
        s.admin = _initializeData.admin;
        s.validators[_initializeData.validatorTimelock] = true;

        s.storedBatchHashes[0] = _initializeData.storedBatchZero;
        s.l2BootloaderBytecodeHash = newChainData.l2BootloaderBytecodeHash;
        s.l2DefaultAccountBytecodeHash = newChainData.l2DefaultAccountBytecodeHash;
        s.l2EvmEmulatorBytecodeHash = newChainData.l2EvmEmulatorBytecodeHash;
        s.priorityTxMaxGasLimit = DEFAULT_PRIORITY_TX_MAX_GAS_LIMIT;
        s.priorityModeInfo.permissionlessValidator = IChainTypeManager(_initializeData.chainTypeManager)
            .PERMISSIONLESS_VALIDATOR();
        s.feeParams = FeeParams({
            pubdataPricingMode: DEFAULT_PUBDATA_PRICING_MODE,
            batchOverheadL1Gas: DEFAULT_BATCH_OVERHEAD_L1_GAS,
            maxPubdataPerBatch: DEFAULT_MAX_PUBDATA_PER_BATCH,
            maxL2GasPerBatch: DEFAULT_MAX_L2_GAS_PER_BATCH,
            priorityTxMaxPubdata: DEFAULT_PRIORITY_TX_MAX_PUBDATA,
            minimalL2GasPrice: DEFAULT_MINIMAL_L2_GAS_PRICE
        });
        s.priorityTree.setup(s.__DEPRECATED_priorityQueue.getTotalPriorityTxs());
        s.precommitmentForTheLatestBatch = DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH;
        s.zksyncOS = IS_ZKSYNC_OS;

        // All new chains (both ZKsync OS ones and not) have the totalSupply tracked for the base token of the chain.
        // The only exception are the legacy ZKsync OS chains.
        s.baseTokenHasTotalSupply = true;

        // While this does not provide a protection in the production, it is needed for local testing
        // Length of the L2Log encoding should not be equal to the length of other L2Logs' tree nodes preimages
        assert(L2_TO_L1_LOG_SERIALIZE_SIZE != 2 * 32);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    /// @dev Adds every facet in the registry-supplied set to the diamond this contract is
    ///      delegatecalled into. Selector lists resolve at execution time: a pinned non-empty list
    ///      wins, otherwise the facet's own `ISelfDescribingFacet.selectors()` is read (its
    ///      immutable bytecode is the single source of truth for what it serves).
    function _installFacets(FacetInstallation[] memory _facets) private {
        uint256 facetsLength = _facets.length;
        if (facetsLength == 0) {
            return;
        }

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](facetsLength);
        for (uint256 i = 0; i < facetsLength; ++i) {
            FacetInstallation memory facet = _facets[i];
            facetCuts[i] = Diamond.FacetCut({
                facet: facet.facet,
                action: Diamond.Action.Add,
                isFreezable: facet.isFreezable,
                selectors: facet.selectors.length != 0 ? facet.selectors : ISelfDescribingFacet(facet.facet).selectors()
            });
        }

        Diamond.diamondCut(Diamond.DiamondCutData({facetCuts: facetCuts, initAddress: address(0), initCalldata: ""}));
    }
}
