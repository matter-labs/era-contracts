// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ICoreTransition} from "../objects/ICoreTransition.sol";
import {ICoreUpgradeExecutor} from "./ICoreUpgradeExecutor.sol";
import {DomainUpgradeExecutorBase} from "./DomainUpgradeExecutorBase.sol";
import {LegNotReserved, Unauthorized, ZeroAddress} from "../../../common/L1ContractErrors.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";
import {OperationManifest} from "../RegistryTypes.sol";

/// @title CoreUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Domain executor BOUND to the ecosystem `ProxyAdmin`: it owns that admin and applies
///         the shared-singleton implementation swaps pinned in write-once `CoreTransition` objects.
///         Inside an ecosystem upgrade it acts on the coordinator's instructions for exactly the
///         core transition it was reserved for; see {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @dev Fixed logic, no generic delegatecall.
contract CoreUpgradeExecutor is DomainUpgradeExecutorBase, ICoreUpgradeExecutor {
    using ObjectAnchorLib for address;

    /// @notice The ecosystem `ProxyAdmin` — admin of every shared singleton proxy. Owned by this
    ///         executor, so transition rows apply through the same authority that validates them.
    ProxyAdmin public immutable PROXY_ADMIN;

    /// @inheritdoc ICoreUpgradeExecutor
    ICoreTransition public reservedCoreTransition;

    constructor(address _initialOwner, ProxyAdmin _proxyAdmin) DomainUpgradeExecutorBase(_initialOwner, address(0)) {
        if (address(_proxyAdmin) == address(0)) {
            revert ZeroAddress();
        }
        PROXY_ADMIN = _proxyAdmin;
    }

    /// @inheritdoc ICoreUpgradeExecutor
    function applyL1Upgrade(ICoreTransition _coreTransition) external {
        if (msg.sender == coordinator) {
            ICoreTransition reserved = reservedCoreTransition;
            if (address(reserved) != address(_coreTransition)) {
                revert LegNotReserved(address(_coreTransition), address(reserved));
            }
        } else if (msg.sender != owner()) {
            revert Unauthorized(msg.sender);
        }
        address(_coreTransition).requireCode();
        _coreTransition.validate();
        ProxyUpgradeRowLib.applyRows(PROXY_ADMIN, _coreTransition.ecosystemRows());
        emit L1UpgradeApplied(address(_coreTransition));
    }

    /// @dev The ecosystem leg is the manifest's core transition, which must be deployed and valid.
    function _reserveLeg(OperationManifest calldata _manifest) internal override returns (address) {
        ICoreTransition coreTransition = ICoreTransition(_manifest.coreTransition);
        if (address(coreTransition) == address(0)) {
            revert ZeroAddress();
        }
        address(coreTransition).requireCode();
        coreTransition.validate();
        reservedCoreTransition = coreTransition;
        return address(coreTransition);
    }

    function _releaseLeg() internal override {
        delete reservedCoreTransition;
    }
}
