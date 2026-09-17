// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Script, console2 as console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {
    IAdminFunctions,
    OwnerWrap,
    OWNER_KIND_NONE,
    OWNER_KIND_LEGACY_GOVERNANCE,
    OWNER_KIND_OZ_CHAIN_ADMIN
} from "contracts/script-interfaces/IAdminFunctions.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IMigrator} from "contracts/state-transition/chain-interfaces/IMigrator.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Call} from "contracts/governance/Common.sol";
import {ChainInfoFromBridgehub, Utils} from "./utils/Utils.sol";

import {stdToml} from "forge-std/StdToml.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {GetDiamondCutData} from "./utils/GetDiamondCutData.sol";
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";
import {L2WrappedBaseTokenStore} from "contracts/bridge/L2WrappedBaseTokenStore.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";

import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {L2DACommitmentScheme, PubdataContent} from "contracts/common/Config.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";

bytes32 constant SET_TOKEN_MULTIPLIER_SETTER_ROLE = keccak256("SET_TOKEN_MULTIPLIER_SETTER_ROLE");

/// @dev Protocol version threshold (packed `major << 32`) at which the Admin
///      facet's `upgradeChainFromVersion` gained the leading `address _chainAddress`
///      parameter. Chains still on a version below this expose only the legacy
///      2-arg signature; calling the v31 variant against them hits the DiamondProxy
///      fallback and reverts with `"F"`.
uint256 constant V31_UPGRADE_CHAIN_FROM_VERSION_THRESHOLD = uint256(31) << 32;

/// @notice Legacy 2-arg Admin interface used when the chain being upgraded is
///         still on a pre-v31 protocol version (so its Admin facet only has
///         the old selector). The abi-encoded call produced via this interface
///         lands on the old facet; the new 3-arg selector would not.
interface IAdminLegacy {
    function upgradeChainFromVersion(uint256 _protocolVersion, Diamond.DiamondCutData calldata _cutData) external;
}

/// @notice Minimal interface for OZ single-step Ownable contracts (e.g. ProxyAdmin).
///         Avoids calling `pendingOwner()` (Ownable2Step-only) on plain Ownable.
interface IOwnableSingleStep {
    function owner() external view returns (address);
    function transferOwnership(address _newOwner) external;
}

/// Subset of the legacy ZKsync `Governance.sol` (TimelockController-style)
/// surface we need for wrapping. `executeInstant` is `onlySecurityCouncil`,
/// `scheduleTransparent` is `onlyOwner`. The `Operation` struct is
/// `(Call[], bytes32 predecessor, bytes32 salt)`.
interface ILegacyGovernance {
    struct LegacyOperation {
        Call[] calls;
        bytes32 predecessor;
        bytes32 salt;
    }
    function scheduleTransparent(LegacyOperation calldata op, uint256 delay) external;
    function executeInstant(LegacyOperation calldata op) external payable;
    function securityCouncil() external view returns (address);
}

/// Subset of the legacy OZ `ChainAdmin` (Ownable variant) surface we need.
interface IChainAdminMulticall {
    function multicall(Call[] calldata calls, bool requireSuccess) external payable;
}

