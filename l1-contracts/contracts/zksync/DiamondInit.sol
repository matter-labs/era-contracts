// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IVerifier} from "./interfaces/IVerifier.sol";
import {IExecutor} from "./interfaces/IExecutor.sol";
import {Diamond} from "./libraries/Diamond.sol";
import {Base} from "./facets/Base.sol";
import {Verifier} from "./Verifier.sol";
import {VerifierParams, FeeParams} from "./Storage.sol";
/* solhint-disable max-line-length */
import {L2_TO_L1_LOG_SERIALIZE_SIZE, EMPTY_STRING_KECCAK, DEFAULT_L2_LOGS_TREE_ROOT_HASH, MAX_GAS_PER_TRANSACTION} from "./Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The contract is used only once to initialize the diamond proxy.
/// @dev The deployment process takes care of this contract's initialization.
contract DiamondInit is Base {
    /// @notice Struct that holds all data needed for initializing zkSync Diamond Proxy.
    /// @dev We use struct instead of raw parameters in `initialize` function to prevent "Stack too deep" error
    /// @param verifier address of Verifier contract
    /// @param governor address who can manage critical updates in the contract
    /// @param admin address who can manage non-critical updates in the contract
    /// @param genesisBatchHash Batch hash of the genesis (initial) batch
    /// @param genesisIndexRepeatedStorageChanges The serial number of the shortcut storage key for genesis batch
    /// @param genesisBatchCommitment The zk-proof commitment for the genesis batch
    /// @param verifierParams Verifier config parameters that describes the circuit to be verified
    /// @param zkPorterIsAvailable The availability of zk porter shard
    /// @param l2BootloaderBytecodeHash The hash of bootloader L2 bytecode
    /// @param l2DefaultAccountBytecodeHash The hash of default account L2 bytecode
    /// @param priorityTxMaxGasLimit maximum number of the L2 gas that a user can request for L1 -> L2 transactions
    /// @param initialProtocolVersion initial protocol version
    /// @param feeParams Fee parameters to be used for L1->L2 transactions
    struct InitializeData {
        IVerifier verifier;
        address governor;
        address admin;
        bytes32 genesisBatchHash;
        uint64 genesisIndexRepeatedStorageChanges;
        bytes32 genesisBatchCommitment;
        VerifierParams verifierParams;
        bool zkPorterIsAvailable;
        bytes32 l2BootloaderBytecodeHash;
        bytes32 l2DefaultAccountBytecodeHash;
        uint256 priorityTxMaxGasLimit;
        uint256 initialProtocolVersion;
        FeeParams feeParams;
    }

    /// @dev Initialize the implementation to prevent any possibility of a Parity hack.
    constructor() reentrancyGuardInitializer {}

    /// @notice zkSync contract initialization
    /// @return Magic 32 bytes, which indicates that the contract logic is expected to be used as a diamond proxy
    /// initializer
    function initialize(InitializeData calldata _initalizeData) external reentrancyGuardInitializer returns (bytes32) {
        require(address(_initalizeData.verifier) != address(0), "vt");
        require(_initalizeData.governor != address(0), "vy");
        require(_initalizeData.admin != address(0), "hc");
        require(_initalizeData.priorityTxMaxGasLimit <= MAX_GAS_PER_TRANSACTION, "vu");

        s.verifier = _initalizeData.verifier;
        s.governor = _initalizeData.governor;
        s.admin = _initalizeData.admin;

        // We need to initialize the state hash because it is used in the commitment of the next batch
        IExecutor.StoredBatchInfo memory storedBatchZero = IExecutor.StoredBatchInfo(
            0,
            _initalizeData.genesisBatchHash,
            _initalizeData.genesisIndexRepeatedStorageChanges,
            0,
            EMPTY_STRING_KECCAK,
            DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            0,
            _initalizeData.genesisBatchCommitment
        );

        s.storedBatchHashes[0] = keccak256(abi.encode(storedBatchZero));
        s.verifierParams = _initalizeData.verifierParams;
        s.zkPorterIsAvailable = _initalizeData.zkPorterIsAvailable;
        s.l2BootloaderBytecodeHash = _initalizeData.l2BootloaderBytecodeHash;
        s.l2DefaultAccountBytecodeHash = _initalizeData.l2DefaultAccountBytecodeHash;
        s.priorityTxMaxGasLimit = _initalizeData.priorityTxMaxGasLimit;
        s.protocolVersion = _initalizeData.initialProtocolVersion;
        s.feeParams = _initalizeData.feeParams;

        // While this does not provide a protection in the production, it is needed for local testing
        // Length of the L2Log encoding should not be equal to the length of other L2Logs' tree nodes preimages
        assert(L2_TO_L1_LOG_SERIALIZE_SIZE != 2 * 32);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
