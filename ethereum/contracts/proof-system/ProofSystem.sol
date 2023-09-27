// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (proxy/Proxy.sol)

pragma solidity ^0.8.13;

import "./proof-system-deps/ProofRegistry.sol";
import "./proof-system-deps/ProofGetters.sol";
import "./Config.sol";

contract ProofSystem is ProofGetters, ProofRegistry {
    /// @notice zkSync contract initialization
    /// @param _verifier address of Verifier contract
    /// @param _governor address who can manage the contract
    /// @param _genesisBlockHash Block hash of the genesis (initial) block
    /// @param _genesisIndexRepeatedStorageChanges The serial number of the shortcut storage key for genesis block
    /// @param _genesisBlockCommitment The zk-proof commitment for the genesis block
    /// @param _allowList The address of the allow list smart contract
    // /// @param _verifierParams Verifier config parameters that describes the circuit to be verified
    /// @param _l2BootloaderBytecodeHash The hash of bootloader L2 bytecode
    /// @param _l2DefaultAccountBytecodeHash The hash of default account L2 bytecode
    /// @param _priorityTxMaxGasLimit maximum number of the L2 gas that a user can request for L1 -> L2 transactions
    // /// @return Magic 32 bytes, which indicates that the contract logic is
    // expected to be used as a diamond proxy initializer
    function initialize(
        address _bridgehead,
        address _verifier,
        address _governor,
        bytes32 _genesisBlockHash,
        uint64 _genesisIndexRepeatedStorageChanges,
        bytes32 _genesisBlockCommitment,
        address _allowList,
        bytes32 _l2BootloaderBytecodeHash,
        bytes32 _l2DefaultAccountBytecodeHash,
        uint256 _priorityTxMaxGasLimit
    ) external reentrancyGuardInitializer {
        require(_governor != address(0), "vy");

        proofStorage.bridgeheadContract = _bridgehead;

        proofStorage.verifier = _verifier;
        proofStorage.governor = _governor;

        // We need to initialize the state hash because it is used in the commitment of the next block
        IProofExecutor.StoredBlockInfo memory storedBlockZero = IProofExecutor.StoredBlockInfo(
            0,
            _genesisBlockHash,
            _genesisIndexRepeatedStorageChanges,
            0,
            EMPTY_STRING_KECCAK,
            DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            0,
            _genesisBlockCommitment
        );
        proofStorage.blockHashZero = keccak256(abi.encode(storedBlockZero));
        proofStorage.allowList = _allowList;
        proofStorage.l2BootloaderBytecodeHash = _l2BootloaderBytecodeHash;
        proofStorage.l2DefaultAccountBytecodeHash = _l2DefaultAccountBytecodeHash;
        proofStorage.priorityTxMaxGasLimit = _priorityTxMaxGasLimit;
    }

    function setParams(
        VerifierParams calldata _verifierParams,
        Diamond.DiamondCutData calldata _cutData
    ) external onlyGovernor {
        proofStorage.verifierParams = _verifierParams;
        proofStorage.cutHash = keccak256(abi.encode(_cutData));
    }
}
