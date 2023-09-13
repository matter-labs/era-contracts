// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

// import "./IProofBase.sol";

interface IProofRegistry {
    /// @notice
    function newChain(
        uint256 _chainID,
        address _chainContract,
        address _governor
    ) external;

    // when a new Chain is added
    event NewProofChain(uint256 indexed _chainId, address indexed _proofChainContract);
}
