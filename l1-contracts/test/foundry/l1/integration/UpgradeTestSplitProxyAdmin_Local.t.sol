// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {SplitCTMProxyAdmin} from "deploy-scripts/upgrade/v35/SplitCTMProxyAdmin.s.sol";
import {Utils as DeployScriptUtils} from "deploy-scripts/utils/Utils.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {CTMUpgradeForLocalTest, UpgradeIntegrationTestLocal} from "./UpgradeTest_Local.t.sol";

/// @notice The v35 bootstrap over an ecosystem whose CTM still shares the ecosystem ProxyAdmin, as
///         zksync-os mainnet's and the ZKsync OS testnet's do: the CTM, its ValidatorTimelock and
///         its BytecodesSupplier behind the Bridgehub's admin, the ServerNotifier behind its own.
///         `SplitCTMProxyAdmin` runs first, governance executes its calls, and every assertion of
///         the regular bootstrap test then runs over the split layout.
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
        _shareTheEcosystemAdmin(ctm, ownAdmin);

        SplitCTMProxyAdmin script = new SplitCTMProxyAdmin();
        vm.expectRevert("CTM still shares the ecosystem ProxyAdmin");
        script.requireSplit(bridgehub, ctm);

        SplitCTMProxyAdmin.Split memory split = script.prepare(bridgehub, ctm);
        assertEq(split.proxies.length, 3, "the CTM, its timelock and its supplier move");
        assertEq(split.proxies[0], ctm, "the CTM moves first");
        assertEq(split.calls.length, 3, "one changeProxyAdmin per proxy");
        assertEq(split.governance, ProxyAdmin(ecosystemAdmin).owner(), "governance owns the ecosystem admin");
        assertEq(ProxyAdmin(split.ctmProxyAdmin).owner(), split.governance, "governance owns the new admin");
        assertTrue(split.ctmProxyAdmin != ecosystemAdmin, "a new admin, not the ecosystem's");
        assertTrue(split.ctmProxyAdmin != ownAdmin, "a new admin, not the one the fixture emptied");

        governanceMulticall(split.governance, split.calls);
        script.requireSplit(bridgehub, ctm);

        // Rendered from live state: once executed, a second run moves nothing.
        SplitCTMProxyAdmin.Split memory again = script.prepare(bridgehub, ctm);
        assertEq(again.calls.length, 0, "an already split CTM yields no calls");
        assertEq(again.ctmProxyAdmin, split.ctmProxyAdmin, "and reports the admin it has");

        splitAdmin = split.ctmProxyAdmin;
    }

    /// @dev Moves the CTM-domain proxies the fixture deployed behind their own admin back behind
    ///      the ecosystem's: the layout an ecosystem deployed before the two-executor model has.
    function _shareTheEcosystemAdmin(address _ctm, address _ownAdmin) private {
        address[3] memory proxies = [
            _ctm,
            IChainTypeManager(_ctm).validatorTimelockPostV29(),
            IChainTypeManager(_ctm).L1_BYTECODES_SUPPLIER()
        ];
        for (uint256 i = 0; i < proxies.length; ++i) {
            if (DeployScriptUtils.getProxyAdminAddress(proxies[i]) != _ownAdmin) {
                continue;
            }
            vm.prank(ProxyAdmin(_ownAdmin).owner());
            ProxyAdmin(_ownAdmin).changeProxyAdmin(ITransparentUpgradeableProxy(payable(proxies[i])), ecosystemAdmin);
        }
        assertEq(DeployScriptUtils.getProxyAdminAddress(_ctm), ecosystemAdmin, "the CTM must share the admin");
    }

    function test_bootstrapLandsTheSplitCTMDomainUnderTheCTMExecutor() public view {
        CTMUpgradeForLocalTest bootstrap = CTMUpgradeForLocalTest(address(ctmUpgrade));
        address ctm = ctmUpgrade.getCTMAddress();
        address executor = address(bootstrap.ctmUpgradeExecutor());

        assertEq(ProxyAdmin(splitAdmin).owner(), executor, "the split admin landed under the CTM executor");
        address[4] memory ctmDomain = [
            ctm,
            IChainTypeManager(ctm).validatorTimelockPostV29(),
            IChainTypeManager(ctm).L1_BYTECODES_SUPPLIER(),
            IChainTypeManager(ctm).serverNotifierAddress()
        ];
        for (uint256 i = 0; i < ctmDomain.length; ++i) {
            assertEq(
                DeployScriptUtils.getProxyAdminAddress(ctmDomain[i]),
                splitAdmin,
                "every CTM-domain proxy sits behind the split admin"
            );
        }
        assertEq(
            ProxyAdmin(ecosystemAdmin).owner(),
            bootstrap.bootstrapMigration().getManifest().coreExecutor,
            "the ecosystem admin landed under the core executor"
        );
    }
}
