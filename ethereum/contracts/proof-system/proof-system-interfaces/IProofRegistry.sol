// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

// import "./IProofBase.sol";
import "../../common/libraries/Diamond.sol";

interface IProofRegistry {
    /// @notice
    function newChain(
        uint256 _chainId,
        address _bridgeheadChainContract,
        address _governor,
        Diamond.DiamondCutData memory _diamondCut
    ) external;

    // when a new Chain is added
    event NewProofChain(uint256 indexed _chainId, address indexed _proofChainContract);
}
