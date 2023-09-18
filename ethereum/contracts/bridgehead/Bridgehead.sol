// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (proxy/Proxy.sol)

pragma solidity ^0.8.13;

import "./bridgehead-deps/Registry.sol";
import "./bridgehead-deps/Router.sol";
import "./bridgehead-deps/BridgeheadGetters.sol";

contract Bridgehead is BridgeheadGetters, Router, Registry {
    function initialize(
        address _governor,
        address _chainImplementation,
        address _chainProxyAdmin,
        IAllowList _allowList,
        uint256 _priorityTxMaxGasLimit
    ) public {
        require(bridgeheadStorage.chainImplementation == address(0), "r1");
        bridgeheadStorage.governor = _governor;
        bridgeheadStorage.chainImplementation = _chainImplementation;
        bridgeheadStorage.chainProxyAdmin = _chainProxyAdmin;
        bridgeheadStorage.allowList = _allowList;
        bridgeheadStorage.priorityTxMaxGasLimit = _priorityTxMaxGasLimit;
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

    function requestL2Transaction(
        uint256 _chainId,
        address _contractL2,
        uint256 _l2Value,
        bytes calldata _calldata,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        bytes[] calldata _factoryDeps,
        address _refundRecipient
    ) public payable returns (bytes32 canonicalTxHash) {
        address chainContract = _findChain();

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
    ) external {
        address chainContract = _findChain();

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
}
