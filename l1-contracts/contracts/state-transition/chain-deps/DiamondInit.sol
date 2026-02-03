// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../libraries/Diamond.sol";
import {ZKChainBase} from "./facets/ZKChainBase.sol";
import {DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH, L2_TO_L1_LOG_SERIALIZE_SIZE, DEFAULT_BATCH_OVERHEAD_L1_GAS, DEFAULT_MAX_PUBDATA_PER_BATCH, DEFAULT_MAX_L2_GAS_PER_BATCH, DEFAULT_PRIORITY_TX_MAX_PUBDATA, DEFAULT_MINIMAL_L2_GAS_PRICE, DEFAULT_PUBDATA_PRICING_MODE, DEFAULT_PRIORITY_TX_MAX_GAS_LIMIT} from "../../common/Config.sol";
import {IDiamondInit, InitializeData} from "../chain-interfaces/IDiamondInit.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {IChainTypeManager} from "../IChainTypeManager.sol";
import {PriorityQueue} from "../libraries/PriorityQueue.sol";
import {PriorityTree} from "../libraries/PriorityTree.sol";
import {EmptyAssetId, EmptyBytes32, ZeroAddress} from "../../common/L1ContractErrors.sol";
import {L2_ASSET_TRACKER_ADDR, L2_BRIDGEHUB_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
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
        InitializeData calldata _initializeData
    ) public virtual reentrancyGuardInitializer returns (bytes32) {
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

        if (!IS_ZKSYNC_OS) {
            if (_initializeData.l2BootloaderBytecodeHash == bytes32(0)) {
                revert EmptyBytes32();
            }

            if (_initializeData.l2DefaultAccountBytecodeHash == bytes32(0)) {
                revert EmptyBytes32();
            }

            if (_initializeData.l2EvmEmulatorBytecodeHash == bytes32(0)) {
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

        // Fetch verifier from CTM based on protocol version
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
        s.l2BootloaderBytecodeHash = _initializeData.l2BootloaderBytecodeHash;
        s.l2DefaultAccountBytecodeHash = _initializeData.l2DefaultAccountBytecodeHash;
        s.l2EvmEmulatorBytecodeHash = _initializeData.l2EvmEmulatorBytecodeHash;
        s.priorityTxMaxGasLimit = DEFAULT_PRIORITY_TX_MAX_GAS_LIMIT;
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

        // While this does not provide a protection in the production, it is needed for local testing
        // Length of the L2Log encoding should not be equal to the length of other L2Logs' tree nodes preimages
        assert(L2_TO_L1_LOG_SERIALIZE_SIZE != 2 * 32);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
