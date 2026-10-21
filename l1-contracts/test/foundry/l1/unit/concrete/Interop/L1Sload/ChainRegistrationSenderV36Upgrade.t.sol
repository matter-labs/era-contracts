// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ChainRegistrationSender} from "contracts/core/chain-registration/ChainRegistrationSender.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IProxyUpgradeInitializable} from "contracts/upgrades/registry/IUpgradeInit.sol";
import {L1View} from "contracts/common/l2-helpers/L1View.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

import {L1ReadsHarness} from "./L1Reads.t.sol";
import {L1SloadSharedTest} from "./_L1Sload_Shared.t.sol";

/// @notice The v35 -> v36 swap of the `ChainRegistrationSender` implementation, starting from the real v35 build
/// (`fixtures/v35/ChainRegistrationSender.json`): pairs that v35 admins allowed keep working once the L2 reads L1,
/// because the swap's `initializeUpgrade` backfills the base token snapshots v35 never wrote.
/// See {protocol-docs/l1sload.md#upgrade-from-v35}.
/// @dev The proxy admin is an EOA here; in an upgrade the Core-domain `ProxyUpgradeTransition` row calls
/// `upgradeAndCall` with `initializeUpgrade` (`CoreUpgrade_v36._coreProxyUpgradeRows`). v35 also pushed each
/// allowance to the chain's L2 Bridgehub as a service transaction; the diamonds are mocked to accept it, since the
/// push is what v36 retires.
contract ChainRegistrationSenderV36UpgradeTest is L1SloadSharedTest {
    string internal constant V35_IMPLEMENTATION =
        "test/foundry/l1/integration/fixtures/v35/ChainRegistrationSender.json";
    /// @dev An interop-enabled chain nobody allowed: the migration snapshots it too.
    uint256 internal constant NOT_ENABLED_CHAIN_ID = 274;

    address internal proxyAdmin;
    L1ReadsHarness internal reads;

    function _chainRegistrationSenderImplementation() internal override returns (address) {
        return deployCode(V35_IMPLEMENTATION, abi.encode(IBridgehubBase(bridgehub)));
    }

    function setUp() public override {
        super.setUp();
        proxyAdmin = makeAddr("proxyAdmin");
        reads = new L1ReadsHarness();
        _registerChain(NOT_ENABLED_CHAIN_ID);
        uint256[] memory chainIds = new uint256[](4);
        chainIds[0] = CHAIN_ID;
        chainIds[1] = PEER_CHAIN_ID;
        chainIds[2] = THIRD_CHAIN_ID;
        chainIds[3] = NOT_ENABLED_CHAIN_ID;
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.getAllZKChainChainIDs, ()), abi.encode(chainIds));
        for (uint256 i = 0; i < chainIds.length; ++i) {
            vm.mockCall(
                makeAddr(string.concat("diamond", vm.toString(chainIds[i]))),
                abi.encodeWithSelector(IMailbox.requestL2ServiceTransaction.selector),
                abi.encode(bytes32(0))
            );
        }

        // The v35 state: CHAIN_ID and PEER_CHAIN_ID allowed each other, CHAIN_ID also allowed THIRD_CHAIN_ID.
        _enableInterop(CHAIN_ID);
        _enableInterop(PEER_CHAIN_ID);
        _enableInterop(THIRD_CHAIN_ID);
        _allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        _allowInteropPeer(PEER_CHAIN_ID, CHAIN_ID);
        _allowInteropPeer(CHAIN_ID, THIRD_CHAIN_ID);
    }

    /// @dev v35 kept no snapshot: an L2 reading v35 state finds no base token for its peers, so its sends would fail.
    function test_v35StateHasNoSnapshots() public view {
        assertTrue(chainRegistrationSender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID));
        assertEq(_snapshot(PEER_CHAIN_ID), bytes32(0));
        assertEq(_snapshot(CHAIN_ID), bytes32(0));
        assertEq(_snapshot(THIRD_CHAIN_ID), bytes32(0));
    }

    function test_upgradeBackfillsTheSnapshotsOfInteropChains() public {
        _upgradeToV36();

        assertEq(chainRegistrationSender.interopBaseTokenAssetId(CHAIN_ID), _baseTokenAssetId(CHAIN_ID));
        assertEq(chainRegistrationSender.interopBaseTokenAssetId(PEER_CHAIN_ID), _baseTokenAssetId(PEER_CHAIN_ID));
        assertEq(chainRegistrationSender.interopBaseTokenAssetId(THIRD_CHAIN_ID), _baseTokenAssetId(THIRD_CHAIN_ID));
        assertEq(
            chainRegistrationSender.interopBaseTokenAssetId(NOT_ENABLED_CHAIN_ID),
            bytes32(0),
            "no v35 admin could have allowed a chain without interop"
        );
        // The whitelist and the owner survive the swap.
        assertTrue(chainRegistrationSender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID));
        assertTrue(chainRegistrationSender.interopPeerAllowed(PEER_CHAIN_ID, CHAIN_ID));
        assertTrue(chainRegistrationSender.interopPeerAllowed(CHAIN_ID, THIRD_CHAIN_ID));
        assertFalse(chainRegistrationSender.interopPeerAllowed(THIRD_CHAIN_ID, CHAIN_ID));
        assertEq(chainRegistrationSender.owner(), governance);
    }

    /// @dev What the L2 reads at its first anchor after the upgrade: the pairs allowed under v35 keep working.
    function test_pairsAllowedUnderV35KeepWorkingOnL2() public {
        _upgradeToV36();
        _importL1Anchor(1, keccak256("first anchor after the upgrade"), block.timestamp);

        (bool allowed, bytes32 peerBaseTokenAssetId) = reads.sendTarget(
            address(chainRegistrationSender),
            CHAIN_ID,
            PEER_CHAIN_ID
        );
        assertTrue(allowed);
        assertEq(peerBaseTokenAssetId, _baseTokenAssetId(PEER_CHAIN_ID));
        assertTrue(reads.isReceiveAllowed(address(chainRegistrationSender), PEER_CHAIN_ID, CHAIN_ID));

        (allowed, peerBaseTokenAssetId) = reads.sendTarget(address(chainRegistrationSender), CHAIN_ID, THIRD_CHAIN_ID);
        assertFalse(allowed, "THIRD_CHAIN_ID never allowed CHAIN_ID");
        assertEq(peerBaseTokenAssetId, _baseTokenAssetId(THIRD_CHAIN_ID));
        assertTrue(reads.isReceiveAllowed(address(chainRegistrationSender), CHAIN_ID, THIRD_CHAIN_ID));
    }

    /// @dev v36 entry points work on the upgraded proxy: a new allowance and a suspension.
    function test_upgradedProxyServesV36() public {
        _upgradeToV36();
        _importL1Anchor(1, keccak256("first anchor after the upgrade"), block.timestamp);

        _allowInteropPeer(THIRD_CHAIN_ID, CHAIN_ID);
        (bool allowed, ) = reads.sendTarget(address(chainRegistrationSender), CHAIN_ID, THIRD_CHAIN_ID);
        assertTrue(allowed);

        _suspendInterop(PEER_CHAIN_ID);
        (allowed, ) = reads.sendTarget(address(chainRegistrationSender), CHAIN_ID, PEER_CHAIN_ID);
        assertFalse(allowed);
    }

    /// @dev `reinitializer(2)`: the backfill runs once.
    function test_revertWhen_backfillReplayed() public {
        _upgradeToV36();
        address implementation = _v36Implementation();

        vm.prank(proxyAdmin);
        vm.expectRevert("Initializable: contract is already initialized");
        ITransparentUpgradeableProxy(address(chainRegistrationSender)).upgradeToAndCall(
            implementation,
            abi.encodeCall(IProxyUpgradeInitializable.initializeUpgrade, ())
        );
    }

    /// @dev Only through the proxy admin's `upgradeToAndCall`.
    function test_revertWhen_backfillNotCalledByTheProxyAdmin() public {
        address implementation = _v36Implementation();
        vm.prank(proxyAdmin);
        ITransparentUpgradeableProxy(address(chainRegistrationSender)).upgradeTo(implementation);

        address caller = makeAddr("caller");
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, caller));
        IProxyUpgradeInitializable(address(chainRegistrationSender)).initializeUpgrade();
        assertEq(chainRegistrationSender.interopBaseTokenAssetId(PEER_CHAIN_ID), bytes32(0));
    }

    function _upgradeToV36() internal {
        address implementation = _v36Implementation();
        vm.prank(proxyAdmin);
        ITransparentUpgradeableProxy(address(chainRegistrationSender)).upgradeToAndCall(
            implementation,
            abi.encodeCall(IProxyUpgradeInitializable.initializeUpgrade, ())
        );
    }

    function _v36Implementation() internal returns (address) {
        return address(new ChainRegistrationSender(IBridgehubBase(bridgehub)));
    }

    /// @dev Read raw: the v35 implementation has no getter for the slot.
    function _snapshot(uint256 _chainId) internal view returns (bytes32) {
        return vm.load(address(chainRegistrationSender), L1View.interopBaseTokenAssetIdSlot(_chainId));
    }
}

