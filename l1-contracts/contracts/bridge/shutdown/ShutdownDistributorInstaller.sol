// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ERC1967Upgrade} from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Upgrade.sol";

import {EmptyBytes32, Unauthorized, ZeroAddress} from "../../common/L1ContractErrors.sol";
import {InvalidShutdownDistributor} from "../asset-tracker/AssetTrackerErrors.sol";
import {IL1AssetTracker} from "../asset-tracker/IL1AssetTracker.sol";
import {IGetters} from "../../state-transition/chain-interfaces/IGetters.sol";
import {NotChainAdmin} from "../../state-transition/L1StateTransitionErrors.sol";

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
    /// @notice The asset tracker that records the shutdown of the chain.
    IL1AssetTracker public immutable L1_ASSET_TRACKER;

    /// @notice The id of the chain being shut down.
    uint256 public immutable CHAIN_ID;

    /// @notice The admin of the chain being shut down, the only address that can install the distributor.
    /// `L1AssetTracker.shutdownChain` reads it through the proxy and records it as the chain admin.
    /// @dev An immutable, so it is read from this contract's code when the proxy delegatecalls into it.
    address public immutable CHAIN_ADMIN;

    /// @notice The implementation of the audited ZKsync Lite sunset distributor that `install` upgrades the proxy to.
    address public immutable DISTRIBUTOR_IMPLEMENTATION;

    /// @param _l1AssetTracker The asset tracker that records the shutdown of the chain.
    /// @param _chainId The id of the chain being shut down.
    /// @param _chainAdmin The admin of the chain being shut down, which must be its admin at deployment.
    /// @param _distributorImplementation The deployed implementation of the audited distributor.
    constructor(
        IL1AssetTracker _l1AssetTracker,
        uint256 _chainId,
        address _chainAdmin,
        address _distributorImplementation
    ) {
        require(
            address(_l1AssetTracker) != address(0) &&
                _chainAdmin != address(0) &&
                _distributorImplementation != address(0),
            ZeroAddress()
        );
        // The installer is deployed before the governance takes over the chain admin role, so the chain admin that
        // provides the claims and mints the chain's native tokens is the one the chain really had.
        address admin = IGetters(_l1AssetTracker.BRIDGE_HUB().getZKChain(_chainId)).getAdmin();
        require(_chainAdmin == admin, NotChainAdmin(_chainAdmin, admin));
        L1_ASSET_TRACKER = _l1AssetTracker;
        CHAIN_ID = _chainId;
        CHAIN_ADMIN = _chainAdmin;
        DISTRIBUTOR_IMPLEMENTATION = _distributorImplementation;
    }

    /// @notice Upgrades the proxy to the distributor and initializes it, in one call, so that no one else can
    /// initialize it first.
    /// @dev Only possible once the chain is shut down with this proxy as its distributor: the root must be computed
    /// from the final state of the chain, which only exists after the shutdown. If the governance has replaced the
    /// distributor, this proxy can no longer be installed.
    /// @param _merkleRoot The root of the Merkle tree of the claims, computed from the snapshot. Its leaves use the
    /// distributor's format, where ETH is `address(0)`, not the vault's `ETH_TOKEN_ADDRESS`.
    /// @param _windowStart The timestamp from which claims are accepted.
    /// @param _distributorOwner The owner of the distributor, who can pause it. It must not be the proxy admin, which
    /// a TransparentUpgradeableProxy does not let call the distributor.
    function install(bytes32 _merkleRoot, uint256 _windowStart, address _distributorOwner) external {
        require(msg.sender == CHAIN_ADMIN, Unauthorized(msg.sender));
        // The distributor does not check the root, and with a zero root `L1AssetTracker` never sends it any funds.
        require(_merkleRoot != bytes32(0), EmptyBytes32());
        // `address(this)` is the proxy, which delegatecalls into this contract.
        // slither-disable-next-line unused-return
        (, address distributor) = L1_ASSET_TRACKER.shutdownChainInfo(CHAIN_ID);
        require(distributor == address(this), InvalidShutdownDistributor(CHAIN_ID, address(this)));
        _upgradeToAndCall(
            DISTRIBUTOR_IMPLEMENTATION,
            abi.encodeCall(IShutdownClaimDistributor.initialize, (_merkleRoot, _windowStart, _distributorOwner)),
            false
        );
    }
}
