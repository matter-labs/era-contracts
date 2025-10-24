// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title IERC778Attributes
/// @notice Interface for the ERC7786 gateway source
/// @dev When adding/removing a function here the InteropCenter must be updated to reflect the changes.
/// https://github.com/ethereum/ERCs/blob/023a7d657666308568d3d1391c578d5972636093/ERCS/erc-7786.md
interface IERC7786Attributes {
    function indirectCall(uint256 _indirectCallMessageValue) external pure;

    function interopCallValue(uint256 _interopCallValue) external pure;

    // Attribute assumes that _executionAddress is an ERC-7930 address.
    function executionAddress(bytes calldata _executionAddress) external pure;

    // Attribute assumes that _executionAddress is an ERC-7930 address.
    function unbundlerAddress(bytes calldata _unbundlerAddress) external pure;
}
