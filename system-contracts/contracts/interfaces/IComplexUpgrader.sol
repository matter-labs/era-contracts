// SPDX-License-Identifier: MIT
<<<<<<< HEAD
// We use a floating point pragma here so it can be used within other projects that interact with the zkSync ecosystem without using our exact pragma version.
=======
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
pragma solidity ^0.8.20;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The interface for the ComplexUpgrader contract.
 */
interface IComplexUpgrader {
    function upgrade(address _delegateTo, bytes calldata _calldata) external payable;
}
