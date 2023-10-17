// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../common/interfaces/IAllowList.sol";
// import "../chain-interfaces/IExecutor.sol";
import "../../common/libraries/Diamond.sol";
// import "../../bridgehub/bridgehub-interfaces/IBridgehubForProof.sol";
import "./facets/Base.sol";
// import "../../common/Config.sol";
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
    function initialize(InitializeData calldata _initData) external reentrancyGuardInitializer returns (bytes32) {
        require(_initData.governor != address(0), "vy");

        chainStorage.chainId = _initData.chainId;
        chainStorage.stateTransition = _initData.stateTransition;
        chainStorage.bridgehub = _initData.bridgehub;

        chainStorage.verifier = _initData.verifier;
        chainStorage.governor = _initData.governor;

        chainStorage.storedBatchHashes[0] = _initData.storedBatchZero;
        chainStorage.allowList = _initData.allowList;
        chainStorage.verifierParams = _initData.verifierParams;
        chainStorage.l2BootloaderBytecodeHash = _initData.l2BootloaderBytecodeHash;
        chainStorage.l2DefaultAccountBytecodeHash = _initData.l2DefaultAccountBytecodeHash;
        chainStorage.priorityTxMaxGasLimit = _initData.priorityTxMaxGasLimit;

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
