// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {Call} from "contracts/governance/Common.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IL2V34Upgrade} from "contracts/upgrades/IL2V34Upgrade.sol";
import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {RegistryBootstrapMigration} from "contracts/upgrades/registry/bootstrap/RegistryBootstrapMigration.sol";
import {BootstrapManifest, PinnedContract, ProxyUpgradeRow} from "contracts/upgrades/registry/RegistryTypes.sol";
import {CTM_CONTRACT_COUNT, CTMContract} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {UpgradeHelperLib} from "../default-upgrade/UpgradeHelperLib.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {ChainCreationParamsConfig, StateTransitionDeployedAddresses} from "../../utils/Types.sol";
import {PublishFactoryDepsResult} from "../../utils/bytecode/BytecodePublisher.s.sol";
import {DeployCTML1OrGateway} from "../../ctm/DeployCTML1OrGateway.sol";
import {Utils} from "../../utils/Utils.sol";

/// @notice The v34 CTM upgrade: the ONE-TIME edge into the registry-driven model (see the
///         Bootstrap section of {docs/registry-driven-upgrades.md}). Chains crossing this edge
///         run pre-v34 facets and take the committed cut by hand, but the cut itself already
///         has the registry shape: NO facet cuts, just the `BootstrapUpgradeZKsyncOS` init,
///         which derives the facet reinstall on-chain from the pinned genesis release. The
///         stage-1 CTM call soup is GONE too: everything the CTM must do (its own
///         implementation swap, the version commit, the provenance anchors, the authority
///         handover) is pinned in a write-once `RegistryBootstrapMigration` deployed at prepare
///         time, and executed by its single `migrate()` call. Governance reviews a manifest and
///         FOUR calls — nominate the CTM, hand over its ProxyAdmin, migrate, accept — and every
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

    /// @notice The upgrade engine — the composed cut's init delegatecall target, pinned by the
    ///         bootstrap manifest through `upgradeCutInitCodehash`. Deployed HERE, not in
    ///         `deployNewCTMContracts`: the engine pins the genesis release as an immutable, and
    ///         the release only exists once `deployStateTransitionDiamondFacets` has run.
    function generateUpgradeData() public virtual override {
        ctmAddresses.stateTransition.defaultUpgrade = deployUsedUpgradeContract();
        super.generateUpgradeData();
    }

    /// @dev Only ZKsync OS chains can be upgraded onto this release (the registry model has no
    ///      EraVM-deployable release yet); protocol-ops skips Era CTMs before this ever runs.
    function deployUsedUpgradeContract() internal virtual override returns (address) {
        require(config.isZKsyncOS, "Upgrading Era chains onto this release is not supported");
        // The bootstrap engine: derives the facet reinstall on-chain from the genesis release it
        // pins as an immutable, then runs the storage/L2 part of `DefaultUpgradeZKsyncOS`.
        return deploySimpleContract("BootstrapUpgradeZKsyncOS", false);
    }

    /// @notice The bootstrap's committed cut carries NO facet cuts: the engine derives the full
    ///         facet reinstall on-chain from its pinned genesis release
    ///         ({BootstrapUpgradeZKsyncOS}) — the same two-step shape as a registry-driven edge,
    ///         with no hand-composed selector lists in the committed calldata.
    function generateUpgradeCutData(
        StateTransitionDeployedAddresses memory _stateTransition,
        ChainCreationParamsConfig memory _chainCreationParams,
        uint256 _l1ChainId,
        address _ownerAddress,
        PublishFactoryDepsResult memory _factoryDepsResult,
        address /* _registeredChainIdDiamondProxy */
    ) public override returns (Diamond.DiamondCutData memory upgradeCutData) {
        uint256 nonce = UpgradeHelperLib.getProtocolUpgradeNonce(_chainCreationParams.latestProtocolVersion);
        ProposedUpgrade memory proposedUpgrade = getProposedUpgrade(
            _stateTransition,
            _chainCreationParams,
            _l1ChainId,
            _ownerAddress,
            _factoryDepsResult,
            nonce
        );
        upgradeCutData = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: _stateTransition.defaultUpgrade,
            initCalldata: abi.encodeCall(DefaultUpgrade.upgrade, (proposedUpgrade))
        });
    }

    /// @notice The committed (ecosystem-wide) L2 upgrade calldata: the upgrade-time (re)init of
    ///         the force-deployed system contracts — NOT the genesis path, these chains are
    ///         already initialized. The additionalForceDeploymentsData placeholder is rewritten
    ///         per chain by `DefaultUpgradeZKsyncOS.getL2UpgradeTxData` at upgrade time.
    function getL2UpgradeCalldata() internal returns (bytes memory) {
        return
            abi.encodeCall(
                IL2V34Upgrade.upgrade,
                (
                    config.isZKsyncOS,
                    coreAddresses.bridgehub.proxies.ctmDeploymentTracker,
                    generatedData.forceDeploymentsData,
                    ""
                )
            );
    }

    /// @notice The L2 delegate (`L2V34Upgrade`) rides the upgrade tx itself as an unsafe force
    ///         deployment at a bytecode-derived address, so it never overwrites live code.
    function getAdditionalUniversalForceDeployments()
        internal
        override
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory additional)
    {
        if (!config.isZKsyncOS) {
            // Era chains cannot be upgraded onto this release; the Era branch exists only for
            // the L1-only local fixture (see `CTMUpgrade_v34_Test`), which relays no L2 leg.
            return additional;
        }
        bytes memory bytecodeInfo = Utils.getZKOSBytecodeInfoForContract("L2V34Upgrade.sol", "L2V34Upgrade");
        additional = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        additional[0] = IComplexUpgrader.UniversalContractUpgradeInfo({
            upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
            deployedBytecodeInfo: bytecodeInfo,
            newAddress: L2GenesisForceDeploymentsHelper.generateRandomAddress(bytecodeInfo)
        });
    }

    function getZKsyncOSL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal virtual override returns (address, bytes memory) {
        // The delegate address must match the force-deployed `L2V34Upgrade` entry above.
        bytes memory bytecodeInfo = Utils.getZKOSBytecodeInfoForContract("L2V34Upgrade.sol", "L2V34Upgrade");
        address delegateTo = L2GenesisForceDeploymentsHelper.generateRandomAddress(bytecodeInfo);
        return getUniversalComplexUpgraderTargetAndData(_deployments, delegateTo, getL2UpgradeCalldata());
    }

    function deployNewCTMContracts() public virtual override {
        super.deployNewCTMContracts();

        // The MailboxFacet deployed by the base pipeline's facet step takes a live checker.
        deployEIP7702Checker();

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

        // Both go through the CREATE2 factory like every other prepare deployment: the Safe
        // bundle replays only factory transactions, so a plain CREATE here would leave the
        // stage-1 `migrate()`/`acceptCTMOwnership()` calls pointing at codeless addresses on
        // the real chain (a call to code-less address is a silent success).
        ctmUpgradeExecutor = CTMUpgradeExecutor(
            payable(
                deployViaCreate2AndNotify(
                    type(CTMUpgradeExecutor).creationCode,
                    abi.encode(
                        getOwnerAddress(),
                        getEmergencyUpgradeBoard(),
                        IChainTypeManager(ctmProxy),
                        ctmProxyAdmin,
                        // The audited-object anchor for every FUTURE transition this executor
                        // accepts. The registry objects carry no immutables, so the compiled
                        // runtime code IS the on-chain runtime code.
                        keccak256(vm.getDeployedCode("CTMTransition.sol:CTMTransition"))
                    ),
                    "CTMUpgradeExecutor",
                    false
                )
            )
        );

        bootstrapMigration = RegistryBootstrapMigration(
            deployViaCreate2AndNotify(
                type(RegistryBootstrapMigration).creationCode,
                abi.encode(_bootstrapManifest(ctmProxy, ctmProxyAdmin)),
                "RegistryBootstrapMigration",
                false
            )
        );
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
        calls[2] = Call({
            target: address(bootstrapMigration),
            data: abi.encodeCall(bootstrapMigration.migrate, ()),
            value: 0
        });
        calls[3] = Call({
            target: address(ctmUpgradeExecutor),
            data: abi.encodeCall(ctmUpgradeExecutor.acceptCTMOwnership, ()),
            value: 0
        });
    }
}
