// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

// import "./IProofBase.sol";
import "../../common/libraries/Diamond.sol";

interface IProofForBridgehead {
    //is IProofBase {
    function newChain(
        uint256 _chainId,
        address _chainContract,
        address _governor,
        Diamond.DiamondCutData calldata _diamondCut
    ) external;
}
