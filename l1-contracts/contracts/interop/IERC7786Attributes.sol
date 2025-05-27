// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title IERC778Attributes
/// @notice Interface for the ERC7786 gateway source
/// https://github.com/ethereum/ERCs/blob/023a7d657666308568d3d1391c578d5972636093/ERCS/erc-7786.md
interface IERC7786Attributes {
    function directCall(uint256 _indirectCallMessageValue) external pure;
}
