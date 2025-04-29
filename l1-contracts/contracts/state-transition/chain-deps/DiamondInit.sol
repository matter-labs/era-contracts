// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Diamond} from "../libraries/Diamond.sol";
import {ZKChainBase} from "./facets/ZKChainBase.sol";
import {L2_TO_L1_LOG_SERIALIZE_SIZE, MAX_GAS_PER_TRANSACTION} from "../../common/Config.sol";
import {InitializeData, IDiamondInit} from "../chain-interfaces/IDiamondInit.sol";
import {PriorityQueue} from "../libraries/PriorityQueue.sol";
import {PriorityTree} from "../libraries/PriorityTree.sol";
import {ZeroAddress, EmptyAssetId, TooMuchGas, EmptyBytes32} from "../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @dev The contract is used only once to initialize the diamond proxy.
/// @dev The deployment process takes care of this contract's initialization.
contract DiamondInit is ZKChainBase, IDiamondInit {
    using PriorityQueue for PriorityQueue.Queue;
    using PriorityTree for PriorityTree.Tree;

    /// @dev Initialize the implementation to prevent any possibility of a Parity hack.
    constructor() reentrancyGuardInitializer {}

    /// @notice ZK chain diamond contract initialization
    /// @return Magic 32 bytes, which indicates that the contract logic is expected to be used as a diamond proxy
    /// initializer
    function initialize(InitializeData calldata _initializeData) external reentrancyGuardInitializer returns (bytes32) {
        if (address(_initializeData.verifier) == address(0)) {
            revert ZeroAddress();
        }
        if (_initializeData.admin == address(0)) {
            revert ZeroAddress();
        }
        if (_initializeData.validatorTimelock == address(0)) {
            revert ZeroAddress();
        }
        if (_initializeData.priorityTxMaxGasLimit > MAX_GAS_PER_TRANSACTION) {
            revert TooMuchGas();
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
        if (_initializeData.blobVersionedHashRetriever == address(0)) {
            revert ZeroAddress();
        }

        if (_initializeData.l2BootloaderBytecodeHash == bytes32(0)) {
            revert EmptyBytes32();
        }

        if (_initializeData.l2DefaultAccountBytecodeHash == bytes32(0)) {
            revert EmptyBytes32();
        }

        if (_initializeData.l2EvmEmulatorBytecodeHash == bytes32(0)) {
            revert EmptyBytes32();
        }

        s.chainId = _initializeData.chainId;
        s.bridgehub = _initializeData.bridgehub;
        s.chainTypeManager = _initializeData.chainTypeManager;
        s.baseTokenAssetId = _initializeData.baseTokenAssetId;
        s.protocolVersion = _initializeData.protocolVersion;

        s.verifier = _initializeData.verifier;
        s.admin = _initializeData.admin;
        s.validators[_initializeData.validatorTimelock] = true;

        s.storedBatchHashes[0] = _initializeData.storedBatchZero;
        s.__DEPRECATED_verifierParams = _initializeData.verifierParams;
        s.l2BootloaderBytecodeHash = _initializeData.l2BootloaderBytecodeHash;
        s.l2DefaultAccountBytecodeHash = _initializeData.l2DefaultAccountBytecodeHash;
        s.l2EvmEmulatorBytecodeHash = _initializeData.l2EvmEmulatorBytecodeHash;
        s.priorityTxMaxGasLimit = _initializeData.priorityTxMaxGasLimit;
        s.feeParams = _initializeData.feeParams;
        s.blobVersionedHashRetriever = _initializeData.blobVersionedHashRetriever;
        s.priorityTree.setup(s.priorityQueue.getTotalPriorityTxs());

        // While this does not provide a protection in the production, it is needed for local testing
        // Length of the L2Log encoding should not be equal to the length of other L2Logs' tree nodes preimages
        assert(L2_TO_L1_LOG_SERIALIZE_SIZE != 2 * 32);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
