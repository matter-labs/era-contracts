// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

// import {L2Log, L2Message} from "../chain-deps/ChainStorage.sol";
import "./BridgeheadBase.sol";
import "../bridgehead-interfaces/IBridgeheadMailbox.sol";
import "../chain-interfaces/IBridgeheadChain.sol";

contract BridgeheadMailbox is BridgeheadBase, IBridgeheadMailbox {
    function isEthWithdrawalFinalized(
        uint256 _chainId,
        uint256 _l2MessageIndex,
        uint256 _l2TxNumberInBlock
    ) external view override returns (bool) {
        address chainContract = bridgeheadStorage.chainContract[_chainId];
        return IBridgeheadChain(chainContract).isEthWithdrawalFinalized(_l2MessageIndex, _l2TxNumberInBlock);
    }

    function proveL2MessageInclusion(
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) external view override returns (bool) {
        address chainContract = bridgeheadStorage.chainContract[_chainId];
        return IBridgeheadChain(chainContract).proveL2MessageInclusion(_blockNumber, _index, _message, _proof);
    }

    function proveL2LogInclusion(
        uint256 _chainId,
        uint256 _blockNumber,
        uint256 _index,
        L2Log memory _log,
        bytes32[] calldata _proof
    ) external view override returns (bool) {
        address chainContract = bridgeheadStorage.chainContract[_chainId];
        return IBridgeheadChain(chainContract).proveL2LogInclusion(_blockNumber, _index, _log, _proof);
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
        address chainContract = bridgeheadStorage.chainContract[_chainId];
        return
            IBridgeheadChain(chainContract).proveL1ToL2TransactionStatus(
                _l2TxHash,
                _l2BlockNumber,
                _l2MessageIndex,
                _l2TxNumberInBlock,
                _merkleProof,
                _status
            );
    }

    function requestL2Transaction(
        uint256 _chainId,
        address _contractL2,
        uint256 _l2Value,
        bytes calldata _calldata,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        bytes[] calldata _factoryDeps,
        address _refundRecipient
    ) public payable override returns (bytes32 canonicalTxHash) {
        address chainContract = bridgeheadStorage.chainContract[_chainId];
        canonicalTxHash = IBridgeheadChain(chainContract).requestL2TransactionBridgehead{value: msg.value}(
            msg.sender,
            _contractL2,
            _l2Value,
            _calldata,
            _l2GasLimit,
            _l2GasPerPubdataByteLimit,
            _factoryDeps,
            _refundRecipient
        );
    }

    function finalizeEthWithdrawal(
        uint256 _chainId,
        uint256 _l2BlockNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBlock,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external override {
        address chainContract = bridgeheadStorage.chainContract[_chainId];
        return
            IBridgeheadChain(chainContract).finalizeEthWithdrawalBridgehead(
                msg.sender,
                _l2BlockNumber,
                _l2MessageIndex,
                _l2TxNumberInBlock,
                _message,
                _merkleProof
            );
    }

    function deposit(uint256 _chainId) external payable onlyChainContract(_chainId) {}

    /// @notice Transfer ether from the contract to the receiver
    /// @dev Reverts only if the transfer call failed
    function withdrawFunds(
        uint256 _chainId,
        address _to,
        uint256 _amount
    ) external onlyChainContract(_chainId) {
        bool callSuccess;
        // Low-level assembly call, to avoid any memory copying (save gas)
        assembly {
            callSuccess := call(gas(), _to, _amount, 0, 0, 0, 0)
        }
        require(callSuccess, "pz");
    }

    function l2TransactionBaseCost(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256) {
        address chainContract = bridgeheadStorage.chainContract[_chainId];
        return IBridgeheadChain(chainContract).l2TransactionBaseCost(_gasPrice, _l2GasLimit, _l2GasPerPubdataByteLimit);
    }
}
