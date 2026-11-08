// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

// solhint-disable no-console

import {console2 as console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Call} from "contracts/governance/Common.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";

import {AddressIntrospector} from "../../utils/AddressIntrospector.sol";
import {Create2FactoryUtils} from "../../utils/deploy/Create2FactoryUtils.s.sol";
import {CTM_PROXY_ADMIN_SALT_DOMAIN, Utils} from "../../utils/Utils.sol";
import {CTMDomainProxies} from "./CTMDomainProxies.sol";

/// @title SplitCTMProxyAdmin
/// @author Matter Labs
/// @notice Gives a CTM whose proxies share the ecosystem `ProxyAdmin` a CTM-domain `ProxyAdmin` of
///         its own, owned by governance, and renders the governance calls that move the CTM domain
///         under it: the precondition {CTMDomainProxies.requireSplit} states for the v35 bootstrap.
///         When and how to run it:
///         {docs/upgrade-operations.md#splitting-a-shared-ctm-domain-proxyadmin}.
contract SplitCTMProxyAdmin is Create2FactoryUtils {
    /// @notice What the split moves and where.
    struct Split {
        /// The CTM being split off.
        address chainTypeManager;
        /// The ecosystem `ProxyAdmin` (the Bridgehub's).
        address ecosystemProxyAdmin;
        /// The Bridgehub's owner, which owns the ecosystem admin and the CTM-domain one.
        address governance;
        /// The CTM-domain admin: newly deployed, or the CTM's own when it already has one.
        address ctmProxyAdmin;
        /// The CTM-domain proxies the governance calls move, in call order.
        address[] proxies;
        /// The governance calls, one `changeProxyAdmin` per proxy. Empty when nothing is shared.
        Call[] calls;
    }

    /// @notice Prepares the split of `_ctm` off `_bridgehub`'s ProxyAdmin and writes it to
    ///         `_outputPath` ({write}). Only under `--broadcast`: a dry run's admin exists only in
    ///         the simulation, and calls naming it would hand the proxies to an address with no code.
    /// @param _bridgehub The ecosystem's Bridgehub proxy.
    /// @param _ctm The CTM proxy.
    /// @param _outputPath Where the TOML output goes.
    function run(address _bridgehub, address _ctm, string memory _outputPath) external {
        require(
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume),
            "dry run: the CTM-domain ProxyAdmin would not be deployed on chain; rerun with --broadcast"
        );
        Split memory split = prepare(_bridgehub, _ctm);
        write(split, _outputPath);
        if (split.calls.length == 0) {
            console.log("Nothing left behind the ecosystem ProxyAdmin; CTM-domain ProxyAdmin:", split.ctmProxyAdmin);
        } else {
            console.log("CTM-domain ProxyAdmin:", split.ctmProxyAdmin);
            for (uint256 i = 0; i < split.proxies.length; ++i) {
                console.log("changeProxyAdmin", split.proxies[i], "on", split.ecosystemProxyAdmin);
            }
        }
    }

    /// @notice Writes `_split` to `_outputPath`: the calls as `[governance_calls] calls` (an
    ///         `abi.encode(Call[])`, the shape the governance tooling reads), what they move as
    ///         `[ctm_proxy_admin_split]`.
    /// @param _split The split {prepare} returned.
    /// @param _outputPath Where the TOML output goes.
    function write(Split memory _split, string memory _outputPath) public {
        string memory section = "ctm_proxy_admin_split";
        vm.serializeAddress(section, "chain_type_manager", _split.chainTypeManager);
        vm.serializeAddress(section, "ecosystem_proxy_admin", _split.ecosystemProxyAdmin);
        vm.serializeAddress(section, "governance", _split.governance);
        vm.serializeAddress(section, "ctm_proxy_admin", _split.ctmProxyAdmin);
        string memory splitToml = vm.serializeAddress(section, "proxies", _split.proxies);
        string memory callsToml = vm.serializeBytes("governance_calls", "calls", abi.encode(_split.calls));
        vm.serializeString("root", section, splitToml);
        vm.writeToml(vm.serializeString("root", "governance_calls", callsToml), _outputPath);
    }

    /// @notice Deploys the CTM-domain ProxyAdmin when the CTM still shares the ecosystem's, and
    ///         renders one `changeProxyAdmin` on the ecosystem admin per CTM-domain proxy still
    ///         behind it. A partial split is finished towards the admin the CTM already has.
    /// @param _bridgehub The ecosystem's Bridgehub proxy.
    /// @param _ctm The CTM proxy.
    /// @return split The split; `calls` is empty when nothing is left behind the ecosystem admin.
    function prepare(address _bridgehub, address _ctm) public returns (Split memory split) {
        require(IBridgehubBase(_bridgehub).chainTypeManagerIsRegistered(_ctm), "CTM not registered on the Bridgehub");
        address ecosystemAdmin = Utils.getProxyAdminAddress(_bridgehub);
        require(ecosystemAdmin != address(0), "Bridgehub has no ProxyAdmin");

        split.chainTypeManager = _ctm;
        split.ecosystemProxyAdmin = ecosystemAdmin;
        split.governance = IOwnable(_bridgehub).owner();
        split.ctmProxyAdmin = Utils.getProxyAdminAddress(_ctm);

        (address[] memory domain, ) = CTMDomainProxies.list(AddressIntrospector.getCTMProxies(ChainTypeManager(_ctm)));
        uint256 shared = 0;
        for (uint256 i = 0; i < domain.length; ++i) {
            if (Utils.getProxyAdminAddress(domain[i]) == ecosystemAdmin) {
                ++shared;
            }
        }
        if (shared == 0) {
            return split;
        }

        // The bootstrap hands the ecosystem admin, not the Bridgehub, to the core executor.
        require(
            ProxyAdmin(ecosystemAdmin).owner() == split.governance,
            "the ecosystem ProxyAdmin is not governance's: split before the v35 bootstrap"
        );

        if (split.ctmProxyAdmin == ecosystemAdmin) {
            // Keyed by the CTM: the factory hands back an existing deployment at a repeated
            // address, so two CTMs under one governance would otherwise share one admin.
            split.ctmProxyAdmin = create2WithDeterministicOwner(
                type(ProxyAdmin).creationCode,
                split.governance,
                keccak256(abi.encode(CTM_PROXY_ADMIN_SALT_DOMAIN, _ctm))
            );
            notifyAboutDeployment(split.ctmProxyAdmin, "ProxyAdmin", "", "CTM-domain ProxyAdmin");
        }
        // A reused admin (an earlier run's, or the CTM's own after a partial split) may have
        // changed hands since; moving proxies under it would hand them over too.
        require(
            ProxyAdmin(split.ctmProxyAdmin).owner() == split.governance,
            "CTM-domain ProxyAdmin not owned by governance"
        );

        split.proxies = new address[](shared);
        split.calls = new Call[](shared);
        uint256 next = 0;
        for (uint256 i = 0; i < domain.length; ++i) {
            if (Utils.getProxyAdminAddress(domain[i]) != ecosystemAdmin) {
                continue;
            }
            split.proxies[next] = domain[i];
            split.calls[next] = Call({
                target: ecosystemAdmin,
                value: 0,
                data: abi.encodeCall(
                    ProxyAdmin.changeProxyAdmin,
                    (ITransparentUpgradeableProxy(payable(domain[i])), split.ctmProxyAdmin)
                )
            });
            ++next;
        }
    }

    /// @notice Reverts unless `_ctm` is split off `_bridgehub`'s ProxyAdmin
    ///         ({CTMDomainProxies.requireSplit}) and governance (the Bridgehub's owner) owns the
    ///         CTM-domain admin.
    /// @param _bridgehub The ecosystem's Bridgehub proxy.
    /// @param _ctm The CTM proxy.
    function requireSplit(address _bridgehub, address _ctm) public view {
        address ecosystemAdmin = Utils.getProxyAdminAddress(_bridgehub);
        address ctmAdmin = Utils.getProxyAdminAddress(_ctm);
        CTMDomainProxies.requireSplit(
            AddressIntrospector.getCTMProxies(ChainTypeManager(_ctm)),
            ctmAdmin,
            ecosystemAdmin
        );
        require(
            ProxyAdmin(ctmAdmin).owner() == IOwnable(_bridgehub).owner(),
            "CTM-domain ProxyAdmin not owned by governance"
        );
    }

    /// @notice Reverts unless `_ctmProxyAdmin`, the admin a split's calls name, is ready to receive
    ///         `_ctm`'s domain: deployed with the `ProxyAdmin` code this build produces, owned by
    ///         governance (the Bridgehub's owner), and not the ecosystem admin.
    /// @param _bridgehub The ecosystem's Bridgehub proxy.
    /// @param _ctm The CTM proxy.
    /// @param _ctmProxyAdmin The output's `ctm_proxy_admin`.
    function requireReady(address _bridgehub, address _ctm, address _ctmProxyAdmin) external view {
        require(IBridgehubBase(_bridgehub).chainTypeManagerIsRegistered(_ctm), "CTM not registered on the Bridgehub");
        address ecosystemAdmin = Utils.getProxyAdminAddress(_bridgehub);
        require(_ctmProxyAdmin != ecosystemAdmin, "the CTM-domain ProxyAdmin is the ecosystem one");
        require(
            keccak256(_ctmProxyAdmin.code) == keccak256(type(ProxyAdmin).runtimeCode),
            "the CTM-domain ProxyAdmin does not run this build's ProxyAdmin code"
        );
        require(
            ProxyAdmin(_ctmProxyAdmin).owner() == IOwnable(_bridgehub).owner(),
            "CTM-domain ProxyAdmin not owned by governance"
        );
    }
}
