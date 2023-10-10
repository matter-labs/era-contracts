// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./chain-deps/ChainExecutor.sol";
import "./chain-deps/ChainGetters.sol";
import "./chain-deps/ChainGovernance.sol";

import "./chain-interfaces/IBridgeheadChain.sol";

contract BridgeheadChain is IBridgeheadChain, ChainExecutor, ChainGetters, ChainGovernance {
    /// @notice zkSync contract initialization
    /// @param _governor address who can manage the contract
    /// @param _allowList The address of the allow list smart contract
    function initialize(
        uint256 _chainId,
        address _proofSystem,
        address _governor,
        IAllowList _allowList
    ) external reentrancyGuardInitializer {
        require(_governor != address(0), "vy");

        chainStorage.bridgehead = msg.sender;
        chainStorage.chainId = _chainId;
        chainStorage.proofSystem = _proofSystem;
        chainStorage.governor = _governor;
        chainStorage.allowList = _allowList;
    }
}
