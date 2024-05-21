// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Diamond} from "../libraries/Diamond.sol";
import {ZkSyncHyperchainBase} from "./facets/ZkSyncHyperchainBase.sol";
import {L2_TO_L1_LOG_SERIALIZE_SIZE, MAX_GAS_PER_TRANSACTION} from "../../common/Config.sol";
import {InitializeData, IDiamondInit} from "../chain-interfaces/IDiamondInit.sol";

/// @author Matter Labs
/// @dev The contract is used only once to initialize the diamond proxy.
/// @dev The deployment process takes care of this contract's initialization.
contract DiamondInit is ZkSyncHyperchainBase, IDiamondInit {
    /// @dev Initialize the implementation to prevent any possibility of a Parity hack.
    constructor() reentrancyGuardInitializer {}

    /// @notice hyperchain diamond contract initialization
    /// @return Magic 32 bytes, which indicates that the contract logic is expected to be used as a diamond proxy
    /// initializer
    function initialize(InitializeData calldata _initializeData) external reentrancyGuardInitializer returns (bytes32) {
        require(address(_initializeData.verifier) != address(0), "vt");
        require(_initializeData.admin != address(0), "vy");
        require(_initializeData.validatorTimelock != address(0), "hc");
        require(_initializeData.priorityTxMaxGasLimit <= MAX_GAS_PER_TRANSACTION, "vu");
        require(_initializeData.bridgehub != address(0), "DiamondInit: b0");
        require(_initializeData.stateTransitionManager != address(0), "DiamondInit: stm0");
        require(_initializeData.baseToken != address(0), "DiamondInit: bt0");
        require(_initializeData.baseTokenBridge != address(0), "DiamondInit: btb0");
        require(_initializeData.blobVersionedHashRetriever != address(0), "DiamondInit: bvhr0");

        s.chainId = _initializeData.chainId;
        s.bridgehub = _initializeData.bridgehub;
        s.stateTransitionManager = _initializeData.stateTransitionManager;
        s.baseToken = _initializeData.baseToken;
        s.baseTokenBridge = _initializeData.baseTokenBridge;
        s.protocolVersion = _initializeData.protocolVersion;

        s.verifier = _initializeData.verifier;
        s.admin = _initializeData.admin;
        s.validators[_initializeData.validatorTimelock] = true;

        s.storedBatchHashes[0] = _initializeData.storedBatchZero;
        s.__DEPRECATED_verifierParams = _initializeData.verifierParams;
        s.l2BootloaderBytecodeHash = _initializeData.l2BootloaderBytecodeHash;
        s.l2DefaultAccountBytecodeHash = _initializeData.l2DefaultAccountBytecodeHash;
        s.priorityTxMaxGasLimit = _initializeData.priorityTxMaxGasLimit;
        s.feeParams = _initializeData.feeParams;
        s.blobVersionedHashRetriever = _initializeData.blobVersionedHashRetriever;

        // While this does not provide a protection in the production, it is needed for local testing
        // Length of the L2Log encoding should not be equal to the length of other L2Logs' tree nodes preimages
        assert(L2_TO_L1_LOG_SERIALIZE_SIZE != 2 * 32);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
