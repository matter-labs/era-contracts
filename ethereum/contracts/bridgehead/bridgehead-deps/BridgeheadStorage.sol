// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (proxy/Proxy.sol)

pragma solidity ^0.8.13;

import "../../common/interfaces/IAllowList.sol";
import "../../proof-system/proof-system-interfaces/IProofSystem.sol";

struct BridgeheadStorage {
    address governor;
    IAllowList allowList;
    /// @notice the location of the
    // address chainImplementation;
    // address chainProxyAdmin;
    /// implementation contract
    // mapping(uint256 => address) chainContract;
    /// @notice The proofSystem Contract of each chainID
    mapping(uint256 => address) proofSystem;
    /// @notice
    mapping(address => bool) proofSystemIsRegistered;
}
