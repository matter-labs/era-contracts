// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {IProxyUpgradeTransition} from "../objects/IProxyUpgradeTransition.sol";
import {ICoreUpgradeExecutor} from "./ICoreUpgradeExecutor.sol";
import {ProxyUpgradeExecutorBase} from "./ProxyUpgradeExecutorBase.sol";
import {ZeroAddress} from "../../../common/L1ContractErrors.sol";
import {ProxyUpgradeDomain} from "../RegistryTypes.sol";

/// @title CoreUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Domain executor BOUND to the ecosystem `ProxyAdmin`: it owns that admin and applies the
///         shared-singleton implementation swaps pinned in write-once Core-domain
///         `ProxyUpgradeTransition` objects; see {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @dev Fixed logic. Its one delegatecall is into the engine an approved transition pins
///      ({ProxyUpgradeExecutorBase}); there is no generic one.
contract CoreUpgradeExecutor is ProxyUpgradeExecutorBase, ICoreUpgradeExecutor {
    /// @notice The ecosystem `ProxyAdmin` — admin of every shared singleton proxy. Owned by this
    ///         executor, so transition rows apply through the same authority that validates them.
    ProxyAdmin public immutable PROXY_ADMIN;

    constructor(address _initialOwner, ProxyAdmin _proxyAdmin) ProxyUpgradeExecutorBase(_initialOwner) {
        if (address(_proxyAdmin) == address(0)) {
            revert ZeroAddress();
        }
        PROXY_ADMIN = _proxyAdmin;
    }

    /// @inheritdoc ICoreUpgradeExecutor
    function applyL1Upgrade(IProxyUpgradeTransition _coreTransition) external onlyOwner {
        _applyProxyUpgradeTransition(PROXY_ADMIN, _coreTransition, ProxyUpgradeDomain.Core, address(0));
        emit L1UpgradeApplied(address(_coreTransition));
    }
}
