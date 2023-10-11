// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (proxy/Proxy.sol)

pragma solidity ^0.8.13;

import {L2_TO_L1_LOG_SERIALIZE_SIZE, EMPTY_STRING_KECCAK, DEFAULT_L2_LOGS_TREE_ROOT_HASH, L2_TX_MAX_GAS_LIMIT, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "../common/Config.sol";
import {L2_FORCE_DEPLOYER_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR} from "../common/L2ContractAddresses.sol";

import {DiamondProxy} from "../common/DiamondProxy.sol";
import {IDiamondInit} from "./chain-interfaces/IDiamondInit.sol";
import {IAllowList} from "../common/interfaces/IAllowList.sol";
import {L2Message, L2Log, TxStatus, WritePriorityOpParams} from "../common/Messaging.sol";
import {IVerifier} from "./chain-interfaces/IVerifier.sol";
import {IExecutor} from "./chain-interfaces/IExecutor.sol";
import {IMailbox} from "./chain-interfaces/IMailbox.sol";
import {IBridgeheadMailbox} from "../bridgehead/bridgehead-interfaces/IBridgeheadMailbox.sol";
import {ISystemContext} from "./l2-deps/ISystemContext.sol";
import {Diamond} from "../common/libraries/Diamond.sol";
import {ProofBase} from "./proof-system-deps/ProofBase.sol";
import {Verifier} from "./Verifier.sol";
import {VerifierParams} from "./chain-deps/ProofChainStorage.sol";
import {InitializeData} from "./proof-system-interfaces/IProofSystem.sol";
import {IProofRegistry} from "./proof-system-interfaces/IProofRegistry.sol";
import {IProofMailbox} from "./proof-system-interfaces/IProofMailbox.sol";

/* solhint-disable max-line-length */

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The contract is used only once to initialize the diamond proxy.
/// @dev The deployment process takes care of this contract's initialization.
contract ProofSystem is IProofRegistry, IProofMailbox, ProofBase {
    //////// Getters

    /// @return The address of the current governor
    function getGovernor() external view returns (address) {
        return proofStorage.governor;
    }

    /// @return The address of the current admin
    function getAdmin() external view returns (address) {
        return proofStorage.admin;
    }

    /// @return The address of the allowList
    function getAllowList() external view returns (address) {
        return proofStorage.allowList;
    }

    function getBridgehead() external view returns (address) {
        return proofStorage.bridgehead;
    }

    function getProofChainContract(uint256 _chainId) external view returns (address) {
        return proofStorage.proofChainContract[_chainId];
    }

    //////// ProofRegistry

    // we have to set the chainId, as blockhashzero is the same for all chains, and specifies the genesis chainId
    function _specialSetChainIdInVMTx(uint256 _chainId, address _chainContract) internal {
        WritePriorityOpParams memory params;

        params.sender = L2_FORCE_DEPLOYER_ADDR;
        params.l2Value = 0;
        params.contractAddressL2 = L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR;
        params.l2GasLimit = $(PRIORITY_TX_MAX_GAS_LIMIT);
        params.l2GasPricePerPubdata = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        params.refundRecipient = address(0);

        bytes memory setChainIdCalldata = abi.encodeCall(ISystemContext.setChainId, (_chainId));
        bytes[] memory emptyA;

        IMailbox(_chainContract).requestL2TransactionProof(params, setChainIdCalldata, emptyA, true);
    }

    /// @notice
    function newChain(
        uint256 _chainId,
        address _governor,
        Diamond.DiamondCutData calldata _diamondCut
    ) external onlyBridgehead {
        bytes32 cutHash = keccak256(abi.encode(_diamondCut));
        require(cutHash == proofStorage.cutHash, "r25");

        bytes memory initData;
        bytes memory copiedData = _diamondCut.initCalldata[132:];
        initData = bytes.concat(
            IDiamondInit.initialize.selector,
            bytes32(_chainId),
            bytes32(uint256(uint160(address(this)))),
            bytes32(uint256(uint160(_governor))),
            bytes32(proofStorage.storedBatchZero),
            copiedData
        );
        Diamond.DiamondCutData memory cutData = _diamondCut;
        cutData.initCalldata = initData;

        DiamondProxy proofChainContract = new DiamondProxy(
            block.chainid,
            cutData
            // _diamondCut
        );

        // IBridgeheadChain(_bridgeheadChainContract).setProofChainContract(address(proofChainContract));
        _specialSetChainIdInVMTx(_chainId, address(proofChainContract));
        proofStorage.proofChainContract[_chainId] = address(proofChainContract);

        emit NewProofChain(_chainId, address(proofChainContract));
    }

    function leaveChain(uint256 chainID) external onlyBridgehead {}

    //////// Mailbox

    function isEthWithdrawalFinalized(
        uint256 _chainId,
        uint256 _l2MessageIndex,
        uint256 _l2TxNumberInBlock
    ) external view override returns (bool) {
        address proofChainContract = proofStorage.proofChainContract[_chainId];
        return IMailbox(proofChainContract).isEthWithdrawalFinalized(_l2MessageIndex, _l2TxNumberInBlock);
    }

    function proveL2MessageInclusion(
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) external view override returns (bool) {
        address proofChainContract = proofStorage.proofChainContract[_chainId];
        return IMailbox(proofChainContract).proveL2MessageInclusion(_blockNumber, _index, _message, _proof);
    }

    function proveL2LogInclusion(
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _index,
        L2Log memory _log,
        bytes32[] calldata _proof
    ) external view override returns (bool) {
        address proofChainContract = proofStorage.proofChainContract[_chainId];
        return IMailbox(proofChainContract).proveL2LogInclusion(_blockNumber, _index, _log, _proof);
    }

    function proveL1ToL2TransactionStatus(
        uint256 _chainId,
        bytes32 _l2TxHash,
        uint256 _l2BlockNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBlock,
        bytes32[] calldata _merkleProof,
        TxStatus _status
    ) external view override returns (bool) {
        address proofChainContract = proofStorage.proofChainContract[_chainId];
        return
            IMailbox(proofChainContract).proveL1ToL2TransactionStatus(
                _l2TxHash,
                _l2BlockNumber,
                _l2MessageIndex,
                _l2TxNumberInBlock,
                _merkleProof,
                _status
            );
    }

    function requestL2TransactionBridgehead(
        uint256 _chainId,
        uint256 _msgValue,
        address _msgSender,
        address _contractL2,
        uint256 _l2Value,
        bytes calldata _calldata,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        bytes[] calldata _factoryDeps,
        address _refundRecipient
    ) public payable override onlyBridgehead returns (bytes32 canonicalTxHash) {
        address proofChainContract = proofStorage.proofChainContract[_chainId];
        canonicalTxHash = IMailbox(proofChainContract).requestL2TransactionBridgehead(
            _msgValue,
            _msgSender,
            _contractL2,
            _l2Value,
            _calldata,
            _l2GasLimit,
            _l2GasPerPubdataByteLimit,
            _factoryDeps,
            _refundRecipient
        );
    }

    function finalizeEthWithdrawalBridgehead(
        uint256 _chainId,
        address _msgSender,
        uint256 _l2BlockNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBlock,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external override onlyBridgehead {
        address proofChainContract = proofStorage.proofChainContract[_chainId];
        return
            IMailbox(proofChainContract).finalizeEthWithdrawalBridgehead(
                msg.sender,
                _l2BlockNumber,
                _l2MessageIndex,
                _l2TxNumberInBlock,
                _message,
                _merkleProof
            );
    }

    function deposit(uint256 _chainId) external payable onlyChain(_chainId) {
        IBridgeheadMailbox(proofStorage.bridgehead).deposit{value: msg.value}(_chainId);
    }

    /// @notice Transfer ether from the contract to the receiver
    /// @dev Reverts only if the transfer call failed
    function withdrawFunds(uint256 _chainId, address _to, uint256 _amount) external onlyChain(_chainId) {
        IBridgeheadMailbox(proofStorage.bridgehead).withdrawFunds(_chainId, _to, _amount);
    }

    function l2TransactionBaseCost(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256) {
        address proofChainContract = proofStorage.proofChainContract[_chainId];
        return IMailbox(proofChainContract).l2TransactionBaseCost(_gasPrice, _l2GasLimit, _l2GasPerPubdataByteLimit);
    }

    //////// initialize

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
