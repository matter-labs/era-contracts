// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ICoreTransition} from "../objects/ICoreTransition.sol";
import {ICoreUpgradeExecutor} from "./ICoreUpgradeExecutor.sol";
import {IDomainUpgradeExecutor} from "./IDomainUpgradeExecutor.sol";
import {DomainUpgradeExecutorBase} from "./DomainUpgradeExecutorBase.sol";
import {ZeroAddress} from "../../../common/L1ContractErrors.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";
import {OperationManifest} from "../RegistryTypes.sol";

/// @title CoreUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Domain executor BOUND to the ecosystem `ProxyAdmin`: it owns that admin and applies
///         the shared-singleton implementation swaps pinned in write-once `CoreTransition` objects,
///         on the coordinator's instruction inside an operation or on the owner's outside one; see
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @dev Fixed logic, no generic delegatecall.
contract CoreUpgradeExecutor is DomainUpgradeExecutorBase, ICoreUpgradeExecutor {
    using ObjectAnchorLib for address;

    /// @notice The ecosystem `ProxyAdmin` — admin of every shared singleton proxy. Owned by this
    ///         executor, so transition rows apply through the same authority that validates them.
    ProxyAdmin public immutable PROXY_ADMIN;

    constructor(address _initialOwner, ProxyAdmin _proxyAdmin) DomainUpgradeExecutorBase(_initialOwner, address(0)) {
        if (address(_proxyAdmin) == address(0)) {
            revert ZeroAddress();
        }
        PROXY_ADMIN = _proxyAdmin;
    }

    /// @inheritdoc IDomainUpgradeExecutor
    /// @dev The ecosystem leg is the manifest's core transition; the coordinator calls this only
    ///      for an operation that names one.
    function applyOperation(OperationManifest calldata _manifest) external onlyCoordinator {
        _applyCoreTransition(ICoreTransition(_manifest.coreTransition));
    }

    /// @inheritdoc ICoreUpgradeExecutor
    function applyL1Upgrade(ICoreTransition _coreTransition) external onlyOwner {
        _applyCoreTransition(_coreTransition);
    }

    /// @param _coreTransition The core transition to apply.
    function _applyCoreTransition(ICoreTransition _coreTransition) private {
        address(_coreTransition).requireCode();
        _coreTransition.validate();
        ProxyUpgradeRowLib.applyRows(PROXY_ADMIN, _coreTransition.ecosystemRows());
        emit L1UpgradeApplied(address(_coreTransition));
    }
}
