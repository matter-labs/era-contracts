// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ChainRegistrationSender} from "contracts/core/chain-registration/ChainRegistrationSender.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {L1SloadNotEnabled} from "contracts/core/bridgehub/L1BridgehubErrors.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {IProxyUpgradeInitializable} from "contracts/upgrades/registry/IUpgradeInit.sol";
import {L1View} from "contracts/common/l2-helpers/L1View.sol";
import {PubdataContent, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT} from "contracts/common/Config.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

import {Utils} from "../../Utils/Utils.sol";
import {L1ReadsHarness} from "./L1Reads.t.sol";
import {L1SloadSharedTest} from "./_L1Sload_Shared.t.sol";

/// @dev A chain's diamond in these tests: the v36 engine's L1SLOAD step (`DefaultUpgrade._enableL1SloadForInterop`)
/// running in the chain's own storage, and the getters the L1 contracts read from the chain. The full engine path,
/// `upgradeFromTransition`, is covered by `DefaultUpgrade.t.sol`.
contract V36ChainUpgradeHarness is DefaultUpgrade {
    function initChain(address _bridgehub, uint256 _chainId, address _admin) external {
        s.bridgehub = _bridgehub;
        s.chainId = _chainId;
        s.admin = _admin;
    }

    function enableL1SloadForInterop() external {
        _enableL1SloadForInterop();
    }

    function getAdmin() external view returns (address) {
        return s.admin;
    }

    function isZKsyncOSL1SloadEnabled() external view returns (bool) {
        return s.zksyncOSL1SloadEnabled;
    }

    /// @dev The loupe `enableInterop` asks: this chain routes every getter it has.
    function facetAddress(bytes4) external view returns (address) {
        return address(this);
    }

    function getZKsyncOSChainConfigHash() external view returns (bytes32) {
        return _getZKsyncOSChainConfigHash();
    }
}