contract AdminFunctions is Script, IAdminFunctions {
    using stdToml for string;

    function governanceAcceptOwner(address _governor, address _target) public {
        Ownable2Step adminContract = Ownable2Step(_target);
        Utils.executeUpgrade({
            _governor: _governor,
            _salt: Utils.currentLegacyGovSalt(),
            _target: _target,
            _data: abi.encodeCall(adminContract.acceptOwnership, ()),
            _value: 0,
            _delay: 0
        });
    }

    /// Walk every Bridgehub-discoverable ecosystem ownable (bridgehub itself,
    /// asset router, l1 nullifier, ctm deployer, chain asset handler) and
    /// accept the pending ownership transfer where one is targeted at
    /// `_governor`. Idempotent — running against an already-correct ecosystem
    /// is a no-op.
    function governanceAcceptOwnerAggregated(address _governor, address _bridgehub) public {
        address assetRouter = address(IL1Bridgehub(_bridgehub).assetRouter());
        address chainAssetHandler = address(IL1Bridgehub(_bridgehub).chainAssetHandler());
        address ctmDeploymentTracker = address(IL1Bridgehub(_bridgehub).l1CtmDeployer());

        IL1AssetRouter assetRouterContract = IL1AssetRouter(assetRouter);
        address l1Nullifier = address(assetRouterContract.L1_NULLIFIER());

        if (Ownable2Step(_bridgehub).pendingOwner() == _governor) {
            governanceAcceptOwner(_governor, _bridgehub);
        }
        if (Ownable2Step(assetRouter).pendingOwner() == _governor) {
            governanceAcceptOwner(_governor, assetRouter);
        }
        if (Ownable2Step(l1Nullifier).pendingOwner() == _governor) {
            governanceAcceptOwner(_governor, l1Nullifier);
        }
        if (Ownable2Step(ctmDeploymentTracker).pendingOwner() == _governor) {
            governanceAcceptOwner(_governor, ctmDeploymentTracker);
        }
        if (Ownable2Step(chainAssetHandler).pendingOwner() == _governor) {
            governanceAcceptOwner(_governor, chainAssetHandler);
        }
    }

    /// Unlike `governanceAcceptOwner`, this does NOT route through a Governance
    /// scheduleTransparent/execute wrapper, so it works against governance
    /// addresses that are not Ownable Governance.sol contracts (e.g.
    /// ProtocolUpgradeHandler on stage/mainnet). Caller is expected to
    /// broadcast as `_governor` (forge `--sender` + `--unlocked` / anvil
    /// impersonation, or governor as a real signer).
    function governanceAcceptOwnerConditional(address _governor, address _target) public {
        if (Ownable2Step(_target).pendingOwner() != _governor) {
            return;
        }
        vm.startBroadcast();
        Ownable2Step(_target).acceptOwnership();
        vm.stopBroadcast();
    }

    /// Broadcasts as the script's `--sender` (which must be the current
    /// owner). No-op when ownership is already at or pending to `_newOwner`.
    function transferOwnerConditional(address _target, address _newOwner) public {
        Ownable2Step ownable = Ownable2Step(_target);
        if (ownable.owner() == _newOwner || ownable.pendingOwner() == _newOwner) {
            return;
        }
        vm.startBroadcast();
        ownable.transferOwnership(_newOwner);
        vm.stopBroadcast();
    }

    /// Single-step Ownable transfer (e.g. OZ ProxyAdmin) — `transferOwnership`
    /// immediately changes the owner with no acceptOwnership step. No-op when
    /// ownership is already at `_newOwner`. Broadcasts as `--sender`, which
    /// must be the current owner.
    function transferOwnerSingleConditional(address _target, address _newOwner) public {
        IOwnableSingleStep ownable = IOwnableSingleStep(_target);
        if (ownable.owner() == _newOwner) {
            return;
        }
        vm.startBroadcast();
        ownable.transferOwnership(_newOwner);
        vm.stopBroadcast();
    }

    /// Fund `_addr` with 100 ETH on the current anvil fork via `anvil_setBalance`.
    /// `vm.deal` only affects forge's in-memory simulation context, so under
    /// `forge script --broadcast` the impersonated sender would still have 0 ETH
    /// on chain and gas estimation would fail. `vm.rpc` propagates to the fork.
    function _anvilFund(address _addr) private {
        string memory params = string.concat('["', vm.toString(_addr), '","0x56BC75E2D63100000"]');
        vm.rpc("anvil_setBalance", params);
    }

    /// Walk every registered chain's CTM (deduplicated) and ensure both the
    /// CTM (Ownable2Step) and its EIP-1967 ProxyAdmin (single-step Ownable) are
    /// owned by `_governance`. Each individual transfer is conditional, so
    /// re-running this against an already-correct ecosystem is a no-op. Intended
    /// for upgrade pre-stages where governance must own these contracts before
    /// stage 1 governance calls (e.g. ProxyAdmin.upgradeAndCall) execute.
    ///
    /// Requires anvil `--auto-impersonate` (or a runner that has unlocked the
    /// resolved owner addresses) — broadcasts switch sender per-step.
    ///
    /// 2-arg variant kept for callers that don't need contract-owner wrapping
    /// (i.e. every current owner is already an EOA). Delegates to the 3-arg
    /// form with an empty registry; if any current owner is a contract that
    /// isn't a no-key EOA, the helper reverts so the caller is forced to
    /// supply a registry entry.
    function ensureCtmsAndProxyAdminsOwnedByGovernance(address _bridgehub, address _governance) public {
        OwnerWrap[] memory empty = new OwnerWrap[](0);
        ensureCtmsAndProxyAdminsOwnedByGovernanceWithWraps(_bridgehub, _governance, empty);
    }

    /// `_wraps` is a registry of contract owners that must be wrapped (since
    /// they have no private key); see [`OwnerWrap`]. EOAs (current owner has
    /// no code) are broadcast directly; contract owners not present in the
    /// registry cause a hard revert so missing config surfaces immediately
    /// instead of being papered over.
    function ensureCtmsAndProxyAdminsOwnedByGovernanceWithWraps(
        address _bridgehub,
        address _governance,
        OwnerWrap[] memory _wraps
    ) public {
        uint256[] memory chainIds = IL1Bridgehub(_bridgehub).getAllZKChainChainIDs();
        address[] memory seenCtms = new address[](chainIds.length);
        uint256 seenCtmCount = 0;

        // `acceptOwnership()` on each Ownable2Step CTM whose pendingOwner is
        // `_governance` must execute as PUH on real chain — which means going
        // through PUH's governance flow, not impersonation. We collect these
        // calls here and persist them so protocol-ops folds them into stage 0
        // of governance_calls in the merged ecosystem.toml. Sized to
        // chainIds.length (max possible), trimmed before serialization.
        Call[] memory acceptCalls = new Call[](chainIds.length);
        uint256 acceptCount = 0;

        for (uint256 i = 0; i < chainIds.length; i++) {
            address ctm = IL1Bridgehub(_bridgehub).chainTypeManager(chainIds[i]);
            bool already = false;
            for (uint256 j = 0; j < seenCtmCount; j++) {
                if (seenCtms[j] == ctm) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            seenCtms[seenCtmCount++] = ctm;

            Ownable2Step ctmOwnable = Ownable2Step(ctm);
            address ctmOwner = ctmOwnable.owner();
            if (ctmOwner != _governance && ctmOwnable.pendingOwner() != _governance) {
                _issueAsOwner(ctmOwner, ctm, abi.encodeCall(Ownable2Step.transferOwnership, (_governance)), _wraps);
            }
            if (ctmOwnable.pendingOwner() == _governance) {
                acceptCalls[acceptCount++] = Call({
                    target: ctm,
                    value: 0,
                    data: abi.encodeCall(Ownable2Step.acceptOwnership, ())
                });
            }

            _ensureProxyAdminOwnedByGovernance(ctm, _governance, _wraps);
        }

        _savePreGovernanceAcceptOwnershipCalls(acceptCalls, acceptCount);

        // Bridgehub-discoverable ecosystem proxies. Mirrors the contracts visited
        // by `governanceAcceptOwnerAggregated`, since the same ProxyAdmins gate
        // their `upgradeAndCall` invocations during stage 1 governance calls.
        address assetRouter = address(IL1Bridgehub(_bridgehub).assetRouter());
        address chainAssetHandler = address(IL1Bridgehub(_bridgehub).chainAssetHandler());
        address ctmDeploymentTracker = address(IL1Bridgehub(_bridgehub).l1CtmDeployer());
        address l1Nullifier = address(IL1AssetRouter(assetRouter).L1_NULLIFIER());

        _ensureProxyAdminOwnedByGovernance(_bridgehub, _governance, _wraps);
        _ensureProxyAdminOwnedByGovernance(assetRouter, _governance, _wraps);
        _ensureProxyAdminOwnedByGovernance(chainAssetHandler, _governance, _wraps);
        _ensureProxyAdminOwnedByGovernance(ctmDeploymentTracker, _governance, _wraps);
        _ensureProxyAdminOwnedByGovernance(l1Nullifier, _governance, _wraps);
    }

    /// Helper: read the EIP-1967 admin slot of `_proxy`, and if its single-step
    /// Ownable owner isn't already `_governance`, transfer ownership to it.
    function _ensureProxyAdminOwnedByGovernance(
        address _proxy,
        address _governance,
        OwnerWrap[] memory _wraps
    ) private {
        address proxyAdmin = address(uint160(uint256(vm.load(_proxy, Utils.ADMIN_SLOT))));
        if (proxyAdmin == address(0)) {
            return;
        }
        address paOwner = IOwnableSingleStep(proxyAdmin).owner();
        if (paOwner == _governance) {
            return;
        }
        _issueAsOwner(paOwner, proxyAdmin, abi.encodeCall(IOwnableSingleStep.transferOwnership, (_governance)), _wraps);
    }

    /// Persist the trimmed `acceptOwnership()` Call list to a TOML so
    /// `protocol_ops ecosystem upgrade-prepare-all` can fold it into stage 0
    /// of the merged governance_calls. Always written (even when empty) so
    /// the Rust side can `vm.readFile` unconditionally.
    function _savePreGovernanceAcceptOwnershipCalls(Call[] memory _calls, uint256 _count) private {
        Call[] memory trimmed = new Call[](_count);
        for (uint256 i = 0; i < _count; i++) {
            trimmed[i] = _calls[i];
        }
        string memory toml = vm.serializeBytes("pre_governance_accept_ownerships", "calls", abi.encode(trimmed));
        string memory path = string.concat(vm.projectRoot(), "/script-out/pre-governance-accept-ownerships.toml");
        vm.writeToml(toml, path);
    }

    /// Execute zero-value calls against Ownable targets as their current
    /// owners. This is used for operational admin surfaces that intentionally
    /// stay outside governance ownership, such as the ServerNotifier
    /// ProxyAdmin. Contract owners without an explicit registry entry are
    /// treated as ChainAdmin-style wrappers, matching the ServerNotifier
    /// ownership model used by CTM deployments.
    function executeOwnableCallsWithWraps(bytes memory _callsToExecute, OwnerWrap[] memory _wraps) public {
        Call[] memory calls = abi.decode(_callsToExecute, (Call[]));
        for (uint256 i = 0; i < calls.length; i++) {
            require(calls[i].value == 0, "ownable call value not supported");
            address currentOwner = IOwnableSingleStep(calls[i].target).owner();
            _issueAsOperationalOwner(currentOwner, calls[i].target, calls[i].data, _wraps);
        }
    }

    function _issueAsOperationalOwner(
        address _currentOwner,
        address _target,
        bytes memory _data,
        OwnerWrap[] memory _wraps
    ) private {
        if (_currentOwner.code.length == 0) {
            _anvilFund(_currentOwner);
            vm.startBroadcast(_currentOwner);
            (bool ok, bytes memory ret) = _target.call(_data);
            vm.stopBroadcast();
            require(ok, _wrapDecodeRevert(ret));
            return;
        }
        uint8 kind = _ownerWrapKind(_currentOwner, _wraps);
        if (kind == OWNER_KIND_LEGACY_GOVERNANCE) {
            _wrapLegacyGovernance(_currentOwner, _target, _data);
        } else {
            _wrapOzChainAdmin(_currentOwner, _target, _data);
        }
    }

    /// Issue `_data` against `_target` on behalf of `_currentOwner`. EOAs are
    /// broadcast directly via `vm.startBroadcast`. Contract owners are looked
    /// up in `_wraps` and routed through their wrapping shape (legacy
    /// Governance.sol => `scheduleTransparent` + `executeInstant` from EOA;
    /// OZ ChainAdmin (Ownable2Step) => `multicall` from EOA). Reverts on
    /// contract owners that have no registry entry.
    function _issueAsOwner(
        address _currentOwner,
        address _target,
        bytes memory _data,
        OwnerWrap[] memory _wraps
    ) private {
        if (_currentOwner.code.length == 0) {
            _anvilFund(_currentOwner);
            vm.startBroadcast(_currentOwner);
            (bool ok, bytes memory ret) = _target.call(_data);
            vm.stopBroadcast();
            require(ok, _wrapDecodeRevert(ret));
            return;
        }
        uint8 kind = _ownerWrapKind(_currentOwner, _wraps);
        if (kind == OWNER_KIND_LEGACY_GOVERNANCE) {
            _wrapLegacyGovernance(_currentOwner, _target, _data);
        } else if (kind == OWNER_KIND_OZ_CHAIN_ADMIN) {
            _wrapOzChainAdmin(_currentOwner, _target, _data);
        } else {
            revert(
                string.concat(
                    "ownable contract owner without registry entry: ",
                    vm.toString(_currentOwner),
                    " - add it to permanent-values/<env>.toml [[ownable_proxies]]"
                )
            );
        }
    }

    function _ownerWrapKind(address _currentOwner, OwnerWrap[] memory _wraps) private pure returns (uint8 kind) {
        kind = OWNER_KIND_NONE;
        for (uint256 i = 0; i < _wraps.length; i++) {
            if (_wraps[i].ownableContract == _currentOwner) {
                return _wraps[i].kind;
            }
        }
    }

    /// Storage-backed salt counter so consecutive `scheduleTransparent` ops
    /// produced by a single script invocation get distinct hashes (the legacy
    /// Governance contract rejects duplicate operation IDs). Foundry script
    /// storage is per-invocation so this resets cleanly each run.
    uint256 private _legacyGovSaltCounter;

    function _wrapLegacyGovernance(address _gov, address _target, bytes memory _data) private {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: _target, value: 0, data: _data});
        // Mix the per-regen `legacy_gov_salt` (Utils.currentLegacyGovSalt()) into
        // the op salt so the op id rotates with it — without this the op id is a
        // fixed counter and collides with a previously-broadcast (and possibly
        // stranded) op of the same content. The counter keeps multiple wraps in a
        // single regen distinct.
        ILegacyGovernance.LegacyOperation memory op = ILegacyGovernance.LegacyOperation({
            calls: calls,
            predecessor: bytes32(0),
            salt: keccak256(abi.encodePacked(Utils.currentLegacyGovSalt(), _legacyGovSaltCounter++))
        });
        address eoaOwner = IOwnableSingleStep(_gov).owner();
        address sc = ILegacyGovernance(_gov).securityCouncil();
        _anvilFund(eoaOwner);
        vm.startBroadcast(eoaOwner);
        ILegacyGovernance(_gov).scheduleTransparent(op, 0);
        vm.stopBroadcast();
        _anvilFund(sc);
        vm.startBroadcast(sc);
        ILegacyGovernance(_gov).executeInstant(op);
        vm.stopBroadcast();
    }

    function _wrapOzChainAdmin(address _admin, address _target, bytes memory _data) private {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: _target, value: 0, data: _data});
        address eoaOwner = IOwnableSingleStep(_admin).owner();
        _anvilFund(eoaOwner);
        vm.startBroadcast(eoaOwner);
        IChainAdminMulticall(_admin).multicall(calls, true);
        vm.stopBroadcast();
    }

    /// Pull a string-typed revert reason out of `_returndata`. Falls back to a
    /// generic message if the returndata isn't an Error(string).
    function _wrapDecodeRevert(bytes memory _returndata) private pure returns (string memory) {
        if (_returndata.length < 68) return "wrapped call failed (no revert reason)";
        bytes4 sig;
        assembly {
            sig := mload(add(_returndata, 32))
        }
        if (sig != 0x08c379a0) return "wrapped call failed (non-string revert)";
        bytes memory stripped = new bytes(_returndata.length - 4);
        for (uint256 i = 0; i < stripped.length; i++) {
            stripped[i] = _returndata[i + 4];
        }
        return abi.decode(stripped, (string));
    }

    function governanceAcceptAdmin(address _governor, address _target) public {
        IZKChain adminContract = IZKChain(_target);
        Utils.executeUpgrade({
            _governor: _governor,
            _salt: Utils.currentLegacyGovSalt(),
            _target: _target,
            _data: abi.encodeCall(adminContract.acceptAdmin, ()),
            _value: 0,
            _delay: 0
        });
    }

    function chainAdminAcceptAdmin(ChainAdmin _chainAdmin, address _target) public {
        IZKChain adminContract = IZKChain(_target);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: _target, value: 0, data: abi.encodeCall(adminContract.acceptAdmin, ())});

        vm.startBroadcast();
        _chainAdmin.multicall(calls, true);
        vm.stopBroadcast();
    }

    function chainSetTokenMultiplierSetter(
        address _chainAdmin,
        address _accessControlRestriction,
        address _diamondProxyAddress,
        address _setter
    ) public {
        if (_accessControlRestriction == address(0)) {
            _chainSetTokenMultiplierSetterOwnable(_chainAdmin, _setter);
        } else {
            _chainSetTokenMultiplierSetterLatestChainAdmin(_accessControlRestriction, _diamondProxyAddress, _setter);
        }
    }

    function _chainSetTokenMultiplierSetterOwnable(address _chainAdmin, address _setter) internal {
        IChainAdminOwnable admin = IChainAdminOwnable(_chainAdmin);

        vm.startBroadcast();
        admin.setTokenMultiplierSetter(_setter);
        vm.stopBroadcast();
    }

    function _chainSetTokenMultiplierSetterLatestChainAdmin(
        address _accessControlRestriction,
        address _diamondProxyAddress,
        address _setter
    ) internal {
        AccessControlRestriction restriction = AccessControlRestriction(_accessControlRestriction);

        if (
            restriction.requiredRoles(_diamondProxyAddress, IAdmin.setTokenMultiplier.selector) !=
            SET_TOKEN_MULTIPLIER_SETTER_ROLE
        ) {
            vm.startBroadcast();
            restriction.setRequiredRoleForCall(
                _diamondProxyAddress,
                IAdmin.setTokenMultiplier.selector,
                SET_TOKEN_MULTIPLIER_SETTER_ROLE
            );
            vm.stopBroadcast();
        }

        if (!restriction.hasRole(SET_TOKEN_MULTIPLIER_SETTER_ROLE, _setter)) {
            vm.startBroadcast();
            restriction.grantRole(SET_TOKEN_MULTIPLIER_SETTER_ROLE, _setter);
            vm.stopBroadcast();
        }
    }

    function governanceExecuteCalls(bytes memory _callsToExecute, address _governanceAddr) public {
        Call[] memory calls = abi.decode(_callsToExecute, (Call[]));
        Utils.executeCalls(_governanceAddr, Utils.currentLegacyGovSalt(), 0, calls);
    }

    /// Fork-only governance replay: impersonate `_governanceAddr` and forward
    /// each call directly. Used when the governance contract is the
    /// `ProtocolUpgradeHandler` (no `Ownable.owner()`, no `scheduleTransparent`
    /// path that simulates without delays/signatures), so the standard
    /// `Utils.executeCalls` flow is unusable. Real-chain replay still needs
    /// the full PUH propose-execute mechanism — this helper exists strictly
    /// for `--auto-impersonate` anvil forks.
    function governanceExecuteCallsDirect(bytes memory _callsToExecute, address _governanceAddr) public {
        Call[] memory calls = abi.decode(_callsToExecute, (Call[]));
        _anvilFund(_governanceAddr);
        vm.startBroadcast(_governanceAddr);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory ret) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            require(ok, _wrapDecodeRevert(ret));
        }
        vm.stopBroadcast();
    }

    function ecosystemAdminExecuteCalls(bytes memory _callsToExecute, address _ecosystemAdminAddr) public {
        Call[] memory calls = abi.decode(_callsToExecute, (Call[]));
        saveAndSendAdminTx(_ecosystemAdminAddr, calls, true);
    }

    function adminEncodeMulticall(bytes memory _callsToExecute) external pure {
        Call[] memory calls = abi.decode(_callsToExecute, (Call[]));

        bytes memory result = abi.encodeCall(ChainAdmin.multicall, (calls, true));
        console.logBytes(result);
    }

    function adminExecuteUpgrade(
        bytes memory _diamondCut,
        address _adminAddr,
        address _accessControlRestriction,
        address _chainDiamondProxy
    ) public {
        uint256 oldProtocolVersion = IZKChain(_chainDiamondProxy).getProtocolVersion();
        Diamond.DiamondCutData memory upgradeCutData = abi.decode(_diamondCut, (Diamond.DiamondCutData));

        Utils.adminExecute(
            _adminAddr,
            _accessControlRestriction,
            _chainDiamondProxy,
            abi.encodeCall(IAdmin.upgradeChainFromVersion, (_chainDiamondProxy, oldProtocolVersion, upgradeCutData)),
            0
        );
    }

    /// @notice Upgrade a chain by reading the diamond cut directly from the CTM, together with the
    ///         DA configuration the new version requires of it.
    /// @dev Reads the diamond cut from the CTM's storage to avoid TOML parsing
    ///      issues with large hex strings.
    ///
    ///      The cut and the DA calls go out as ONE `ChainAdmin.multicall`. They cannot be split:
    ///      `setPubdataContent` only exists on the facets the cut installs, and between the cut and
    ///      a later DA transaction the chain would commit v33 batches under the old pair — which
    ///      for a no-DA validium do not prove.
    function upgradeChainFromCTM(IAdminFunctions.ChainUpgradeParams calldata _params) public {
        address _chainAddress = _params.chainAddress;
        console.log("AdminFunctions: upgrading chain", _chainAddress);

        IZKChain chain = IZKChain(_chainAddress);
        IChainTypeManager ctm = IChainTypeManager(chain.getChainTypeManager());
        console.log("AdminFunctions: using CTM", address(ctm));

        uint256 newProtocolVersion = ctm.protocolVersion();
        console.log("AdminFunctions: new protocol version", newProtocolVersion);

        uint256 currentProtocolVersion = chain.getProtocolVersion();
        console.log("AdminFunctions: current chain protocol version", currentProtocolVersion);

        require(
            newProtocolVersion > currentProtocolVersion,
            "AdminFunctions: new protocol version must be greater than current"
        );

        Diamond.DiamondCutData memory diamondCut = GetDiamondCutData.getDiamondCutData(
            address(ctm),
            currentProtocolVersion
        );

        // Select the Admin facet's `upgradeChainFromVersion` signature that
        // actually lives on the chain we're about to call. Pre-v31 chains
        // expose the legacy 2-arg variant; v31+ expose the new 3-arg one that
        // carries `_chainAddress`. Using the wrong one hits the DiamondProxy
        // fallback and reverts with `"F"`.
        bytes memory upgradeCall = currentProtocolVersion < V31_UPGRADE_CHAIN_FROM_VERSION_THRESHOLD
            ? abi.encodeCall(IAdminLegacy.upgradeChainFromVersion, (currentProtocolVersion, diamondCut))
            : abi.encodeCall(IAdmin.upgradeChainFromVersion, (_chainAddress, currentProtocolVersion, diamondCut));

        uint256 callCount = 1;
        if (_params.shouldSetDaValidatorPair) {
            ++callCount;
        }
        if (_params.shouldSetPubdataContent) {
            ++callCount;
        }
        Call[] memory calls = new Call[](callCount);
        uint256 next;
        calls[next++] = Call({target: _chainAddress, value: 0, data: upgradeCall});
        // After the cut, so the pair the first batch of the new version commits with is already
        // the new one.
        if (_params.shouldSetDaValidatorPair) {
            console.log("AdminFunctions: setting DA validator pair", _params.l1DaValidator);
            calls[next++] = Call({
                target: _chainAddress,
                value: 0,
                data: abi.encodeCall(
                    IAdmin.setDAValidatorPair,
                    (_params.l1DaValidator, L2DACommitmentScheme(_params.l2DaCommitmentScheme))
                )
            });
        }
        if (_params.shouldSetPubdataContent) {
            console.log("AdminFunctions: setting pubdata content", _params.pubdataContent);
            calls[next++] = Call({
                target: _chainAddress,
                value: 0,
                data: abi.encodeCall(IAdmin.setPubdataContent, (PubdataContent(_params.pubdataContent)))
            });
        }

        Utils.adminExecuteCalls(_params.adminAddr, _params.accessControlRestriction, calls);

        console.log("AdminFunctions: upgrade completed successfully");
    }

    function adminScheduleUpgrade(
        address _adminAddr,
        address _accessControlRestriction,
        address _bridgehub,
        uint256 _chainId,
        uint256 _timestamp
    ) public {
        ChainInfoFromBridgehub memory chainInfo = Utils.chainInfoFromBridgehubAndChainId(_bridgehub, _chainId);

        Call[] memory calls = new Call[](1);
        // ServerNotifier.setUpgradeTimestamp validates upgrade cut data exists, eliminating
        // the race between timestamp and diamond-cut availability that exists on ChainAdmin alone.
        calls[0] = Call({
            target: chainInfo.serverNotifier,
            value: 0,
            data: abi.encodeCall(ServerNotifier.setUpgradeTimestamp, (_chainId, _timestamp))
        });

        Utils.adminExecuteCalls(_adminAddr, _accessControlRestriction, calls);
    }

    function makePermanentRollup(ChainAdmin _chainAdmin, address _target) public {
        IZKChain adminContract = IZKChain(_target);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: _target, value: 0, data: abi.encodeCall(adminContract.makePermanentRollup, ())});

        vm.startBroadcast();
        _chainAdmin.multicall(calls, true);
        vm.stopBroadcast();
    }

    function updateValidator(
        address _adminAddr,
        address _accessControlRestriction,
        address _validatorTimelock,
        uint256 _chainId,
        address _validatorAddress,
        bool _addValidator
    ) public {
        bytes memory data;
        // Selector is identical between the new and old ValidatorTimelock,
        // so this works against both shapes.
        if (_addValidator) {
            data = abi.encodeCall(ValidatorTimelock.addValidatorForChainId, (_chainId, _validatorAddress));
        } else {
            data = abi.encodeCall(ValidatorTimelock.removeValidatorForChainId, (_chainId, _validatorAddress));
        }

        Utils.adminExecute(_adminAddr, _accessControlRestriction, _validatorTimelock, data, 0);
    }

    /// @notice Adds L2WrappedBaseToken of a chain to the store.
    function addL2WethToStore(
        address _storeAddress,
        ChainAdmin _ecosystemAdmin,
        uint256 _chainId,
        address _l2WBaseToken
    ) public {
        L2WrappedBaseTokenStore l2WrappedBaseTokenStore = L2WrappedBaseTokenStore(_storeAddress);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: _storeAddress,
            value: 0,
            data: abi.encodeCall(l2WrappedBaseTokenStore.initializeChain, (_chainId, _l2WBaseToken))
        });

        vm.startBroadcast();
        _ecosystemAdmin.multicall(calls, true);
        vm.stopBroadcast();
    }

    /// @notice Change pubdata pricing mode. Must be called by chain admin.
    function setPubdataPricingMode(ChainAdmin _chainAdmin, address _target, PubdataPricingMode _pricingMode) public {
        IZKChain zkChainContract = IZKChain(_target);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: _target,
            value: 0,
            data: abi.encodeCall(zkChainContract.setPubdataPricingMode, (_pricingMode))
        });

        vm.startBroadcast();
        _chainAdmin.multicall(calls, true);
        vm.stopBroadcast();
    }

    struct Output {
        address admin;
        bytes encodedData;
    }

    /// We use explicit `_shouldSend` instead of the standard `--broadcast` to ensure stable output
    /// for the calldata
    function setTransactionFilterer(
        address _bridgehub,
        uint256 _chainId,
        address _transactionFiltererAddress,
        bool _shouldSend
    ) public {
        ChainInfoFromBridgehub memory chainInfo = Utils.chainInfoFromBridgehubAndChainId(_bridgehub, _chainId);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: chainInfo.diamondProxy,
            value: 0,
            data: abi.encodeCall(IAdmin.setTransactionFilterer, (_transactionFiltererAddress))
        });

        saveAndSendAdminTx(chainInfo.admin, calls, _shouldSend);
    }

    function pauseDepositsBeforeInitiatingMigration(address _bridgehub, uint256 _chainId, bool _shouldSend) public {
        ChainInfoFromBridgehub memory chainInfo = Utils.chainInfoFromBridgehubAndChainId(_bridgehub, _chainId);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: chainInfo.diamondProxy,
            value: 0,
            data: abi.encodeCall(IMigrator.pauseDepositsBeforeInitiatingMigration, ())
        });

        saveAndSendAdminTx(chainInfo.admin, calls, _shouldSend);
    }

    function unpauseDeposits(address _bridgehub, uint256 _chainId, bool _shouldSend) public {
        ChainInfoFromBridgehub memory chainInfo = Utils.chainInfoFromBridgehubAndChainId(_bridgehub, _chainId);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: chainInfo.diamondProxy,
            value: 0,
            data: abi.encodeCall(IMigrator.unpauseDeposits, ())
        });

        saveAndSendAdminTx(chainInfo.admin, calls, _shouldSend);
    }

    function setDAValidatorPair(
        address _bridgehub,
        address _accessControlRestriction,
        uint256 _chainId,
        address _l1DaValidator,
        L2DACommitmentScheme _l2DaCommitmentScheme,
        bool _shouldSend
    ) public {
        ChainInfoFromBridgehub memory chainInfo = Utils.chainInfoFromBridgehubAndChainId(_bridgehub, _chainId);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: chainInfo.diamondProxy,
            value: 0,
            data: abi.encodeCall(IAdmin.setDAValidatorPair, (_l1DaValidator, _l2DaCommitmentScheme))
        });

        saveAndSendAdminTx(chainInfo.admin, _accessControlRestriction, calls, _shouldSend);
    }

    /// @notice Sets the chain's pubdata content (ZKsync OS only): whether its batches commit the full
    ///         pubdata or only the mandatory L2->L1 log region. A new chain starts at `FULL_PUBDATA`, and a
    ///         permanent rollup is locked to it.
    /// @dev Rejected by the chain while committed-but-unverified batches exist, since the value is part of
    ///      the batch public input.
    function setPubdataContent(
        address _bridgehub,
        address _accessControlRestriction,
        uint256 _chainId,
        PubdataContent _pubdataContent,
        bool _shouldSend
    ) public {
        ChainInfoFromBridgehub memory chainInfo = Utils.chainInfoFromBridgehubAndChainId(_bridgehub, _chainId);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: chainInfo.diamondProxy,
            value: 0,
            data: abi.encodeCall(IAdmin.setPubdataContent, (_pubdataContent))
        });

        saveAndSendAdminTx(chainInfo.admin, _accessControlRestriction, calls, _shouldSend);
    }

    /// @notice Raises the chain's ZKsync OS single-transaction gas limit (EIP-7825) above the Ethereum
    ///         default. A new chain runs on that default until this is called.
    /// @dev Same batch-public-input constraint as `setPubdataContent`.
    function setZKsyncOSMaxTxGasLimit(
        address _bridgehub,
        address _accessControlRestriction,
        uint256 _chainId,
        uint64 _newMaxTxGasLimit,
        bool _shouldSend
    ) public {
        ChainInfoFromBridgehub memory chainInfo = Utils.chainInfoFromBridgehubAndChainId(_bridgehub, _chainId);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: chainInfo.diamondProxy,
            value: 0,
            data: abi.encodeCall(IAdmin.setZKsyncOSMaxTxGasLimit, (_newMaxTxGasLimit))
        });

        saveAndSendAdminTx(chainInfo.admin, _accessControlRestriction, calls, _shouldSend);
    }

    function enableValidator(
        address _bridgehub,
        uint256 _l2ChainId,
        address _validatorAddress,
        address _validatorTimelock,
        bool _shouldSend
    ) public {
        ChainInfoFromBridgehub memory l2ChainInfo = Utils.chainInfoFromBridgehubAndChainId(_bridgehub, _l2ChainId);

        bytes memory callData = abi.encodeCall(
            ValidatorTimelock.addValidatorForChainId,
            (_l2ChainId, _validatorAddress)
        );
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: _validatorTimelock, value: 0, data: callData});

        saveAndSendAdminTx(l2ChainInfo.admin, calls, _shouldSend);
    }

    struct AdminL1L2TxParams {
        address bridgehub;
        uint256 l1GasPrice;
        uint256 chainId;
        address to;
        uint256 value;
        bytes data;
        address refundRecipient;
        bool _shouldSend;
    }

    // Using struct for input to avoid stack too deep errors.
    // The outer function does not expect it as input rightaway for easier encoding in zkstack Rust.
    function _adminL1L2TxInner(AdminL1L2TxParams memory params) private {
        ChainInfoFromBridgehub memory l2ChainInfo = Utils.chainInfoFromBridgehubAndChainId(
            params.bridgehub,
            params.chainId
        );
        Call[] memory calls = Utils.prepareAdminL1L2DirectTransaction(
            params.l1GasPrice,
            params.data,
            Utils.MAX_PRIORITY_TX_GAS,
            new bytes[](0),
            params.to,
            params.value,
            params.chainId,
            params.bridgehub,
            l2ChainInfo.l1AssetRouterProxy,
            params.refundRecipient
        );

        saveAndSendAdminTx(l2ChainInfo.admin, calls, params._shouldSend);
    }

    function adminL1L2Tx(
        address _bridgehub,
        uint256 _l1GasPrice,
        uint256 _chainId,
        address _to,
        uint256 _value,
        bytes memory _data,
        address _refundRecipient,
        bool _shouldSend
    ) public {
        _adminL1L2TxInner(
            AdminL1L2TxParams({
                bridgehub: _bridgehub,
                l1GasPrice: _l1GasPrice,
                chainId: _chainId,
                to: _to,
                value: _value,
                data: _data,
                refundRecipient: _refundRecipient,
                _shouldSend: _shouldSend
            })
        );
    }

    function saveAndSendAdminTx(address _admin, Call[] memory _calls, bool _shouldSend) internal {
        saveAndSendAdminTx(_admin, address(0), _calls, _shouldSend);
    }

    function saveAndSendAdminTx(
        address _admin,
        address _accessControlRestriction,
        Call[] memory _calls,
        bool _shouldSend
    ) internal {
        bytes memory data = abi.encode(_calls);

        if (_shouldSend && _calls.length > 0) {
            Utils.adminExecuteCalls(_admin, _accessControlRestriction, _calls);
        }

        saveOutput(Output({admin: _admin, encodedData: data}));
    }

    function saveOutput(Output memory output) internal {
        vm.serializeAddress("root", "admin_address", output.admin);
        string memory toml = vm.serializeBytes("root", "encoded_data", output.encodedData);
        string memory path = string.concat(vm.projectRoot(), "/script-out/output-admin-functions.toml");
        vm.writeToml(toml, path);
    }
}
