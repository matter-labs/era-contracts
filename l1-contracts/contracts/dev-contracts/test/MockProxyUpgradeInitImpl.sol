// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";

import {IActiveRegistryProvider} from "../../upgrades/registry/IUpgradeInit.sol";

interface IManifestHash {
    function manifestHash() external view returns (bytes32);
}

/// @title MockProxyUpgradeInitImpl
/// @notice Test-only implementation exercising the fixed `initializeUpgrade()` reinitializer
///         path: it discovers the registry object being applied through the provider chain
///         (`msg.sender` is the ProxyAdmin, its owner is the executor/migration answering
///         `activeRegistry()`) and stores that object's manifest hash for assertions.
/// @dev No reinitializer replay guard: production implementations MUST carry one (the function
///      is external on the proxy); these tests never upgrade the same proxy twice.
contract MockProxyUpgradeInitImpl {
    bytes32 public initializedFromManifest;

    function initializeUpgrade() external {
        address provider = Ownable(msg.sender).owner();
        address registry = IActiveRegistryProvider(provider).activeRegistry();
        initializedFromManifest = IManifestHash(registry).manifestHash();
    }

    function version() external pure returns (uint256) {
        return 42;
    }
}
