// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (proxy/Proxy.sol)

pragma solidity ^0.8.13;

import "./proof-system-deps/ProofRegistry.sol";
import "./proof-system-deps/ProofMailbox.sol";
import "./proof-system-deps/ProofGetters.sol";
import {L2_TO_L1_LOG_SERIALIZE_SIZE, EMPTY_STRING_KECCAK, DEFAULT_L2_LOGS_TREE_ROOT_HASH, L2_TX_MAX_GAS_LIMIT} from "../common/Config.sol";

import {IAllowList} from "../common/interfaces/IAllowList.sol";
import {IVerifier} from "./chain-interfaces/IVerifier.sol";
import {IExecutor} from "./chain-interfaces/IExecutor.sol";
import {Diamond} from "../common/libraries/Diamond.sol";
import {ProofChainBase} from "./chain-deps/facets/Base.sol";
import {Verifier} from "./Verifier.sol";
import {VerifierParams} from "./chain-deps/ProofChainStorage.sol";
import {InitializeData} from "./proof-system-interfaces/IProofSystem.sol";

/* solhint-disable max-line-length */

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The contract is used only once to initialize the diamond proxy.
/// @dev The deployment process takes care of this contract's initialization.
contract ProofSystem is ProofBase, ProofGetters, ProofRegistry, ProofMailbox {
    /// @dev Initialize the implementation to prevent any possibility of a Parity hack.
    /// @notice zkSync contract initialization
    /// @return Magic 32 bytes, which indicates that the contract logic is expected to be used as a diamond proxy
    /// initializer
    function initialize(InitializeData calldata _initalizeData) external reentrancyGuardInitializer returns (bytes32) {
        require(address(_initalizeData.verifier) != address(0), "vt");
        require(_initalizeData.governor != address(0), "vy");
        require(_initalizeData.admin != address(0), "hc");
        require(_initalizeData.priorityTxMaxGasLimit <= L2_TX_MAX_GAS_LIMIT, "vu");

        proofStorage.bridgehead = _initalizeData.bridgehead;
        proofStorage.verifier = _initalizeData.verifier;
        proofStorage.governor = _initalizeData.governor;
        proofStorage.admin = _initalizeData.admin;

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
        proofStorage.storedBatchZero = keccak256(abi.encode(storedBatchZero));
        proofStorage.allowList = _initalizeData.allowList;

        proofStorage.allowList = _initalizeData.allowList;
        // proofStorage.verifierParams = _initalizeData.verifierParams;
        proofStorage.l2BootloaderBytecodeHash = _initalizeData.l2BootloaderBytecodeHash;
        proofStorage.l2DefaultAccountBytecodeHash = _initalizeData.l2DefaultAccountBytecodeHash;
        proofStorage.priorityTxMaxGasLimit = _initalizeData.priorityTxMaxGasLimit;

        // While this does not provide a protection in the production, it is needed for local testing
        // Length of the L2Log encoding should not be equal to the length of other L2Logs' tree nodes preimages
        assert(L2_TO_L1_LOG_SERIALIZE_SIZE != 2 * 32);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    function setParams(
        VerifierParams calldata _verifierParams,
        Diamond.DiamondCutData calldata _cutData
    ) external onlyGovernor {
        proofStorage.verifierParams = _verifierParams;
        proofStorage.cutHash = keccak256(abi.encode(_cutData));
    }
}
