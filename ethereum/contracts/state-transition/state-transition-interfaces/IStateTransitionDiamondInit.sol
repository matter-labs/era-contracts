// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Diamond} from "../../common/libraries/Diamond.sol";

/// @notice Struct that holds all data needed for initializing zkSync Diamond Proxy.
/// @dev We use struct instead of raw parameters in `initialize` function to prevent "Stack too deep" error
/// @param _governor address who can manage critical updates in the contract
/// @param _admin address who can manage non-critical updates in the contract
/// @param _genesisBatchHash Batch hash of the genesis (initial) batch
/// @param _genesisIndexRepeatedStorageChanges The serial number of the shortcut storage key for genesis batch
/// @param _genesisBatchCommitment The zk-proof commitment for the genesis batch
struct StateTransitionInitializeData {
    address bridgehub;
    address governor;
    address diamondInit;
    bytes32 genesisBatchHash;
    uint64 genesisIndexRepeatedStorageChanges;
    bytes32 genesisBatchCommitment;
    Diamond.DiamondCutData diamondCut;
    uint256 protocolVersion;
}

interface IStateTransitionDiamondInit {
    function initialize(StateTransitionInitializeData calldata _initalizeData) external;
}
