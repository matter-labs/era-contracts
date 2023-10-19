// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../common/interfaces/IAllowList.sol";
import "../../common/libraries/Diamond.sol";
import "./facets/Base.sol";
import {L2_TX_MAX_GAS_LIMIT, L2_TO_L1_LOG_SERIALIZE_SIZE} from "../../common/Config.sol";
import {InitializeData} from "../chain-interfaces/IDiamondInit.sol";

/// @author Matter Labs
/// @dev The contract is used only once to initialize the diamond proxy.
/// @dev The deployment process takes care of this contract's initialization.
contract DiamondInit is StateTransitionChainBase {
    /// @dev Initialize the implementation to prevent any possibility of a Parity hack.
    constructor() reentrancyGuardInitializer {}

    /// @notice zkSync contract initialization
    /// @return Magic 32 bytes, which indicates that the contract logic is expected to be used as a diamond proxy
    /// initializer
    function initialize(InitializeData calldata _initializeData) external reentrancyGuardInitializer returns (bytes32) {
        require(address(_initializeData.verifier) != address(0), "vt");
        require(_initializeData.governor != address(0), "vy");
        require(_initializeData.admin != address(0), "hc");
        require(_initializeData.priorityTxMaxGasLimit <= L2_TX_MAX_GAS_LIMIT, "vu");

        chainStorage.chainId = _initializeData.chainId;
        chainStorage.stateTransition = _initializeData.stateTransition;
        chainStorage.bridgehub = _initializeData.bridgehub;

        chainStorage.verifier = _initializeData.verifier;
        chainStorage.governor = _initializeData.governor;
        chainStorage.admin = _initializeData.admin;

        chainStorage.storedBatchHashes[0] = _initializeData.storedBatchZero;
        chainStorage.allowList = _initializeData.allowList;
        chainStorage.verifierParams = _initializeData.verifierParams;
        chainStorage.l2BootloaderBytecodeHash = _initializeData.l2BootloaderBytecodeHash;
        chainStorage.l2DefaultAccountBytecodeHash = _initializeData.l2DefaultAccountBytecodeHash;
        chainStorage.priorityTxMaxGasLimit = _initializeData.priorityTxMaxGasLimit;

        // While this does not provide a protection in the production, it is needed for local testing
        // Length of the L2Log encoding should not be equal to the length of other L2Logs' tree nodes preimages
        assert(L2_TO_L1_LOG_SERIALIZE_SIZE != 2 * 32);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
