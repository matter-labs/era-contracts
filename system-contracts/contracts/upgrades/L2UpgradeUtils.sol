// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {SystemContractHelper} from "../libraries/SystemContractHelper.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";

/// @dev Storage slot with the admin of the contract used for EIP1967 proxies (e.g., TUP, BeaconProxy, etc.).
bytes32 constant PROXY_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @title L2UpgradeUtils
/// @notice Utility functions that help with the upgrade of the L2 protocol.
library L2UpgradeUtils {
    /// @notice Forces an upgrade of a TransparentUpgradeableProxy contract.
    /// @dev Constructs the appropriate calldata for upgrading the proxy and executes the upgrade
    /// by mimicCall-ing the admin of the proxy.
    /// @param _proxyAddr Address of the TransparentUpgradeableProxy to upgrade.
    /// @param _newImpl Address of the new implementation contract.
    /// @param _additionalData Additional calldata to pass to the `upgradeToAndCall` function, if any.
    function forceUpgradeTransparentProxy(address _proxyAddr, address _newImpl, bytes memory _additionalData) internal {
        bytes memory upgradeData;
        if (_additionalData.length > 0) {
            upgradeData = abi.encodeCall(ITransparentUpgradeableProxy.upgradeToAndCall, (_newImpl, _additionalData));
        } else {
            upgradeData = abi.encodeCall(ITransparentUpgradeableProxy.upgradeTo, (_newImpl));
        }

        // Retrieve the proxy admin address from the proxy's storage slot.
        address proxyAdmin = address(uint160(uint256(SystemContractHelper.forcedSload(_proxyAddr, PROXY_ADMIN_SLOT))));

        SystemContractHelper.mimicCallWithPropagatedRevert(_proxyAddr, proxyAdmin, upgradeData);
    }

    /// @notice Forces an upgrade of an UpgradeableBeacon proxy contract.
    /// @dev Constructs the appropriate calldata for upgrading the proxy and executes the upgrade
    /// by mimicCall-ing the admin of the proxy.
    /// @param _proxyAddr Address of the UpgradeableBeacon proxy to upgrade.
    /// @param _newImpl Address of the new implementation contract.
    function forceUpgradeBeaconProxy(address _proxyAddr, address _newImpl) internal {
        bytes memory upgradeData = abi.encodeCall(UpgradeableBeacon.upgradeTo, (_newImpl));

        // Retrieve the owner of the beacon.
        address owner = UpgradeableBeacon(_proxyAddr).owner();

        // Execute the upgrade via a low-level call, propagating any revert.
        SystemContractHelper.mimicCallWithPropagatedRevert(_proxyAddr, owner, upgradeData);
    }
}
