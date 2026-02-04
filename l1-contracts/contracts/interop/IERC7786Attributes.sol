// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title IERC7786Attributes
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

    /// @notice Specifies fee payment method for interop calls
    /// @param _useFixed true = pay fixed ZK amount, false = pay operator-set base token amount
    /// @dev This attribute is REQUIRED for all interop calls to ensure explicit fee payment choice
    /// @dev Contracts should be able to toggle this flag for Stage1/Stage2 compatibility, this is due to the fact that operator-set base token amount is dependant on operator of the chain, while fixed ZK option is not.
    function useFixedFee(bool _useFixed) external pure;
}