/// @notice The backfill on a proxy that already runs v36: it keeps every existing snapshot and writes the missing
/// ones, as when a fresh v36 ecosystem's `ChainRegistrationSender` is swapped with reinitialization.
contract ChainRegistrationSenderBackfillOnV36Test is L1SloadSharedTest {
    function test_backfillKeepsExistingSnapshots() public {
        uint256[] memory chainIds = new uint256[](3);
        chainIds[0] = CHAIN_ID;
        chainIds[1] = PEER_CHAIN_ID;
        chainIds[2] = THIRD_CHAIN_ID;
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.getAllZKChainChainIDs, ()), abi.encode(chainIds));
        _allowBothWays(CHAIN_ID, PEER_CHAIN_ID);
        _enableInterop(THIRD_CHAIN_ID);
        // The Bridgehub would never change a base token; this only shows the backfill doesn't overwrite.
        vm.mockCall(
            bridgehub,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (PEER_CHAIN_ID)),
            abi.encode(keccak256("another base token"))
        );

        address implementation = address(new ChainRegistrationSender(IBridgehubBase(bridgehub)));
        vm.prank(makeAddr("proxyAdmin"));
        ITransparentUpgradeableProxy(address(chainRegistrationSender)).upgradeToAndCall(
            implementation,
            abi.encodeCall(IProxyUpgradeInitializable.initializeUpgrade, ())
        );

        assertEq(chainRegistrationSender.interopBaseTokenAssetId(PEER_CHAIN_ID), _baseTokenAssetId(PEER_CHAIN_ID));
        assertEq(chainRegistrationSender.interopBaseTokenAssetId(CHAIN_ID), _baseTokenAssetId(CHAIN_ID));
        assertEq(chainRegistrationSender.interopBaseTokenAssetId(THIRD_CHAIN_ID), _baseTokenAssetId(THIRD_CHAIN_ID));
    }
}
