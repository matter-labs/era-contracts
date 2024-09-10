// SPDX-License-Identifier: MIT
<<<<<<< HEAD
pragma solidity 0.8.24;
=======
// We use a floating point pragma here so it can be used within other projects that interact with the zkSync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe

/// @title The interface of the ZKsync contract, responsible for the main ZKsync logic.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IZkSyncHyperchainBase {
    /// @return Returns facet name.
    function getName() external view returns (string memory);
}
