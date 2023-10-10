// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

// import "../common/Config.sol";
import "./ChainBase.sol";
import "../../common/libraries/UncheckedMath.sol";
import "../chain-interfaces/IChainGetters.sol";

/// @title Getters Contract implements functions for getting contract state from outside the blockchain.
/// @author Matter Labs
contract ChainGetters is IChainGetters, ChainBase {
    using UncheckedMath for uint256;

    /*//////////////////////////////////////////////////////////////
                            CUSTOM GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @return The address of the current governor
    function getGovernor() external view returns (address) {
        return chainStorage.governor;
    }

    /// @return The address of the pending governor
    function getPendingGovernor() external view returns (address) {
        return chainStorage.pendingGovernor;
    }

    /// @return The total number of blocks that were committed & verified & executed
    function getChainId() external view returns (uint256) {
        return chainStorage.chainId;
    }

    /// @return The total number of blocks that were committed & verified & executed
    function getProofSystem() external view returns (address) {
        return chainStorage.proofSystem;
    }

    /// @return The allow list smart contract
    function getAllowList() external view returns (address) {
        return address(chainStorage.allowList);
    }
}
