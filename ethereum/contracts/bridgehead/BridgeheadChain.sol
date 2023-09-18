// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./chain-deps/ChainExecutor.sol";
import "./chain-deps/ChainGetters.sol";
import "./chain-deps/ChainGovernance.sol";
import "./chain-deps/Mailbox.sol";

import "./chain-interfaces/IBridgeheadChain.sol";

contract BridgeheadChain is IBridgeheadChain, ChainExecutor, ChainGetters, ChainGovernance, Mailbox {
    /// @notice zkSync contract initialization
    /// @param _governor address who can manage the contract
    /// @param _allowList The address of the allow list smart contract
    /// @param _priorityTxMaxGasLimit maximum number of the L2 gas that a user can request for L1 -> L2 transactions
    function initialize(
        uint256 _chainId,
        address _proofSystem,
        address _governor,
        IAllowList _allowList,
        uint256 _priorityTxMaxGasLimit
    ) external reentrancyGuardInitializer {
        require(_governor != address(0), "vy");

        chainStorage.bridgehead = msg.sender;
        chainStorage.chainId = _chainId;
        chainStorage.proofSystem = _proofSystem;
        chainStorage.governor = _governor;
        chainStorage.allowList = _allowList;
        chainStorage.priorityTxMaxGasLimit = _priorityTxMaxGasLimit;
    }
}
