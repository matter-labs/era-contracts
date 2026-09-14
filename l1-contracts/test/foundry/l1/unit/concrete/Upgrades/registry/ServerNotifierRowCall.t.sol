// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {CTMUpgradeExecutorFixture} from "./CTMUpgradeExecutor.t.sol";
import {DefaultCTMUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {RegistryBootstrapMigration} from "contracts/upgrades/registry/bootstrap/RegistryBootstrapMigration.sol";
import {ProxyUpgradeRowLib} from "contracts/upgrades/registry/libraries/ProxyUpgradeRowLib.sol";
import {IProxyUpgradeInitializable} from "contracts/upgrades/registry/IUpgradeInit.sol";
import {MockProxyUpgradeInitImpl} from "contracts/dev-contracts/test/MockProxyUpgradeInitImpl.sol";
import {CTMContract, CTM_CONTRACT_COUNT} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {
    AuthoredL2Plan,
    BootstrapManifest,
    PinnedContract,
    ProxyUpgradeRow,
    TransitionManifest
} from "contracts/upgrades/registry/RegistryTypes.sol";

/// @dev Exposes the prepare's row source and the two live inputs the admin-call rendering reads.
///      Nothing else of the pipeline runs: the rendering depends only on the deployed upgrade
///      object and the live notifier proxy.
contract ServerNotifierRowCallHarness is DefaultCTMUpgrade {
    address internal migration;

    function setCTMTransition(address _transition) external {
        upgradeAddresses.ctmTransition = _transition;
    }

    function setBootstrapMigration(address _migration) external {
        migration = _migration;
    }

    function setServerNotifierProxy(address _proxy) external {
        ctmAddresses.stateTransition.proxies.serverNotifier = _proxy;
    }

    function setOutputPath(string memory _path) external {
        upgradeConfig.outputPath = _path;
    }

    function bootstrapMigrationAddress() public view override returns (address) {
        return migration;
    }
}

/// @dev Applies rows through the production library while OWNING the row's admin, so a test can
///      observe the exact `ProxyAdmin` call `applyRows` makes for a row.
contract RowApplier {
    function applyRows(ProxyAdmin _admin, ProxyUpgradeRow[] memory _rows) external {
        ProxyUpgradeRowLib.applyRows(_admin, _rows);
    }
}

contract NotifierImplV1 {
    function version() external pure returns (uint256) {
        return 1;
    }
}

contract NotifierImplV2 {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev Stands in for the ChainAdmin that owns the notifier's ProxyAdmin: an `Ownable` whose
///      owner the admin-calls section records.
contract ChainAdminStub is Ownable {}

/// @notice The ServerNotifier's implementation swap is emitted as the ChainAdmin's own call
///         (section 4.4 of {docs/upgrade-stage-lifecycle.md}). That call is RENDERED from the
///         `CTMContract.ServerNotifier` row the upgrade object pins — the transition on a
///         recurring edge, the bootstrap migration on the bootstrap edge — and is byte-identical
///         to the `ProxyAdmin` call `ProxyUpgradeRowLib.applyRows` makes for the same row, so the
///         administrator executes exactly the swap governance reviewed.
contract ServerNotifierRowCallTest is CTMUpgradeExecutorFixture {
    using stdToml for string;

    ServerNotifierRowCallHarness internal harness;
    address internal implOld;
    address internal implNew;
    ChainAdminStub internal chainAdmin;
    ProxyAdmin internal notifierAdmin;
    TransparentUpgradeableProxy internal notifierProxy;

    function setUp() public override {
        super.setUp();
        harness = new ServerNotifierRowCallHarness();
        implOld = address(new NotifierImplV1());
        implNew = address(new NotifierImplV2());
        // The notifier's own admin, owned by the chain admin rather than by the CTM executor.
        chainAdmin = new ChainAdminStub();
        notifierAdmin = new ProxyAdmin();
        notifierAdmin.transferOwnership(address(chainAdmin));
        notifierProxy = new TransparentUpgradeableProxy(implOld, address(notifierAdmin), hex"");
        harness.setServerNotifierProxy(address(notifierProxy));
    }

    // ─────────────────────────────── happy path ───────────────────────────────

    function test_plainRowRendersTheApplyRowsUpgradeCall() public {
        ProxyUpgradeRow memory row = _notifierRow(implNew, false, notifierAdmin);
        harness.setCTMTransition(address(_transitionWith(row)));

        Call[] memory calls = harness.prepareUpgradeServerNotifierCall();
        assertEq(calls.length, 1, "one admin call");
        assertEq(calls[0].target, address(notifierAdmin), "the row's own administrator is the target");
        assertEq(calls[0].value, 0, "no value");
        assertEq(
            calls[0].data,
            abi.encodeCall(ProxyAdmin.upgrade, (ITransparentUpgradeableProxy(address(notifierProxy)), implNew)),
            "a non-reinitializing row is a plain upgrade"
        );
        _assertSameCallAsApplyRows(row, calls[0]);

        _executeAsChainAdmin(calls[0]);
        assertEq(_liveImpl(), implNew, "the administrator's call moves the proxy to the pinned implementation");
    }

    function test_reinitializingRowRendersUpgradeAndCall() public {
        address reinitImpl = address(new MockProxyUpgradeInitImpl());
        ProxyUpgradeRow memory row = _notifierRow(reinitImpl, true, notifierAdmin);
        harness.setCTMTransition(address(_transitionWith(row)));

        Call[] memory calls = harness.prepareUpgradeServerNotifierCall();
        assertEq(calls.length, 1, "one admin call");
        assertEq(calls[0].target, address(notifierAdmin), "the row's own administrator is the target");
        assertEq(
            calls[0].data,
            abi.encodeCall(
                ProxyAdmin.upgradeAndCall,
                (
                    ITransparentUpgradeableProxy(address(notifierProxy)),
                    reinitImpl,
                    abi.encodeCall(IProxyUpgradeInitializable.initializeUpgrade, ())
                )
            ),
            "a reinitializing row is upgradeAndCall with the fixed argument-less reinitializer"
        );
        _assertSameCallAsApplyRows(row, calls[0]);

        _executeAsChainAdmin(calls[0]);
        assertEq(_liveImpl(), reinitImpl, "the proxy moves to the pinned implementation");
        assertEq(
            MockProxyUpgradeInitImpl(address(notifierProxy)).initializeUpgradeCalls(),
            1,
            "the reinitializer runs exactly once, atomically with the swap"
        );
    }

    /// @dev The bootstrap edge deploys no transition; its rows are read off the migration.
    function test_bootstrapEdgeRendersTheMigrationsRow() public {
        ProxyUpgradeRow memory row = _notifierRow(implNew, false, notifierAdmin);
        harness.setBootstrapMigration(address(_migrationWith(row)));

        Call[] memory calls = harness.prepareUpgradeServerNotifierCall();
        assertEq(calls.length, 1, "one admin call");
        assertEq(calls[0].target, address(notifierAdmin), "the row's own administrator is the target");
        assertEq(
            calls[0].data,
            abi.encodeCall(ProxyAdmin.upgrade, (ITransparentUpgradeableProxy(address(notifierProxy)), implNew)),
            "rendered from the migration's row"
        );
    }

    function test_inertNotifierSlotRendersNoCall() public {
        // The fixture's default transition leaves every CTM-domain slot inert.
        harness.setCTMTransition(address(transition));
        assertEq(harness.prepareUpgradeServerNotifierCall().length, 0, "nothing to emit");
    }

    // ─────────────────────────────── the admin-calls section ───────────────────────────────

    function test_adminCallsSectionRecordsTheRowAndItsAdministrator() public {
        ProxyUpgradeRow memory row = _notifierRow(implNew, false, notifierAdmin);
        harness.setCTMTransition(address(_transitionWith(row)));
        string memory outputPath = _outputPath("with-row");
        harness.setOutputPath(outputPath);

        Call[] memory calls = harness.prepareDefaultCTMAdminCalls();
        assertEq(calls.length, 1, "the section carries the rendered call");
        assertEq(harness.externalActionDescriptions().length, 1, "the swap is declared as an external action");

        string memory toml = vm.readFile(outputPath);
        assertEq(toml.readAddress("$.ctm_admin_calls.chain_admin"), address(chainAdmin), "the row's administrator");
        assertEq(toml.readAddress("$.ctm_admin_calls.chain_admin_owner"), address(this), "and its owner");
        Call[] memory written = abi.decode(toml.readBytes("$.ctm_admin_calls.server_notifier_upgrade"), (Call[]));
        assertEq(written.length, 1, "one written call");
        assertEq(written[0].target, calls[0].target, "written target");
        assertEq(written[0].data, calls[0].data, "written calldata");
    }

    function test_adminCallsSectionIsWrittenWithoutARow() public {
        harness.setCTMTransition(address(transition));
        string memory outputPath = _outputPath("without-row");
        harness.setOutputPath(outputPath);

        Call[] memory calls = harness.prepareDefaultCTMAdminCalls();
        assertEq(calls.length, 0, "no call");
        assertEq(harness.externalActionDescriptions().length, 0, "no declared action");

        string memory toml = vm.readFile(outputPath);
        assertEq(
            toml.readAddress("$.ctm_admin_calls.chain_admin"),
            address(chainAdmin),
            "the section is still written"
        );
        Call[] memory written = abi.decode(toml.readBytes("$.ctm_admin_calls.server_notifier_upgrade"), (Call[]));
        assertEq(written.length, 0, "an empty call list");
    }

    // ─────────────────────────────── unhappy paths ───────────────────────────────

    function test_revertWhen_noUpgradeObjectIsDeployed() public {
        vm.expectRevert(bytes("no upgrade object deployed: the CTM-domain rows are read from it"));
        harness.prepareUpgradeServerNotifierCall();
    }

    function test_revertWhen_rowNamesNoAdministrator() public {
        harness.setCTMTransition(address(_transitionWith(_notifierRow(implNew, false, ProxyAdmin(address(0))))));
        vm.expectRevert(bytes("the pinned ServerNotifier row names no administrator"));
        harness.prepareUpgradeServerNotifierCall();
    }

    /// @dev The section records the LIVE administrator's approval; a row naming another one would
    ///      emit a call that administrator cannot make.
    function test_revertWhen_rowAdministratorIsNotTheLiveProxysAdmin() public {
        ProxyAdmin otherAdmin = new ProxyAdmin();
        harness.setCTMTransition(address(_transitionWith(_notifierRow(implNew, false, otherAdmin))));
        harness.setOutputPath(_outputPath("other-admin"));

        vm.expectRevert(bytes("the pinned ServerNotifier row names an administrator other than the live proxy's"));
        harness.prepareDefaultCTMAdminCalls();
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    function _notifierRow(
        address _implNew,
        bool _callInitializeUpgrade,
        ProxyAdmin _admin
    ) internal view returns (ProxyUpgradeRow memory) {
        return
            ProxyUpgradeRow({
                proxy: address(notifierProxy),
                expectedOldImpl: implOld,
                implNew: _pin(_implNew),
                callInitializeUpgrade: _callInitializeUpgrade,
                admin: _admin
            });
    }

    function _inventoryWith(ProxyUpgradeRow memory _row) internal pure returns (ProxyUpgradeRow[] memory inventory) {
        inventory = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        inventory[uint256(CTMContract.ServerNotifier)] = _row;
    }

    function _transitionWith(ProxyUpgradeRow memory _row) internal returns (CTMTransition) {
        TransitionManifest memory manifest = _transitionManifest(
            777,
            chainContractAddress.currentRelease(),
            0,
            L2_DELEGATE_CODE
        );
        manifest.proxyUpgrades = _inventoryWith(_row);
        return new CTMTransition(manifest);
    }

    /// @dev An L1-only bootstrap edge over the fixture's objects; the notifier row is its one
    ///      implementation swap.
    function _migrationWith(ProxyUpgradeRow memory _row) internal returns (RegistryBootstrapMigration) {
        return
            new RegistryBootstrapMigration(
                BootstrapManifest({
                    ctm: address(chainContractAddress),
                    expectedProtocolVersion: 0,
                    ctmProxyAdmin: ctmProxyAdmin,
                    proxyUpgrades: _inventoryWith(_row),
                    currentRelease: _pin(address(release)),
                    newProtocolVersion: newVersion,
                    oldProtocolVersionDeadline: 1000,
                    upgradeEngine: _pin(upgradeEngineAddr),
                    l2Plan: AuthoredL2Plan({
                        extraDeployments: new IComplexUpgrader.UniversalContractUpgradeInfo[](0),
                        delegateTo: address(0),
                        delegateComposer: PinnedContract({addr: address(0), codehash: bytes32(0)}),
                        factoryDepHashes: new uint256[](0)
                    }),
                    upgradeTimestamp: 0,
                    ctmExecutor: _pin(address(ctmExecutor)),
                    ctmExecutorOwner: governor,
                    ecosystemExecutor: address(ecosystemExecutor),
                    upgradeTimer: _pin(address(_newTimer(0, 0)))
                })
            );
    }

    function _outputPath(string memory _tag) internal returns (string memory) {
        string memory dir = string.concat(vm.projectRoot(), "/script-out");
        vm.createDir(dir, true);
        return string.concat(dir, "/server-notifier-row-call-", _tag, ".toml");
    }

    function _liveImpl() internal view returns (address) {
        return notifierAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(notifierProxy)));
    }

    function _executeAsChainAdmin(Call memory _call) internal {
        vm.prank(address(chainAdmin));
        (bool success, ) = _call.target.call{value: _call.value}(_call.data);
        assertTrue(success, "the administrator's call must succeed");
    }

    /// @dev Hands the row's admin to a `RowApplier` and applies the row through the production
    ///      library, expecting exactly the rendered call on the admin — then restores the state so
    ///      the caller can execute the rendered call itself.
    function _assertSameCallAsApplyRows(ProxyUpgradeRow memory _row, Call memory _rendered) internal {
        uint256 snapshot = vm.snapshotState();
        RowApplier applier = new RowApplier();
        vm.prank(address(chainAdmin));
        notifierAdmin.transferOwnership(address(applier));

        ProxyUpgradeRow[] memory rows = new ProxyUpgradeRow[](1);
        rows[0] = _row;
        vm.expectCall(_rendered.target, _rendered.value, _rendered.data);
        applier.applyRows(ctmProxyAdmin, rows);
        assertEq(_liveImpl(), _row.implNew.addr, "applyRows moved the proxy through the same call");
        assertTrue(vm.revertToState(snapshot), "restore the pre-apply state");
    }
}
