// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Proxy} from "@openzeppelin/contracts-v4/proxy/Proxy.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {ConstructorsNotSupported, SystemContractProxyInitialized} from "../common/L1ContractErrors.sol";
import {ISystemContractProxy} from "./ISystemContractProxy.sol";

/// @notice Proxy contract for system contracts on L2.
/// Note, that constructors are not supported during force deployments, so the first
/// thing that should happen after the contract is spawned is the initialization of the admin.
contract SystemContractProxy is TransparentUpgradeableProxy {
    /// @dev The constructor is never expected to be actually activated.
    constructor() TransparentUpgradeableProxy(address(0), address(0), "") {
        revert ConstructorsNotSupported();
    }

    /// @notice Force initializes the admin of the proxy.
    /// @dev You can read more about the logic in the doc-comments for the interface.
    /// The contract does not inherit the interface for the reasons of implementing the
    /// transparent proxy pattern correctly.
    function _dispatchForceInitAdmin() internal {
        address newAdmin = abi.decode(msg.data[4:], (address));
        _changeAdmin(newAdmin);
    }

    /// @notice For gas savings, we override the _fallback function to avoid the extra
    /// storage read of the admin slot, since we know that the admin will never call the implementation of the proxy.
    function _fallback() internal override {
        bytes4 selector = msg.sig;

        if (
            selector == ITransparentUpgradeableProxy.upgradeTo.selector ||
            selector == ITransparentUpgradeableProxy.upgradeToAndCall.selector ||
            selector == ITransparentUpgradeableProxy.changeAdmin.selector ||
            selector == ITransparentUpgradeableProxy.admin.selector ||
            selector == ITransparentUpgradeableProxy.implementation.selector
        ) {
            super._fallback();
        } else if (selector == ISystemContractProxy.forceInitAdmin.selector) {
            if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
                Proxy._fallback();
                // The `Proxy._fallback()` will delegate the call to the implementation, and does the complete return,
                // making any code after that unreachable so we don't need to do anything else here.
            }

            // This functionality is only allowed if the admin is still uninitialized.
            // It is needed to initialize the admin after force deployments.
            // Once initialized to a non-zero, non-upgrader address, the admin can never be changed to zero address again
            // due to how the TransparentUpgradeableProxy is implemented.
            require(_getAdmin() == address(0), SystemContractProxyInitialized());
            // Call the internal function to force initialize the admin.
            _dispatchForceInitAdmin();
        } else {
            // Directly delegate to implementation without admin check.
            Proxy._fallback();
        }
    }
}
