// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";

import {IUpgradeInitDataProvider} from "../../upgrades/registry/IUpgradeInit.sol";

/// @title MockProxyUpgradeInitImpl
/// @notice Test-only implementation exercising the fixed `initializeUpgrade()` reinitializer
///         path: it fetches its pinned data through the provider chain (`msg.sender` is the
///         ProxyAdmin, its owner is the executor/migration serving the active inventory's
///         `initData`) and stores the decoded value for assertions.
/// @dev No reinitializer replay guard: production implementations MUST carry one (the function
///      is external on the proxy); these tests never upgrade the same proxy twice.
contract MockProxyUpgradeInitImpl {
    uint256 public initializedValue;

    function initializeUpgrade() external {
        address provider = Ownable(msg.sender).owner();
        bytes memory data = IUpgradeInitDataProvider(provider).upgradeInitData(address(this));
        initializedValue = abi.decode(data, (uint256));
    }

    function version() external pure returns (uint256) {
        return 42;
    }
}
