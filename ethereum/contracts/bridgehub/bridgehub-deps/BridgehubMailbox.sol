// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

// import {L2Log, L2Message} from "../chain-deps/ChainStorage.sol";
import "./BridgehubBase.sol";
import "../bridgehub-interfaces/IBridgehubMailbox.sol";
import "../../state-transition/chain-interfaces/IStateTransitionChain.sol";

contract BridgehubMailboxFacet is BridgehubBase, IBridgehubMailbox {
    function isEthWithdrawalFinalized(
        uint256 _chainId,
        uint256 _l2MessageIndex,
        uint256 _l2TxNumberInBlock
    ) external view override returns (bool) {
        address stateTransitionChain = bridgehubStorage.stateTransitionChain[_chainId];
        return
            IStateTransitionChain(stateTransitionChain).isEthWithdrawalFinalized(_l2MessageIndex, _l2TxNumberInBlock);
    }

    function proveL2MessageInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) external view override returns (bool) {
        address stateTransitionChain = bridgehubStorage.stateTransitionChain[_chainId];
        return
            IStateTransitionChain(stateTransitionChain).proveL2MessageInclusion(_batchNumber, _index, _message, _proof);
    }

    function proveL2LogInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Log memory _log,
        bytes32[] calldata _proof
    ) external view override returns (bool) {
        address stateTransitionChain = bridgehubStorage.stateTransitionChain[_chainId];
        return IStateTransitionChain(stateTransitionChain).proveL2LogInclusion(_batchNumber, _index, _log, _proof);
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
        address stateTransitionChain = bridgehubStorage.stateTransitionChain[_chainId];
        return
            IStateTransitionChain(stateTransitionChain).proveL1ToL2TransactionStatus(
                _l2TxHash,
                _l2BlockNumber,
                _l2MessageIndex,
                _l2TxNumberInBlock,
                _merkleProof,
                _status
            );
    }

    function l2TransactionBaseCost(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256) {
        require(address(1) != address(0), "zero addres");

        address stateTransitionChain = bridgehubStorage.stateTransitionChain[_chainId];
        return
            IStateTransitionChain(stateTransitionChain).l2TransactionBaseCost(
                _gasPrice,
                _l2GasLimit,
                _l2GasPerPubdataByteLimit
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
        address stateTransitionChain = bridgehubStorage.stateTransitionChain[_chainId];
        canonicalTxHash = IStateTransitionChain(stateTransitionChain).requestL2TransactionBridgehub(
            msg.value,
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
        address stateTransitionChain = bridgehubStorage.stateTransitionChain[_chainId];
        return
            IStateTransitionChain(stateTransitionChain).finalizeEthWithdrawalBridgehub(
                msg.sender,
                _l2BlockNumber,
                _l2MessageIndex,
                _l2TxNumberInBlock,
                _message,
                _merkleProof
            );
    }

    function deposit(uint256 _chainId) external payable onlyStateTransitionChain(_chainId) {
        // just accept eth
        return;
    }

    /// @notice Transfer ether from the contract to the receiver
    /// @dev Reverts only if the transfer call failed
    function withdrawFunds(uint256 _chainId, address _to, uint256 _amount) external onlyStateTransitionChain(_chainId) {
        bool callSuccess;
        // Low-level assembly call, to avoid any memory copying (save gas)
        assembly {
            callSuccess := call(gas(), _to, _amount, 0, 0, 0, 0)
        }
        require(callSuccess, "pz");
    }
}
