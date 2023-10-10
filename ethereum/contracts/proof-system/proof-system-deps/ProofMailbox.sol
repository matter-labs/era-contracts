// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

// import {L2Log, L2Message} from "../chain-deps/ChainStorage.sol";
import "./ProofBase.sol";
import "../proof-system-interfaces/IProofMailbox.sol";
import "../chain-interfaces/IMailbox.sol";
import "../../bridgehead/bridgehead-interfaces/IBridgeheadMailbox.sol";

contract ProofMailbox is ProofBase, IProofMailbox {
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
    function withdrawFunds(
        uint256 _chainId,
        address _to,
        uint256 _amount
    ) external onlyChain(_chainId) {
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
}
