// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CTMDomainProxies} from "deploy-scripts/upgrade/v35/CTMDomainProxies.sol";
import {SplitCTMProxyAdmin} from "deploy-scripts/upgrade/v35/SplitCTMProxyAdmin.s.sol";
import {AddressIntrospector} from "deploy-scripts/utils/AddressIntrospector.sol";
import {Utils as DeployScriptUtils} from "deploy-scripts/utils/Utils.sol";
import {Call} from "contracts/governance/Common.sol";
import {StateTransitionContracts} from "contracts/common/StateTransitionTypes.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";

import {CTMUpgradeForLocalTest, UpgradeIntegrationTestLocal} from "./UpgradeTest_Local.t.sol";

/// @notice The v35 bootstrap over an ecosystem whose CTM still shares the ecosystem ProxyAdmin, as
///         zksync-os mainnet's and the ZKsync OS testnet's do: the CTM, its ValidatorTimelock,
///         BytecodesSupplier and PermissionlessValidator behind the Bridgehub's admin, the
///         ServerNotifier behind its own. `SplitCTMProxyAdmin` runs first and governance executes
///         the calls its output carries (in two goes, to cover a partial split); every assertion
///         of the regular bootstrap test then runs over the split layout.
contract UpgradeIntegrationTestLocalSplitCTMProxyAdmin is UpgradeIntegrationTestLocal {
    using stdToml for string;

    /// @dev The CTM-domain ProxyAdmin the split deployed.
    address internal splitAdmin;

    /// @dev The ecosystem (Bridgehub) ProxyAdmin.
    address internal ecosystemAdmin;

    /// @dev Whether the fixture also puts the ServerNotifier behind the ecosystem admin.
    function _shareTheNotifier() internal pure virtual returns (bool) {
        return false;
    }

    function _beforePrepare() internal override {
        address bridgehub = previousRelease.bridgehub;
        address ctm = previousRelease.chainTypeManager;
        ecosystemAdmin = DeployScriptUtils.getProxyAdminAddress(bridgehub);
        address ownAdmin = DeployScriptUtils.getProxyAdminAddress(ctm);
        StateTransitionContracts memory domain = AddressIntrospector.getCTMProxies(ChainTypeManager(ctm));
        assertTrue(domain.permissionlessValidator != address(0), "the fixture's CTM has a PermissionlessValidator");
        uint256 shared = _shareTheEcosystemAdmin(domain, ownAdmin);
        assertEq(shared, _shareTheNotifier() ? 5 : 4, "the CTM, its timelock, supplier, validator (and notifier)");

        SplitCTMProxyAdmin script = new SplitCTMProxyAdmin();
        vm.expectRevert(
            "CTM domain shares the ecosystem ProxyAdmin; run SplitCTMProxyAdmin and execute its calls first"
        );
        script.requireSplit(bridgehub, ctm);

        // Outside `--broadcast` the admin would exist only in the simulation.
        string memory output = string.concat(vm.projectRoot(), "/script-out/split-ctm-proxy-admin-test.toml");
        vm.expectRevert("dry run: the CTM-domain ProxyAdmin would not be deployed on chain; rerun with --broadcast");
        script.run(bridgehub, ctm, output);

        SplitCTMProxyAdmin.Split memory split = script.prepare(bridgehub, ctm);
        assertEq(split.proxies.length, shared, "every CTM-domain proxy behind the ecosystem admin moves");
        assertEq(split.proxies[0], ctm, "the CTM moves first");
        assertEq(split.proxies[3], domain.permissionlessValidator, "the PermissionlessValidator moves too");
        assertEq(split.governance, ProxyAdmin(ecosystemAdmin).owner(), "governance owns the ecosystem admin");
        assertTrue(split.ctmProxyAdmin != ecosystemAdmin, "a new admin, not the ecosystem's");
        assertTrue(split.ctmProxyAdmin != ownAdmin, "a new admin, not the one the fixture emptied");
        script.requireReady(bridgehub, ctm, split.ctmProxyAdmin);

        // What governance executes is the output's `[governance_calls] calls`.
        script.write(split, output);
        Call[] memory calls = abi.decode(vm.readFile(output).readBytes(".governance_calls.calls"), (Call[]));
        vm.removeFile(output);
        assertEq(keccak256(abi.encode(calls)), keccak256(abi.encode(split.calls)), "the output carries the calls");

        // A partial split: the last proxy stays behind the ecosystem admin, which the split's check
        // and the prepare's (the same rule) refuse.
        (, string[] memory names) = CTMDomainProxies.list(domain);
        governanceMulticall(split.governance, _firstCalls(calls, calls.length - 1));
        vm.expectRevert(
            bytes(
                string.concat(
                    names[calls.length - 1],
                    " is still behind the ecosystem ProxyAdmin; run SplitCTMProxyAdmin and execute its calls first"
                )
            )
        );
        script.requireSplit(bridgehub, ctm);

        // Rerun from live state: the rest moves under the admin the CTM already has.
        SplitCTMProxyAdmin.Split memory rest = script.prepare(bridgehub, ctm);
        assertEq(rest.ctmProxyAdmin, split.ctmProxyAdmin, "the rest moves under the same admin");
        assertEq(rest.proxies.length, 1, "only the proxy left behind moves");
        assertEq(rest.proxies[0], split.proxies[calls.length - 1], "the one left behind");
        governanceMulticall(rest.governance, rest.calls);
        script.requireSplit(bridgehub, ctm);

        SplitCTMProxyAdmin.Split memory again = script.prepare(bridgehub, ctm);
        assertEq(again.calls.length, 0, "a split CTM yields no calls");
        assertEq(again.ctmProxyAdmin, split.ctmProxyAdmin, "and reports the admin it has");

        splitAdmin = split.ctmProxyAdmin;
    }

    /// @dev Moves every CTM-domain proxy the fixture deployed behind its own admin back behind the
    ///      ecosystem's: the layout an ecosystem deployed before the two-executor model has. The
    ///      ServerNotifier keeps an admin of its own, as on those ecosystems, unless
    ///      {_shareTheNotifier}.
    function _shareTheEcosystemAdmin(
        StateTransitionContracts memory _domain,
        address _ownAdmin
    ) private returns (uint256 moved) {
        (address[] memory proxies, ) = CTMDomainProxies.list(_domain);
        for (uint256 i = 0; i < proxies.length; ++i) {
            address admin = DeployScriptUtils.getProxyAdminAddress(proxies[i]);
            bool notifier = proxies[i] == _domain.serverNotifier;
            if (admin != _ownAdmin && !(notifier && _shareTheNotifier())) {
                continue;
            }
            vm.prank(ProxyAdmin(admin).owner());
            ProxyAdmin(admin).changeProxyAdmin(ITransparentUpgradeableProxy(payable(proxies[i])), ecosystemAdmin);
            ++moved;
        }
    }

    function _firstCalls(Call[] memory _calls, uint256 _count) private pure returns (Call[] memory first) {
        first = new Call[](_count);
        for (uint256 i = 0; i < _count; ++i) {
            first[i] = _calls[i];
        }
    }

    function test_bootstrapLandsTheSplitCTMDomainUnderTheCTMExecutor() public view {
        CTMUpgradeForLocalTest bootstrap = CTMUpgradeForLocalTest(address(ctmUpgrade));
        address ctm = ctmUpgrade.getCTMAddress();

        assertEq(
            ProxyAdmin(splitAdmin).owner(),
            address(bootstrap.ctmUpgradeExecutor()),
            "the split admin landed under the CTM executor"
        );
        // After the edge the domain includes the notifier (handed over) and the interop fee
        // manager (deployed by the prepare): all of it behind the split admin.
        (address[] memory proxies, string[] memory names) = CTMDomainProxies.list(
            AddressIntrospector.getCTMProxies(ChainTypeManager(ctm))
        );
        assertEq(proxies.length, 6, "the whole CTM domain");
        for (uint256 i = 0; i < proxies.length; ++i) {
            assertEq(
                DeployScriptUtils.getProxyAdminAddress(proxies[i]),
                splitAdmin,
                string.concat(names[i], " sits behind the split admin")
            );
        }
        assertEq(
            ProxyAdmin(ecosystemAdmin).owner(),
            bootstrap.bootstrapMigration().getManifest().coreExecutor,
            "the ecosystem admin landed under the core executor"
        );
    }

    /// @dev Moves the CTM's PermissionlessValidator from the split admin (the CTM executor's since
    ///      the bootstrap) to `_admin`.
    function _moveValidatorTo(address _admin) private {
        CTMUpgradeForLocalTest bootstrap = CTMUpgradeForLocalTest(address(ctmUpgrade));
        address validator = AddressIntrospector
            .getCTMProxies(ChainTypeManager(ctmUpgrade.getCTMAddress()))
            .permissionlessValidator;
        vm.prank(address(bootstrap.ctmUpgradeExecutor()));
        ProxyAdmin(splitAdmin).changeProxyAdmin(ITransparentUpgradeableProxy(payable(validator)), _admin);
    }

    function test_prepareRefusesAProxyLeftBehindTheEcosystemAdmin() public {
        _moveValidatorTo(ecosystemAdmin);
        vm.expectRevert(
            "PermissionlessValidator is still behind the ecosystem ProxyAdmin; run SplitCTMProxyAdmin and execute its calls first"
        );
        CTMUpgradeForLocalTest(address(ctmUpgrade)).deployRegistryBootstrap();
    }

    function test_prepareRefusesAProxyBehindAThirdPartyAdmin() public {
        _moveValidatorTo(address(new ProxyAdmin()));
        vm.expectRevert(
            "PermissionlessValidator is behind a ProxyAdmin that is neither the CTM-domain nor the ecosystem one"
        );
        CTMUpgradeForLocalTest(address(ctmUpgrade)).deployRegistryBootstrap();
    }

    /// @dev After the bootstrap the ecosystem admin is the core executor's, so governance can no
    ///      longer send a split's calls; and an admin the split would reuse must be governance's.
    function test_splitRefusesAfterTheBootstrapAndAnAdminGovernanceDoesNotOwn() public {
        address bridgehub = previousRelease.bridgehub;
        address ctm = ctmUpgrade.getCTMAddress();
        address coreExecutor = ProxyAdmin(ecosystemAdmin).owner();
        _moveValidatorTo(ecosystemAdmin);
        SplitCTMProxyAdmin script = new SplitCTMProxyAdmin();

        vm.expectRevert("the ecosystem ProxyAdmin is already the core executor's: split before the v35 bootstrap");
        script.prepare(bridgehub, ctm);

        // Were the ecosystem admin's owner not the bound executor, the split admin (the CTM
        // executor's) would still not be that owner's.
        vm.mockCall(coreExecutor, abi.encodeWithSignature("PROXY_ADMIN()"), abi.encode(address(1)));
        vm.expectRevert("CTM-domain ProxyAdmin not owned by governance");
        script.prepare(bridgehub, ctm);
    }

    function test_requireReadyRefusesAnAdminNotReadyForTheDomain() public {
        address bridgehub = previousRelease.bridgehub;
        address ctm = ctmUpgrade.getCTMAddress();
        SplitCTMProxyAdmin script = new SplitCTMProxyAdmin();

        vm.expectRevert("the CTM-domain ProxyAdmin is the ecosystem one");
        script.requireReady(bridgehub, ctm, ecosystemAdmin);

        vm.expectRevert("the CTM-domain ProxyAdmin does not run this build's ProxyAdmin code");
        script.requireReady(bridgehub, ctm, address(script));

        // The right code, but owned by whoever deployed it.
        address strangers = address(new ProxyAdmin());
        vm.expectRevert("CTM-domain ProxyAdmin not owned by governance");
        script.requireReady(bridgehub, ctm, strangers);
    }
}

/// @notice The same, with the ServerNotifier behind the ecosystem admin too: the split moves it
///         with the rest, and the bootstrap's handover only nominates the CTM executor.
contract UpgradeIntegrationTestLocalSplitCTMProxyAdminWithNotifier is UpgradeIntegrationTestLocalSplitCTMProxyAdmin {
    function _shareTheNotifier() internal pure override returns (bool) {
        return true;
    }

    function _handoverAdminCalls() internal pure override returns (uint256) {
        return 1;
    }
}
