// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ICoreRegistry, EcosystemContractRow} from "../objects/ICoreRegistry.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {EcosystemImplMismatch, EmptyBytes32, ZeroAddress} from "../../../common/L1ContractErrors.sol";
import {CodehashPinLib} from "../libraries/CodehashPinLib.sol";

/// @title EcosystemUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Domain-specific executor BOUND to one immutable ecosystem `ProxyAdmin`: it owns that
///         admin and points every ecosystem proxy at its new implementation, as pinned by a
///         write-once core registry. Ecosystem authority is deliberately separate from CTM
///         authority (`CTMUpgradeExecutor`).
/// @dev Fixed logic, no generic delegatecall. The break-glass `forward` (base) is gated by a
///      SEPARATE governor. The registry address is a *pinned implementation address* — the exact
///      generated contract governance approved — never a proxy.
contract EcosystemUpgradeExecutor is UpgradeExecutorBase {
    using CodehashPinLib for address;

    /// @notice The one ecosystem `ProxyAdmin` this executor governs. Registries carry no proxy
    ///         admin pointer; the binding is this immutable.
    ProxyAdmin public immutable PROXY_ADMIN;

    /// @notice `EXTCODEHASH` of the audited `CoreRegistry` — see
    ///         `CTMUpgradeExecutor.TRANSITION_CODEHASH` for the provenance model.
    bytes32 public immutable CORE_REGISTRY_CODEHASH;

    /// @notice Emitted for every ecosystem proxy pointed at its new implementation. The proxy
    ///         ADDRESS is the row identity (human labels live in the off-chain manifest).
    event EcosystemContractUpgraded(address indexed proxy, address newImpl);

    constructor(
        address _initialOwner,
        address _breakGlassGovernor,
        ProxyAdmin _proxyAdmin,
        bytes32 _coreRegistryCodehash
    ) UpgradeExecutorBase(_initialOwner, _breakGlassGovernor) {
        if (address(_proxyAdmin) == address(0)) {
            revert ZeroAddress();
        }
        if (_coreRegistryCodehash == bytes32(0)) {
            revert EmptyBytes32();
        }
        PROXY_ADMIN = _proxyAdmin;
        CORE_REGISTRY_CODEHASH = _coreRegistryCodehash;
    }

    /// @notice Points every ecosystem proxy at its new implementation, as pinned by the registry.
    ///         Rows are SOURCE-CHECKED edges: a proxy already at `implNew` is skipped
    ///         (idempotence); a proxy at `expectedOldImpl` is upgraded; a proxy at anything else
    ///         reverts — replaying a stale registry can therefore never downgrade a proxy that a
    ///         later upgrade has already moved on.
    /// @dev The live read through the bound `ProxyAdmin` is safe here — unlike the CTM diamond
    ///      cut (committed as a hash for a whole upgrade window), this function reads and writes
    ///      in one atomic transaction.
    /// @param _coreRegistry The pinned core-registry implementation approved by governance.
    function applyL1Upgrade(ICoreRegistry _coreRegistry) external onlyOwner {
        address(_coreRegistry).requirePin(CORE_REGISTRY_CODEHASH);
        _coreRegistry.validate();

        // One call returns complete typed rows; no per-key rescans of the registry.
        EcosystemContractRow[] memory rows = _coreRegistry.ecosystemRows();
        uint256 rowsLength = rows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            // Every row is a real edge by registry construction (no placeholder rows exist).
            address newImpl = rows[i].implNew;
            ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(rows[i].proxy);
            address liveImpl = PROXY_ADMIN.getProxyImplementation(proxy);
            if (liveImpl == newImpl) {
                continue;
            }
            if (liveImpl != rows[i].expectedOldImpl) {
                revert EcosystemImplMismatch(rows[i].proxy, rows[i].expectedOldImpl, liveImpl);
            }
            PROXY_ADMIN.upgrade(proxy, newImpl);
            emit EcosystemContractUpgraded(address(proxy), newImpl);
        }
    }
}
