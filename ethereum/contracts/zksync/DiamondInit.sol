// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {IAllowList} from "../common/interfaces/IAllowList.sol";
import {IVerifier} from "./interfaces/IVerifier.sol";
import {IExecutor} from "./interfaces/IExecutor.sol";
import {Diamond} from "./libraries/Diamond.sol";
import {Base} from "./facets/Base.sol";
import {Verifier} from "./Verifier.sol";
import {VerifierParams} from "./Storage.sol";
import {L2_TO_L1_LOG_SERIALIZE_SIZE, EMPTY_STRING_KECCAK, DEFAULT_L2_LOGS_TREE_ROOT_HASH, L2_TX_MAX_GAS_LIMIT} from "./Config.sol";

/// @author Matter Labs
/// @dev The contract is used only once to initialize the diamond proxy.
/// @dev The deployment process takes care of this contract's initialization.
contract DiamondInit is Base {
    /// @dev Initialize the implementation to prevent any possibility of a Parity hack.
    constructor() reentrancyGuardInitializer {}

    /// @notice zkSync contract initialization
    /// @param _verifier address of Verifier contract
    /// @param _governor address who can manage the contract
    /// @param _genesisBlockHash Block hash of the genesis (initial) block
    /// @param _genesisIndexRepeatedStorageChanges The serial number of the shortcut storage key for genesis block
    /// @param _genesisBlockCommitment The zk-proof commitment for the genesis block
    /// @param _allowList The address of the allow list smart contract
    /// @param _verifierParams Verifier config parameters that describes the circuit to be verified
    /// @param _zkPorterIsAvailable The availability of zk porter shard
    /// @param _l2BootloaderBytecodeHash The hash of bootloader L2 bytecode
    /// @param _l2DefaultAccountBytecodeHash The hash of default account L2 bytecode
    /// @param _priorityTxMaxGasLimit maximum number of the L2 gas that a user can request for L1 -> L2 transactions
    /// @return Magic 32 bytes, which indicates that the contract logic is expected to be used as a diamond proxy initializer
    function initialize(
        IVerifier _verifier,
        address _governor,
        bytes32 _genesisBlockHash,
        uint64 _genesisIndexRepeatedStorageChanges,
        bytes32 _genesisBlockCommitment,
        IAllowList _allowList,
        VerifierParams calldata _verifierParams,
        bool _zkPorterIsAvailable,
        bytes32 _l2BootloaderBytecodeHash,
        bytes32 _l2DefaultAccountBytecodeHash,
        uint256 _priorityTxMaxGasLimit
    ) external reentrancyGuardInitializer returns (bytes32) {
        require(address(_verifier) != address(0), "vt");
        require(_governor != address(0), "vy");
        require(_priorityTxMaxGasLimit <= L2_TX_MAX_GAS_LIMIT, "vu");

        s.verifier = _verifier;
        s.governor = _governor;

        // We need to initialize the state hash because it is used in the commitment of the next block
        IExecutor.StoredBlockInfo memory storedBlockZero = IExecutor.StoredBlockInfo(
            0,
            _genesisBlockHash,
            _genesisIndexRepeatedStorageChanges,
            0,
            EMPTY_STRING_KECCAK,
            DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            0,
            _genesisBlockCommitment
        );

        s.storedBlockHashes[0] = keccak256(abi.encode(storedBlockZero));
        s.allowList = _allowList;
        s.verifierParams = _verifierParams;
        s.zkPorterIsAvailable = _zkPorterIsAvailable;
        s.l2BootloaderBytecodeHash = _l2BootloaderBytecodeHash;
        s.l2DefaultAccountBytecodeHash = _l2DefaultAccountBytecodeHash;
        s.priorityTxMaxGasLimit = _priorityTxMaxGasLimit;

        // While this does not provide a protection in the production, it is needed for local testing
        // Length of the L2Log encoding should not be equal to the length of other L2Logs' tree nodes preimages
        assert(L2_TO_L1_LOG_SERIALIZE_SIZE != 2 * 32);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
