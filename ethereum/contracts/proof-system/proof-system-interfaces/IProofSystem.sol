// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./IProofRegistry.sol";
import "./IProofMailbox.sol";
import "../Verifier.sol";
import "../../common/interfaces/IAllowList.sol";
import "../chain-interfaces/IVerifier.sol";
import "../../common/libraries/Diamond.sol";

/// @notice Struct that holds all data needed for initializing zkSync Diamond Proxy.
/// @dev We use struct instead of raw parameters in `initialize` function to prevent "Stack too deep" error
/// @param _verifier address of Verifier contract
/// @param _governor address who can manage critical updates in the contract
/// @param _admin address who can manage non-critical updates in the contract
/// @param _genesisBatchHash Batch hash of the genesis (initial) batch
/// @param _genesisIndexRepeatedStorageChanges The serial number of the shortcut storage key for genesis batch
/// @param _genesisBatchCommitment The zk-proof commitment for the genesis batch
/// @param _allowList The address of the allow list smart contract
/// @param _l2BootloaderBytecodeHash The hash of bootloader L2 bytecode
/// @param _l2DefaultAccountBytecodeHash The hash of default account L2 bytecode
/// @param _priorityTxMaxGasLimit maximum number of the L2 gas that a user can request for L1 -> L2 transactions
struct InitializeData {
    address bridgehead;
    address verifier;
    address governor;
    address admin;
    bytes32 genesisBatchHash;
    uint64 genesisIndexRepeatedStorageChanges;
    bytes32 genesisBatchCommitment;
    address allowList;
    bytes32 l2BootloaderBytecodeHash;
    bytes32 l2DefaultAccountBytecodeHash;
    uint256 priorityTxMaxGasLimit;
}

interface IProofSystem is IProofRegistry, IProofMailbox {
    function initialize(InitializeData calldata _initalizeData) external;

    function setParams(VerifierParams calldata _verifierParams, Diamond.DiamondCutData calldata _cutData) external;
}
