// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

// solhint-disable no-console

import {console2 as console} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Call} from "contracts/governance/Common.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";

import {AddressIntrospector} from "../../utils/AddressIntrospector.sol";
import {Create2FactoryUtils} from "../../utils/deploy/Create2FactoryUtils.s.sol";
import {CTM_PROXY_ADMIN_SALT_DOMAIN, Utils} from "../../utils/Utils.sol";
import {CTMDomainProxies} from "./CTMDomainProxies.sol";

/// @title SplitCTMProxyAdmin
/// @author Matter Labs
/// @notice Gives a CTM whose proxies still share the ecosystem `ProxyAdmin` a CTM-domain
///         `ProxyAdmin` of its own: the shape the v35 registry bootstrap requires, since it hands
///         the ecosystem admin to the core executor and the CTM-domain one to the CTM executor.
///         Ecosystems deployed before the two-executor model (zksync-os mainnet and the ZKsync OS
///         testnet among them) keep the CTM, its ValidatorTimelock, BytecodesSupplier and
///         PermissionlessValidator behind the ecosystem admin, and `CTMUpgrade_v35` refuses them
///         until this has run ({CTMDomainProxies.requireSplit}).
/// @dev Run ONCE per affected CTM, BEFORE the v35 prepare, and execute its governance calls in an
///      earlier governance execution than the bootstrap bundle: the prepare reads the CTM-domain
///      admin from the CTM's live EIP-1967 slot, binds the CTM executor to it and pins it in the
///      migration's manifest, and package verification refuses any extra call to a `ProxyAdmin`
///      inside the bootstrap bundle. See "Splitting a shared CTM-domain ProxyAdmin" in
///      {docs/upgrade-operations.md}.
/// @dev What it does: deploys a `ProxyAdmin` through the CREATE2 factory, owned by the ecosystem
///      admin's owner (governance, the account that hands the CTM-domain admin to the migration in
///      the bootstrap bundle), under the salt domain fresh deployments use for theirs keyed by the
///      CTM, so each CTM gets an admin of its own; and renders one
///      `changeProxyAdmin(proxy, newAdmin)` call on the ecosystem admin per CTM-domain proxy
///      (`AddressIntrospector.getCTMProxies`, the list the prepare reads) still behind it. A
///      ServerNotifier behind an admin of its own is left to the bootstrap's ChainAdmin handover.
///      Rendered from live state, so a CTM that already has its own admin yields no calls.
contract SplitCTMProxyAdmin is Create2FactoryUtils {
    /// @notice What the split moves and where.
    struct Split {
        /// The CTM being split off.
        address chainTypeManager;
        /// The ecosystem `ProxyAdmin` (the Bridgehub's).
        address ecosystemProxyAdmin;
        /// Its owner, which owns the CTM-domain admin too.
        address governance;
        /// The CTM-domain admin: newly deployed, or the CTM's own when it already has one.
        address ctmProxyAdmin;
        /// The CTM-domain proxies the governance calls move, in call order.
        address[] proxies;
        /// The governance calls, one `changeProxyAdmin` per proxy. Empty when nothing is shared.
        Call[] calls;
    }

    /// @notice Prepares the split of `_ctm` off `_bridgehub`'s ProxyAdmin and writes it to
    ///         `_outputPath` as `[ctm_proxy_admin_split]`, the calls ABI-encoded as a `Call[]`.
    /// @param _bridgehub The ecosystem's Bridgehub proxy.
    /// @param _ctm The CTM proxy.
    /// @param _outputPath Where the TOML output goes.
    function run(address _bridgehub, address _ctm, string memory _outputPath) external {
        Split memory split = prepare(_bridgehub, _ctm);

        string memory section = "ctm_proxy_admin_split";
        vm.serializeAddress(section, "chain_type_manager", split.chainTypeManager);
        vm.serializeAddress(section, "ecosystem_proxy_admin", split.ecosystemProxyAdmin);
        vm.serializeAddress(section, "governance", split.governance);
        vm.serializeAddress(section, "ctm_proxy_admin", split.ctmProxyAdmin);
        vm.serializeAddress(section, "proxies", split.proxies);
        string memory body = vm.serializeBytes(section, "governance_calls", abi.encode(split.calls));
        vm.writeToml(vm.serializeString("root", section, body), _outputPath);

        if (split.calls.length == 0) {
            console.log("Nothing left behind the ecosystem ProxyAdmin; CTM-domain ProxyAdmin:", split.ctmProxyAdmin);
        } else {
            console.log("CTM-domain ProxyAdmin:", split.ctmProxyAdmin);
            console.log("Governance calls to execute before the v35 prepare:", split.calls.length);
        }
    }

    /// @notice Deploys the CTM-domain ProxyAdmin when the CTM still shares the ecosystem's, and
    ///         renders the governance calls that move every CTM-domain proxy still behind the
    ///         ecosystem admin under the CTM's. A partial split is finished towards the admin the
    ///         CTM already has.
    /// @param _bridgehub The ecosystem's Bridgehub proxy.
    /// @param _ctm The CTM proxy.
    /// @return split The split; `calls` is empty when nothing is left behind the ecosystem admin.
    function prepare(address _bridgehub, address _ctm) public returns (Split memory split) {
        require(IBridgehubBase(_bridgehub).chainTypeManagerIsRegistered(_ctm), "CTM not registered on the Bridgehub");
        address ecosystemAdmin = Utils.getProxyAdminAddress(_bridgehub);
        require(ecosystemAdmin != address(0), "Bridgehub has no ProxyAdmin");

        split.chainTypeManager = _ctm;
        split.ecosystemProxyAdmin = ecosystemAdmin;
        split.governance = ProxyAdmin(ecosystemAdmin).owner();
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

        if (split.ctmProxyAdmin == ecosystemAdmin) {
            // The CTM is part of the salt domain: two CTMs split under one governance must never
            // land on one admin, and the factory hands back an existing deployment at a repeated
            // address.
            split.ctmProxyAdmin = create2WithDeterministicOwner(
                type(ProxyAdmin).creationCode,
                split.governance,
                keccak256(abi.encode(CTM_PROXY_ADMIN_SALT_DOMAIN, _ctm))
            );
            notifyAboutDeployment(split.ctmProxyAdmin, "ProxyAdmin", "", "CTM-domain ProxyAdmin");
        }
        // A rerun reuses the admin an earlier run deployed, and a partial split moves the rest
        // under the CTM's own: either must still be governance's, or the moves would hand the
        // proxies to someone else.
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
    ///         ({CTMDomainProxies.requireSplit}, the check `CTMUpgrade_v35` makes before it
    ///         prepares) and governance, the ecosystem admin's owner, owns the CTM-domain admin.
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
            ProxyAdmin(ctmAdmin).owner() == ProxyAdmin(ecosystemAdmin).owner(),
            "CTM-domain ProxyAdmin not owned by governance"
        );
    }
}
