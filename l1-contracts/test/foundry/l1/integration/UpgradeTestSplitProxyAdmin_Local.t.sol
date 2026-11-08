// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

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
///         ServerNotifier behind its own. `SplitCTMProxyAdmin` runs first, governance executes
///         its calls (in two goes, to cover a partial split), and every assertion of the regular
///         bootstrap test then runs over the split layout.
contract UpgradeIntegrationTestLocalSplitCTMProxyAdmin is UpgradeIntegrationTestLocal {
    /// @dev The CTM-domain ProxyAdmin the split deployed.
    address internal splitAdmin;

    /// @dev The ecosystem (Bridgehub) ProxyAdmin.
    address internal ecosystemAdmin;

    function _beforePrepare() internal override {
        address bridgehub = previousRelease.bridgehub;
        address ctm = previousRelease.chainTypeManager;
        ecosystemAdmin = DeployScriptUtils.getProxyAdminAddress(bridgehub);
        address ownAdmin = DeployScriptUtils.getProxyAdminAddress(ctm);
        StateTransitionContracts memory domain = AddressIntrospector.getCTMProxies(ChainTypeManager(ctm));
        assertTrue(domain.permissionlessValidator != address(0), "the fixture's CTM has a PermissionlessValidator");
        assertEq(_shareTheEcosystemAdmin(domain, ownAdmin), 4, "the CTM, its timelock, supplier and validator");

        SplitCTMProxyAdmin script = new SplitCTMProxyAdmin();
        vm.expectRevert(
            "CTM domain shares the ecosystem ProxyAdmin; run SplitCTMProxyAdmin and execute its calls first"
        );
        script.requireSplit(bridgehub, ctm);

        SplitCTMProxyAdmin.Split memory split = script.prepare(bridgehub, ctm);
        assertEq(split.proxies.length, 4, "every CTM-domain proxy behind the ecosystem admin moves");
        assertEq(split.proxies[0], ctm, "the CTM moves first");
        assertEq(split.proxies[3], domain.permissionlessValidator, "the PermissionlessValidator moves too");
        assertEq(split.calls.length, 4, "one changeProxyAdmin per proxy");
        assertEq(split.governance, ProxyAdmin(ecosystemAdmin).owner(), "governance owns the ecosystem admin");
        assertEq(ProxyAdmin(split.ctmProxyAdmin).owner(), split.governance, "governance owns the new admin");
        assertTrue(split.ctmProxyAdmin != ecosystemAdmin, "a new admin, not the ecosystem's");
        assertTrue(split.ctmProxyAdmin != ownAdmin, "a new admin, not the one the fixture emptied");

        // A partial split: the last proxy is still behind the ecosystem admin, which both the
        // split's check and the prepare's (the same rule) refuse.
        governanceMulticall(split.governance, _firstCalls(split.calls, 3));
        vm.expectRevert(
            "PermissionlessValidator is still behind the ecosystem ProxyAdmin; run SplitCTMProxyAdmin and execute its calls first"
        );
        script.requireSplit(bridgehub, ctm);

        // Rerun from live state: the rest moves under the admin the CTM already has.
        SplitCTMProxyAdmin.Split memory rest = script.prepare(bridgehub, ctm);
        assertEq(rest.ctmProxyAdmin, split.ctmProxyAdmin, "the rest moves under the same admin");
        assertEq(rest.proxies.length, 1, "only the proxy left behind moves");
        assertEq(rest.proxies[0], domain.permissionlessValidator, "the PermissionlessValidator");
        governanceMulticall(rest.governance, rest.calls);
        script.requireSplit(bridgehub, ctm);

        SplitCTMProxyAdmin.Split memory again = script.prepare(bridgehub, ctm);
        assertEq(again.calls.length, 0, "a split CTM yields no calls");
        assertEq(again.ctmProxyAdmin, split.ctmProxyAdmin, "and reports the admin it has");

        splitAdmin = split.ctmProxyAdmin;
    }

    /// @dev Moves every CTM-domain proxy the fixture deployed behind its own admin back behind the
    ///      ecosystem's: the layout an ecosystem deployed before the two-executor model has. The
    ///      ServerNotifier keeps an admin of its own, as on those ecosystems.
    function _shareTheEcosystemAdmin(
        StateTransitionContracts memory _domain,
        address _ownAdmin
    ) private returns (uint256 moved) {
        (address[] memory proxies, ) = CTMDomainProxies.list(_domain);
        for (uint256 i = 0; i < proxies.length; ++i) {
            if (DeployScriptUtils.getProxyAdminAddress(proxies[i]) != _ownAdmin) {
                continue;
            }
            vm.prank(ProxyAdmin(_ownAdmin).owner());
            ProxyAdmin(_ownAdmin).changeProxyAdmin(ITransparentUpgradeableProxy(payable(proxies[i])), ecosystemAdmin);
            ++moved;
        }
        assertTrue(
            DeployScriptUtils.getProxyAdminAddress(_domain.serverNotifier) != ecosystemAdmin,
            "the notifier keeps its own admin"
        );
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
}
