// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {Call} from "contracts/governance/Common.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {RegistryBootstrapMigration} from "contracts/upgrades/registry/bootstrap/RegistryBootstrapMigration.sol";
import {BootstrapManifest, PinnedContract, ProxyUpgradeRow} from "contracts/upgrades/registry/RegistryTypes.sol";
import {CTM_CONTRACT_COUNT, CTMContract} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {UpgradeHelperLib} from "../default-upgrade/UpgradeHelperLib.sol";
import {DeployCTML1OrGateway} from "../../ctm/DeployCTML1OrGateway.sol";
import {Utils} from "../../utils/Utils.sol";

/// @notice The v34 CTM upgrade: the ONE-TIME edge into the registry-driven model (see the
///         Bootstrap section of {docs/registry-driven-upgrades.md}). The pipeline still deploys
///         the new implementations and composes the legacy upgrade cut — chains crossing this
///         edge run pre-v34 facets and take the cut by hand — but the stage-1 CTM call soup is
///         GONE: everything the CTM must do (its own implementation swap, the version commit,
///         the provenance anchors, the authority handover) is pinned in a write-once
///         `RegistryBootstrapMigration` deployed at prepare time, and executed by its single
///         `migrate()` call. Governance reviews a manifest and FOUR calls — nominate the CTM,
///         hand over its ProxyAdmin, migrate, accept — instead of a dozen setters, and every
///         later upgrade is a `CTMTransition` under the bound `CTMUpgradeExecutor`.
contract CTMUpgrade_v34 is DefaultCTMUpgrade {
    /// @notice The bound executor the whole CTM domain lands under. Deployed by this prepare
    ///         run; its address rides the bootstrap manifest (pinned + binding-checked there).
    CTMUpgradeExecutor public ctmUpgradeExecutor;

    /// @notice The write-once edge object. Its manifest pins everything the stage-1 calls used
    ///         to spell out.
    RegistryBootstrapMigration public bootstrapMigration;

    function prepareCTMUpgrade() public virtual override {
        super.prepareCTMUpgrade();
        // AFTER `generateUpgradeData`: the manifest pins the composed upgrade cut.
        deployRegistryBootstrap();
    }

    function deployNewCTMContracts() public virtual override {
        super.deployNewCTMContracts();

        // The MailboxFacet deployed by the base pipeline's facet step takes a live checker.
        deployEIP7702Checker();

        // The upgrade engine — the composed cut's init delegatecall target, pinned by the
        // bootstrap manifest through `upgradeCutInitCodehash`.
        ctmAddresses.stateTransition.defaultUpgrade = deployUsedUpgradeContract();

        // The new ChainTypeManager implementation (per VM) — the bootstrap manifest's one
        // participating inventory row.
        (, string memory ctmContractName) = DeployCTML1OrGateway.resolve(
            config.isZKsyncOS,
            CTMContract.ChainTypeManager
        );
        ctmAddresses.stateTransition.implementations.chainTypeManager = deploySimpleContract(ctmContractName, false);

        // Deliberately OUTSIDE the registry flow (own chainAdmin-owned ProxyAdmin): the notifier
        // upgrade rides the CTM-admin operational calls, not the bootstrap manifest.
        ctmAddresses.stateTransition.implementations.serverNotifier = deploySimpleContract("ServerNotifier", false);

        // The genesis release deployed by the base pipeline's `deployStateTransitionDiamondFacets`
        // pins the force-deployments blob, so it must exist before that step runs.
        getFixedForceDeploymentsData();
    }

    /// @notice The break-glass governor of the deployed `CTMUpgradeExecutor`.
    /// @dev Defaults to the upgrade owner so local/test runs work unconfigured. A PRODUCTION run
    ///      MUST override this with the real EmergencyUpgradeBoard — the whole point of the
    ///      split is that the routine owner cannot bypass transition invariants.
    function getEmergencyUpgradeBoard() public virtual returns (address) {
        return getOwnerAddress();
    }

    /// @notice Deploys the bound executor and the write-once migration pinned to this prepare
    ///         run's outputs.
    function deployRegistryBootstrap() public virtual {
        require(upgradeConfig.upgradeCutPrepared, "upgrade cut not prepared");
        address ctmProxy = ctmAddresses.stateTransition.proxies.chainTypeManager;
        require(ctmProxy != address(0), "CTM proxy is zero");
        // The admin that ACTUALLY owns the CTM proxy (and the per-CTM proxies), read from the
        // live EIP-1967 slot rather than any address book — the migration validates every row
        // against it, so a stale book entry would fail loudly at the wrong time.
        ProxyAdmin ctmProxyAdmin = ProxyAdmin(Utils.getProxyAdminAddress(ctmProxy));

        vm.broadcast(getBroadcasterAddress());
        ctmUpgradeExecutor = new CTMUpgradeExecutor(
            getOwnerAddress(),
            getEmergencyUpgradeBoard(),
            IChainTypeManager(ctmProxy),
            ctmProxyAdmin,
            // The audited-object anchor for every FUTURE transition this executor accepts. The
            // registry objects carry no immutables, so the compiled runtime code IS the on-chain
            // runtime code.
            keccak256(vm.getDeployedCode("CTMTransition.sol:CTMTransition"))
        );

        vm.broadcast(getBroadcasterAddress());
        bootstrapMigration = new RegistryBootstrapMigration(_bootstrapManifest(ctmProxy, ctmProxyAdmin));

        console.log("CTMUpgradeExecutor deployed at:", address(ctmUpgradeExecutor));
        console.log("RegistryBootstrapMigration deployed at:", address(bootstrapMigration));
    }

    function _bootstrapManifest(
        address _ctmProxy,
        ProxyAdmin _ctmProxyAdmin
    ) internal view returns (BootstrapManifest memory manifest) {
        address implNew = ctmAddresses.stateTransition.implementations.chainTypeManager;
        require(implNew != address(0), "new CTM implementation not deployed");
        address release = ctmAddresses.stateTransition.currentRelease;
        require(release != address(0), "current release not deployed");

        // The one participating slot of the enum-indexed CTM-domain inventory: the CTM's own
        // implementation swap. Every other slot stays inert (explicitly not upgraded) — the
        // per-CTM proxies keep their implementations across this edge.
        ProxyUpgradeRow[] memory proxyUpgrades = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        proxyUpgrades[uint256(CTMContract.ChainTypeManager)] = ProxyUpgradeRow({
            proxy: _ctmProxy,
            expectedOldImpl: Utils.getImplementation(_ctmProxy),
            implNew: PinnedContract({addr: implNew, codehash: implNew.codehash}),
            callInitializeUpgrade: false
        });

        Diamond.DiamondCutData memory upgradeCut = abi.decode(
            newlyGeneratedData.upgradeCutData,
            (Diamond.DiamondCutData)
        );

        manifest = BootstrapManifest({
            ctm: _ctmProxy,
            expectedProtocolVersion: getOldProtocolVersion(),
            ctmProxyAdmin: _ctmProxyAdmin,
            proxyUpgrades: proxyUpgrades,
            currentRelease: PinnedContract({addr: release, codehash: release.codehash}),
            newProtocolVersion: getNewProtocolVersion(),
            oldProtocolVersionDeadline: UpgradeHelperLib.getOldProtocolDeadline(),
            upgradeCut: upgradeCut,
            upgradeCutInitCodehash: upgradeCut.initAddress.codehash,
            ctmExecutor: PinnedContract({
                addr: address(ctmUpgradeExecutor),
                codehash: address(ctmUpgradeExecutor).codehash
            })
        });
    }

    /// @notice The migration swaps the CTM implementation itself (a source-checked manifest row).
    function prepareUpgradeCTMCalls() public virtual override returns (Call[] memory calls) {
        return new Call[](0);
    }

    /// @notice The migration commits the version edge and installs both anchors itself.
    function provideSetNewVersionUpgradeCall() public virtual override returns (Call[] memory calls) {
        return new Call[](0);
    }

    /// @notice The whole stage-1 CTM leg: hand both authorities to the migration, run the edge,
    ///         and complete the executor's two-step CTM ownership handover. `migrate()` is
    ///         permissionless (the handover IS the approval) but rides the bundle so the edge is
    ///         applied atomically with it.
    function prepareVersionSpecificStage1GovernanceCallsL1() public virtual override returns (Call[] memory calls) {
        require(address(bootstrapMigration) != address(0), "bootstrap migration not deployed");
        address ctmProxy = ctmAddresses.stateTransition.proxies.chainTypeManager;
        address ctmProxyAdmin = Utils.getProxyAdminAddress(ctmProxy);

        calls = new Call[](4);
        calls[0] = Call({
            target: ctmProxy,
            data: abi.encodeCall(Ownable2Step.transferOwnership, (address(bootstrapMigration))),
            value: 0
        });
        calls[1] = Call({
            target: ctmProxyAdmin,
            data: abi.encodeCall(Ownable2Step.transferOwnership, (address(bootstrapMigration))),
            value: 0
        });
        calls[2] = Call({target: address(bootstrapMigration), data: abi.encodeCall(bootstrapMigration.migrate, ()), value: 0});
        calls[3] = Call({
            target: address(ctmUpgradeExecutor),
            data: abi.encodeCall(ctmUpgradeExecutor.acceptCTMOwnership, ()),
            value: 0
        });
    }
}
