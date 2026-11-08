// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

// solhint-disable no-console

import {console2 as console} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Call} from "contracts/governance/Common.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {Create2FactoryUtils} from "../../utils/deploy/Create2FactoryUtils.s.sol";
import {CTM_PROXY_ADMIN_SALT_DOMAIN, Utils} from "../../utils/Utils.sol";

/// @title SplitCTMProxyAdmin
/// @author Matter Labs
/// @notice Gives a CTM whose proxies still share the ecosystem `ProxyAdmin` a CTM-domain
///         `ProxyAdmin` of its own: the shape the v35 registry bootstrap requires, since it hands
///         the ecosystem admin to the core executor and the CTM-domain one to the CTM executor.
///         Ecosystems deployed before the two-executor model (zksync-os mainnet and the ZKsync OS
///         testnet among them) keep the CTM, its ValidatorTimelock and its BytecodesSupplier behind
///         the ecosystem admin, and `CTMUpgrade_v35` refuses them until this has run.
/// @dev Run ONCE per affected CTM, BEFORE the v35 prepare, and execute its governance calls in an
///      earlier governance execution than the bootstrap bundle: the prepare reads the CTM-domain
///      admin from the CTM's live EIP-1967 slot, binds the CTM executor to it and pins it in the
///      migration's manifest, and package verification refuses any extra call to a `ProxyAdmin`
///      inside the bootstrap bundle. See "Splitting a shared CTM-domain ProxyAdmin" in
///      {docs/upgrade-operations.md}.
/// @dev What it does: deploys a `ProxyAdmin` through the CREATE2 factory, owned by the ecosystem
///      admin's owner (governance, the account that hands the CTM-domain admin to the migration in
///      the bootstrap bundle), under the salt domain fresh deployments use for theirs keyed by the
///      CTM, so each CTM gets an admin of its own; and renders
///      one `changeProxyAdmin(proxy, newAdmin)` call on the ecosystem admin per CTM-domain proxy
///      still behind it. The ServerNotifier is not moved here: it has an admin of its own, and the
///      bootstrap's ChainAdmin handover moves it under the new admin. Rendered from live state, so
///      a CTM that already has its own admin yields no calls.
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
            console.log("The CTM already has a CTM-domain ProxyAdmin of its own:", split.ctmProxyAdmin);
        } else {
            console.log("CTM-domain ProxyAdmin deployed:", split.ctmProxyAdmin);
            console.log("Governance calls to execute before the v35 prepare:", split.calls.length);
        }
    }

    /// @notice Deploys the CTM-domain ProxyAdmin when the CTM still shares the ecosystem's, and
    ///         renders the governance calls that move the CTM-domain proxies under it.
    /// @param _bridgehub The ecosystem's Bridgehub proxy.
    /// @param _ctm The CTM proxy.
    /// @return split The split; `calls` is empty when the CTM already has an admin of its own.
    function prepare(address _bridgehub, address _ctm) public returns (Split memory split) {
        require(IBridgehubBase(_bridgehub).chainTypeManagerIsRegistered(_ctm), "CTM not registered on the Bridgehub");
        address ecosystemAdmin = Utils.getProxyAdminAddress(_bridgehub);
        require(ecosystemAdmin != address(0), "Bridgehub has no ProxyAdmin");

        split.chainTypeManager = _ctm;
        split.ecosystemProxyAdmin = ecosystemAdmin;
        split.governance = ProxyAdmin(ecosystemAdmin).owner();

        address ctmAdmin = Utils.getProxyAdminAddress(_ctm);
        if (ctmAdmin != ecosystemAdmin) {
            // Already split (or deployed with its own admin): nothing moves.
            split.ctmProxyAdmin = ctmAdmin;
            return split;
        }

        // The CTM is part of the salt domain: two CTMs split under one governance must never land
        // on one admin, and the factory hands back an existing deployment at a repeated address.
        split.ctmProxyAdmin = create2WithDeterministicOwner(
            type(ProxyAdmin).creationCode,
            split.governance,
            keccak256(abi.encode(CTM_PROXY_ADMIN_SALT_DOMAIN, _ctm))
        );
        // A rerun reuses the admin an earlier run deployed; it must still be governance's.
        require(
            ProxyAdmin(split.ctmProxyAdmin).owner() == split.governance,
            "CTM-domain ProxyAdmin not owned by governance"
        );
        notifyAboutDeployment(split.ctmProxyAdmin, "ProxyAdmin", "", "CTM-domain ProxyAdmin");

        address[] memory candidates = ctmDomainProxies(_ctm);
        uint256 shared = 0;
        for (uint256 i = 0; i < candidates.length; ++i) {
            if (Utils.getProxyAdminAddress(candidates[i]) == ecosystemAdmin) {
                ++shared;
            }
        }
        split.proxies = new address[](shared);
        split.calls = new Call[](shared);
        uint256 next = 0;
        for (uint256 i = 0; i < candidates.length; ++i) {
            if (Utils.getProxyAdminAddress(candidates[i]) != ecosystemAdmin) {
                continue;
            }
            split.proxies[next] = candidates[i];
            split.calls[next] = Call({
                target: ecosystemAdmin,
                value: 0,
                data: abi.encodeCall(
                    ProxyAdmin.changeProxyAdmin,
                    (ITransparentUpgradeableProxy(payable(candidates[i])), split.ctmProxyAdmin)
                )
            });
            ++next;
        }
    }

    /// @notice The CTM-domain proxies a pre-registry CTM has besides its ServerNotifier (which the
    ///         bootstrap's ChainAdmin handover moves): the CTM itself, its ValidatorTimelock and its
    ///         BytecodesSupplier, the CTM first.
    /// @param _ctm The CTM proxy.
    /// @return proxies The proxies, without zero entries.
    function ctmDomainProxies(address _ctm) public view returns (address[] memory proxies) {
        IChainTypeManager ctm = IChainTypeManager(_ctm);
        proxies = new address[](3);
        proxies[0] = _ctm;
        proxies[1] = ctm.validatorTimelockPostV29();
        proxies[2] = ctm.L1_BYTECODES_SUPPLIER();
        for (uint256 i = 1; i < proxies.length; ++i) {
            require(proxies[i] != address(0), "CTM-domain proxy is zero");
        }
    }

    /// @notice Reverts unless `_ctm` is split off `_bridgehub`'s ProxyAdmin: the CTM and every other
    ///         CTM-domain proxy sit behind one admin other than the ecosystem's, owned by the
    ///         ecosystem admin's owner. The state `CTMUpgrade_v35` needs before it prepares.
    /// @param _bridgehub The ecosystem's Bridgehub proxy.
    /// @param _ctm The CTM proxy.
    function requireSplit(address _bridgehub, address _ctm) public view {
        address ecosystemAdmin = Utils.getProxyAdminAddress(_bridgehub);
        address ctmAdmin = Utils.getProxyAdminAddress(_ctm);
        require(ctmAdmin != ecosystemAdmin, "CTM still shares the ecosystem ProxyAdmin");
        address[] memory proxies = ctmDomainProxies(_ctm);
        for (uint256 i = 1; i < proxies.length; ++i) {
            require(Utils.getProxyAdminAddress(proxies[i]) == ctmAdmin, "CTM-domain proxy not behind the CTM admin");
        }
        require(
            ProxyAdmin(ctmAdmin).owner() == ProxyAdmin(ecosystemAdmin).owner(),
            "CTM-domain ProxyAdmin not owned by governance"
        );
    }
}