/// @notice The v35 -> v36 upgrade of interop chains, starting from the real v35 `L1MessageRoot` and
/// `ChainRegistrationSender` builds (`fixtures/v35/`): interop was enabled with L1SLOAD off, and the pairs v35 admins
/// allowed have no base token snapshot. The ecosystem leg swaps both implementations, and the
/// `ChainRegistrationSender`'s `initializeUpgrade` backfills the snapshots; each chain's own upgrade then turns L1SLOAD
/// on if its interop is enabled. Once the L2 imports an anchor, the v35 pairs keep working.
/// See {protocol-docs/l1sload.md#upgrade-from-v35}.
/// @dev The proxy admin is an EOA here; in an upgrade the Core-domain `ProxyUpgradeTransition` rows swap the
/// implementations (`CoreUpgrade_v36._coreProxyUpgradeRows`). v35 also pushed each allowance to the chain's L2 Bridgehub
/// as a service transaction; the diamonds are mocked to accept it, since the push is what v36 retires. Foundry has no
/// L1SLOAD precompile, so the mock one serves the L2 reads whatever the chain's flag ({L1SloadMockUtils}).
contract ChainRegistrationSenderV36UpgradeTest is L1SloadSharedTest {
    string internal constant V35_IMPLEMENTATION =
        "test/foundry/l1/integration/fixtures/v35/ChainRegistrationSender.json";
    string internal constant V35_MESSAGE_ROOT = "test/foundry/l1/integration/fixtures/v35/L1MessageRoot.json";
    /// @dev A chain without interop: the upgrade gives it neither a snapshot nor L1SLOAD.
    uint256 internal constant NOT_ENABLED_CHAIN_ID = 274;

    address internal proxyAdmin;
    L1ReadsHarness internal reads;

    function _chainRegistrationSenderImplementation() internal override returns (address) {
        return deployCode(V35_IMPLEMENTATION, abi.encode(IBridgehubBase(bridgehub)));
    }

    function _l1MessageRootImplementation(address _chainAssetHandler) internal override returns (address) {
        return deployCode(V35_MESSAGE_ROOT, abi.encode(bridgehub, _chainAssetHandler));
    }

    function _installChain(uint256 _chainId, address _diamond) internal override {
        vm.etch(_diamond, address(new V36ChainUpgradeHarness()).code);
        V36ChainUpgradeHarness(_diamond).initChain(bridgehub, _chainId, _chainAdmin(_chainId));
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

    /// @dev The state the chain upgrade repairs: v35 enabled interop without L1SLOAD.
    function test_v35StateHasInteropOnAndL1SloadOff() public {
        assertTrue(l1MessageRoot.isInteropEnabled(CHAIN_ID));
        assertFalse(_chain(CHAIN_ID).isZKsyncOSL1SloadEnabled());
        assertEq(_chain(CHAIN_ID).getZKsyncOSChainConfigHash(), _chainConfigHash(CHAIN_ID, false));
    }

    /// @dev Each chain's upgrade turns L1SLOAD on when its interop is enabled, with the Admin setter's event, and the
    /// chain config hash its next batch commits carries it. A chain without interop keeps it off, and from v36 it can't
    /// get interop without it.
    function test_chainUpgradeTurnsL1SloadOnForInteropChains() public {
        _upgradeEcosystemToV36();
        assertTrue(l1MessageRoot.isInteropEnabled(CHAIN_ID), "the v35 state survives the swap");

        uint256[3] memory interopChains = [CHAIN_ID, PEER_CHAIN_ID, THIRD_CHAIN_ID];
        for (uint256 i = 0; i < interopChains.length; ++i) {
            V36ChainUpgradeHarness chain = _chain(interopChains[i]);
            vm.expectEmit(address(chain));
            emit IAdmin.NewZKsyncOSL1Sload(false, true);
            chain.enableL1SloadForInterop();
            assertTrue(chain.isZKsyncOSL1SloadEnabled());
            assertEq(chain.getZKsyncOSChainConfigHash(), _chainConfigHash(interopChains[i], true));
        }

        V36ChainUpgradeHarness other = _chain(NOT_ENABLED_CHAIN_ID);
        vm.recordLogs();
        other.enableL1SloadForInterop();
        assertEq(vm.getRecordedLogs().length, 0, "no event");
        assertFalse(other.isZKsyncOSL1SloadEnabled());
        assertEq(other.getZKsyncOSChainConfigHash(), _chainConfigHash(NOT_ENABLED_CHAIN_ID, false));

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(L1SloadNotEnabled.selector, NOT_ENABLED_CHAIN_ID));
        l1MessageRoot.enableInterop(NOT_ENABLED_CHAIN_ID, false);
    }

    /// @dev Every later transition finds the flag on and does nothing.
    function test_chainUpgradeIsANoopOnceL1SloadIsOn() public {
        _upgradeToV36();

        vm.recordLogs();
        _chain(CHAIN_ID).enableL1SloadForInterop();
        assertEq(vm.getRecordedLogs().length, 0, "no event");
        assertTrue(_chain(CHAIN_ID).isZKsyncOSL1SloadEnabled());
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
        assertTrue(_chain(CHAIN_ID).isZKsyncOSL1SloadEnabled());
        assertTrue(_chain(PEER_CHAIN_ID).isZKsyncOSL1SloadEnabled());
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

    /// @dev The ecosystem leg, then every chain's own upgrade.
    function _upgradeToV36() internal {
        _upgradeEcosystemToV36();
        uint256[4] memory chainIds = [CHAIN_ID, PEER_CHAIN_ID, THIRD_CHAIN_ID, NOT_ENABLED_CHAIN_ID];
        for (uint256 i = 0; i < chainIds.length; ++i) {
            _chain(chainIds[i]).enableL1SloadForInterop();
        }
    }

    /// @dev The two implementation swaps, the `ChainRegistrationSender` one with its backfill.
    function _upgradeEcosystemToV36() internal {
        address messageRootImplementation = address(new L1MessageRoot(bridgehub, makeAddr("chainAssetHandler")));
        address implementation = _v36Implementation();
        vm.startPrank(proxyAdmin);
        ITransparentUpgradeableProxy(address(l1MessageRoot)).upgradeTo(messageRootImplementation);
        ITransparentUpgradeableProxy(address(chainRegistrationSender)).upgradeToAndCall(
            implementation,
            abi.encodeCall(IProxyUpgradeInitializable.initializeUpgrade, ())
        );
        vm.stopPrank();
    }

    function _chain(uint256 _chainId) internal returns (V36ChainUpgradeHarness) {
        return V36ChainUpgradeHarness(makeAddr(string.concat("diamond", vm.toString(_chainId))));
    }

    /// @dev The chain config hash of a fixture chain: default gas limit, full pubdata, only L1SLOAD may be on.
    function _chainConfigHash(uint256 _chainId, bool _l1SloadEnabled) internal pure returns (bytes32) {
        return
            Utils.chainConfigHash({
                _chainId: _chainId,
                _maxTxGasLimit: ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT,
                _pubdataContent: PubdataContent.FULL_PUBDATA,
                _filteringEnabled: false,
                _largeContractsEnabled: false,
                _l1SloadEnabled: _l1SloadEnabled
            });
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
