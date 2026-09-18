// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

interface ISystemContractProxy {
    /// @notice Force initializes the admin of the proxy.
    /// @dev Note, that since constructors are not supported, the
    /// initially stored value for the admin is zero and L2_COMPLEX_UPGRADER_ADDR is allowed
    /// to update the admin to the real admin.
    /// Once it's changed, it will return the stored admin. The TransparentUpgradeableProxy
    /// ensures that the stored admin can never be set to zero address (without a buggy implementation).
    function forceInitAdmin(address _newAdmin) external;
}
