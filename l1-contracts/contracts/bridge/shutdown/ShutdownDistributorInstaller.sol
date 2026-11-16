// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ERC1967Upgrade} from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Upgrade.sol";

import {Unauthorized, ZeroAddress} from "../../common/L1ContractErrors.sol";

import {IShutdownClaimDistributor} from "./IShutdownClaimDistributor.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The initial implementation of the claim distributor proxy of a chain that is about to be shut down.
/// It lets the chain admin install the audited distributor exactly once.
/// @dev The governance proposal that shuts the chain down must name the distributor, but its Merkle root can only be
/// computed after the shutdown. So the distributor is first deployed as a TransparentUpgradeableProxy with this
/// implementation and the governance as proxy admin. Once the snapshot is ready, the chain admin calls `install`
/// through the proxy, which upgrades the proxy to the distributor and initializes it in the same call.
/// @dev The distributor implementation is fixed at deployment and the chain admin only provides the arguments of its
/// initializer, so the chain admin can not run any other code in the proxy, e.g. code that changes the proxy admin.
/// After `install`, the proxy no longer points to this contract, so `install` can not be called again and only the
/// governance (the proxy admin) can upgrade the distributor.
/// @dev It has no `MERKLE_ROOT()`, so `L1AssetTracker` sends and mints nothing to the distributor, and the chain's
/// funds stay in the vault, until the real distributor is in place.
contract ShutdownDistributorInstaller is ERC1967Upgrade {
    /// @notice The admin of the chain being shut down, the only address that can install the distributor.
    /// `L1AssetTracker.shutdownChain` reads it through the proxy and records it as the chain admin.
    /// @dev An immutable, so it is read from this contract's code when the proxy delegatecalls into it.
    address public immutable CHAIN_ADMIN;

    /// @notice The implementation of the audited ZKsync Lite sunset distributor that `install` upgrades the proxy to.
    address public immutable DISTRIBUTOR_IMPLEMENTATION;

    /// @param _chainAdmin The admin of the chain being shut down.
    /// @param _distributorImplementation The deployed implementation of the audited distributor.
    constructor(address _chainAdmin, address _distributorImplementation) {
        require(_chainAdmin != address(0) && _distributorImplementation != address(0), ZeroAddress());
        CHAIN_ADMIN = _chainAdmin;
        DISTRIBUTOR_IMPLEMENTATION = _distributorImplementation;
    }

    /// @notice Upgrades the proxy to the distributor and initializes it, in one call, so that no one else can
    /// initialize it first.
    /// @param _merkleRoot The root of the Merkle tree of the claims, computed from the snapshot.
    /// @param _windowStart The timestamp from which claims are accepted.
    /// @param _distributorOwner The owner of the distributor, who can pause it.
    function install(bytes32 _merkleRoot, uint256 _windowStart, address _distributorOwner) external {
        require(msg.sender == CHAIN_ADMIN, Unauthorized(msg.sender));
        _upgradeToAndCall(
            DISTRIBUTOR_IMPLEMENTATION,
            abi.encodeCall(IShutdownClaimDistributor.initialize, (_merkleRoot, _windowStart, _distributorOwner)),
            false
        );
    }
}
