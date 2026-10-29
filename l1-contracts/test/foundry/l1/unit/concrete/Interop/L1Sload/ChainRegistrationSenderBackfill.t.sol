// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ChainRegistrationSender} from "contracts/core/chain-registration/ChainRegistrationSender.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IProxyUpgradeInitializable} from "contracts/upgrades/registry/IUpgradeInit.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

import {L1SloadSharedTest} from "./_L1Sload_Shared.t.sol";

/// @notice `ChainRegistrationSender.initializeUpgrade`, the v36 backfill of base token snapshots for chains that v35
/// admins could have allowed. See {protocol-docs/l1sload.md#upgrade-from-v35}.
/// @dev Pairs allowed under v35 have no snapshot. Chains with interop enabled and no allowance yet are in the same
/// state, so they stand in for them.
contract ChainRegistrationSenderBackfillTest is L1SloadSharedTest {
    uint256 internal constant NOT_ENABLED_CHAIN_ID = 274;

    address internal proxyAdmin;
    address internal implementation;

    function setUp() public override {
        super.setUp();
        proxyAdmin = makeAddr("proxyAdmin");
        implementation = address(new ChainRegistrationSender(IBridgehubBase(bridgehub)));
        _registerChain(NOT_ENABLED_CHAIN_ID);
        uint256[] memory chainIds = new uint256[](4);
        chainIds[0] = CHAIN_ID;
        chainIds[1] = PEER_CHAIN_ID;
        chainIds[2] = THIRD_CHAIN_ID;
        chainIds[3] = NOT_ENABLED_CHAIN_ID;
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.getAllZKChainChainIDs, ()), abi.encode(chainIds));

        _enableInterop(CHAIN_ID);
        _enableInterop(PEER_CHAIN_ID);
        _enableInterop(THIRD_CHAIN_ID);
        _allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
    }

    function test_backfillsInteropChains() public {
        // The existing snapshot is kept, not re-read.
        vm.expectCall(bridgehub, abi.encodeCall(IBridgehubBase.baseTokenAssetId, (PEER_CHAIN_ID)), 0);
        _upgrade();

        assertEq(chainRegistrationSender.interopBaseTokenAssetId(CHAIN_ID), _baseTokenAssetId(CHAIN_ID));
        assertEq(chainRegistrationSender.interopBaseTokenAssetId(PEER_CHAIN_ID), _baseTokenAssetId(PEER_CHAIN_ID));
        assertEq(chainRegistrationSender.interopBaseTokenAssetId(THIRD_CHAIN_ID), _baseTokenAssetId(THIRD_CHAIN_ID));
        assertEq(chainRegistrationSender.interopBaseTokenAssetId(NOT_ENABLED_CHAIN_ID), bytes32(0));
        assertTrue(chainRegistrationSender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID));
        assertEq(chainRegistrationSender.owner(), governance);
    }

    function test_revertWhen_replayed() public {
        _upgrade();

        vm.prank(proxyAdmin);
        vm.expectRevert("Initializable: contract is already initialized");
        ITransparentUpgradeableProxy(address(chainRegistrationSender)).upgradeToAndCall(
            implementation,
            abi.encodeCall(IProxyUpgradeInitializable.initializeUpgrade, ())
        );
    }

    function test_revertWhen_notProxyAdmin() public {
        vm.prank(proxyAdmin);
        ITransparentUpgradeableProxy(address(chainRegistrationSender)).upgradeTo(implementation);

        address caller = makeAddr("caller");
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, caller));
        IProxyUpgradeInitializable(address(chainRegistrationSender)).initializeUpgrade();
    }

    function _upgrade() internal {
        vm.prank(proxyAdmin);
        ITransparentUpgradeableProxy(address(chainRegistrationSender)).upgradeToAndCall(
            implementation,
            abi.encodeCall(IProxyUpgradeInitializable.initializeUpgrade, ())
        );
    }
}
