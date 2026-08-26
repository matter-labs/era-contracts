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
import {IDiamondInit} from "../chain-interfaces/IDiamondInit.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {IChainTypeManager} from "../IChainTypeManager.sol";
import {ICTMRelease} from "../../upgrades/registry/objects/ICTMRelease.sol";
import {ReleaseFacetReader} from "../../upgrades/registry/libraries/ReleaseFacetReader.sol";
import {PriorityQueue} from "../libraries/PriorityQueue.sol";
import {ChainBatchRootTree} from "../../common/libraries/ChainBatchRootTree.sol";
import {PriorityTree} from "../libraries/PriorityTree.sol";
import {EmptyAssetId, EmptyBytes32, ZeroAddress} from "../../common/L1ContractErrors.sol";
import {L2_BRIDGEHUB_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {IL1AssetRouter} from "../../bridge/asset-router/IL1AssetRouter.sol";
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
    /// @dev `_chainId` and `_admin` are the ONLY per-chain inputs. The ChainTypeManager is
    ///      `msg.sender`: the CTM is the one deploying the diamond proxy (`_deployNewChain`, for
    ///      both chain creation and migration mint), and the proxy constructor delegatecalls
    ///      into this init, preserving the sender. Everything else — bridgehub, protocol
    ///      version, validator timelock, genesis batch hash, base token asset id, facet set,
    ///      verifier and base system contract hashes — is read from the CTM and the genesis
    ///      registry / bridgehub it points at.
    /// @return Magic 32 bytes, which indicates that the contract logic is expected to be used as a diamond proxy
    /// initializer
    function initialize(uint256 _chainId, address _admin) public virtual reentrancyGuardInitializer returns (bytes32) {
        IChainTypeManager ctm = IChainTypeManager(msg.sender);
        address bridgehub = ctm.BRIDGE_HUB();
        uint256 protocolVersion = ctm.protocolVersion();
        address validatorTimelock = ctm.validatorTimelockPostV29();
        // Registered by the bridgehub before it calls into the CTM, in both the chain-creation
        // and the migration-mint flow.
        bytes32 baseTokenAssetId = IBridgehubBase(bridgehub).baseTokenAssetId(_chainId);

        if (_admin == address(0)) {
            revert ZeroAddress();
        }
        if (validatorTimelock == address(0)) {
            revert ZeroAddress();
        }
        if (bridgehub == address(0)) {
            revert ZeroAddress();
        }
        if (baseTokenAssetId == bytes32(0)) {
            revert EmptyAssetId();
        }

        // Everything chain-independent is read from the current release the CTM pins — the
        // committed chain-creation cut carries no init payload. Facets are installed here, by the
        // init itself, from the release's EXPLICIT routing (selector lists are pinned in the
        // release manifest, not read back out of facet bytecode at execution time).
        address currentRelease = ctm.currentRelease();
        if (currentRelease == address(0)) {
            revert ZeroAddress();
        }
        ICTMRelease release = ICTMRelease(currentRelease);
        release.validate();
        Diamond.FacetCut[] memory facetCuts = ReleaseFacetReader.newChainInstallations(release);
        if (facetCuts.length != 0) {
            Diamond.diamondCut(
                Diamond.DiamondCutData({facetCuts: facetCuts, initAddress: address(0), initCalldata: ""})
            );
        }

        (
            bytes32 l2BootloaderBytecodeHash,
            bytes32 l2DefaultAccountBytecodeHash,
            bytes32 l2EvmEmulatorBytecodeHash
        ) = release.baseSystemContractHashes();

        if (!IS_ZKSYNC_OS) {
            if (l2BootloaderBytecodeHash == bytes32(0)) {
                revert EmptyBytes32();
            }

            if (l2DefaultAccountBytecodeHash == bytes32(0)) {
                revert EmptyBytes32();
            }

            if (l2EvmEmulatorBytecodeHash == bytes32(0)) {
                revert EmptyBytes32();
            }
        }

        s.chainId = _chainId;
        s.bridgehub = bridgehub;
        s.chainTypeManager = msg.sender;
        if (bridgehub == L2_BRIDGEHUB_ADDR) {
            s.nativeTokenVault = L2_NATIVE_TOKEN_VAULT_ADDR;
        } else {
            s.nativeTokenVault = address(
                IL1AssetRouter(address(IBridgehubBase(bridgehub).assetRouter())).nativeTokenVault()
            );
        }
        s.baseTokenAssetId = baseTokenAssetId;
        s.protocolVersion = protocolVersion;

        // The verifier is part of the release's installed chain state, so it comes from the same
        // object as the facets and base-system hashes rather than from a separate CTM lookup.
        address verifier = release.verifier();
        if (verifier == address(0)) {
            revert ZeroAddress();
        }
        s.verifier = IVerifier(verifier);
        s.admin = _admin;
        s.validators[validatorTimelock] = true;

        s.storedBatchHashes[0] = ctm.storedBatchZero();
        s.l2BootloaderBytecodeHash = l2BootloaderBytecodeHash;
        s.l2DefaultAccountBytecodeHash = l2DefaultAccountBytecodeHash;
        s.l2EvmEmulatorBytecodeHash = l2EvmEmulatorBytecodeHash;
        s.priorityTxMaxGasLimit = DEFAULT_PRIORITY_TX_MAX_GAS_LIMIT;
        s.priorityModeInfo.permissionlessValidator = ctm.PERMISSIONLESS_VALIDATOR();
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
        if (IS_ZKSYNC_OS) {
            s.l2LogsRootHashes[0] = ChainBatchRootTree.genesisChainBatchRoot();
        }

        // All new chains (both ZKsync OS ones and not) have the totalSupply tracked for the base token of the chain.
        // The only exception are the legacy ZKsync OS chains.
        s.baseTokenHasTotalSupply = true;

        // While this does not provide a protection in the production, it is needed for local testing
        // Length of the L2Log encoding should not be equal to the length of other L2Logs' tree nodes preimages
        assert(L2_TO_L1_LOG_SERIALIZE_SIZE != 2 * 32);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
