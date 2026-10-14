// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {stdToml} from "forge-std/StdToml.sol";

import {DefaultCoreUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCoreUpgrade.s.sol";
import {DefaultCTMUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {UpgradeKind} from "deploy-scripts/upgrade/default-upgrade/UpgradeParams.sol";
import {Utils as DeployScriptUtils} from "deploy-scripts/utils/Utils.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {IEcosystemUpgradeOperation} from "contracts/upgrades/registry/objects/IEcosystemUpgradeOperation.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {ProxyUpgradeRow} from "contracts/upgrades/registry/RegistryTypes.sol";
import {
    CTMContract,
    L1EcosystemContract,
    L2_ECOSYSTEM_CONTRACT_COUNT
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

import {UpgradeIntegrationBootstrapFixture} from "./UpgradeTest_Local.t.sol";

/*//////////////////////////////////////////////////////////////
            THE VERSION SCRIPTS THE RECURRING HOPS RUN
//////////////////////////////////////////////////////////////*/

/// @notice The shared base of every recurring hop in this file: the real `DefaultCTMUpgrade`
///         pipeline with the two bytecode-table reads the local fixture cannot afford substituted,
///         plus read access to the objects the prepare deployed.
/// @dev The substitution is not a convenience: the fixture's LIVE release was pinned with the same
///      empty table (see `CTMUpgradeForLocalTest`), so a hop reading the real one would pin a
///      different manifest and publish a new release for a hop that changes nothing. Everything
///      this file tests — the declaration, the objects, the version and release invariants — runs
///      unmocked.
abstract contract RecurringCTMUpgradeForTests is DefaultCTMUpgrade {
    function getL2BytecodeInfoTable() internal pure override returns (bytes[] memory) {
        return new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT);
    }

    function getL2SystemProxyBytecodeInfo() internal pure override returns (bytes memory) {
        return "";
    }

    /// @notice The transition this prepare deployed, zero when it deployed none.
    function preparedTransition() external view returns (address) {
        return upgradeAddresses.ctmTransition;
    }

    /// @notice The operation this prepare deployed — what the coordinator's `execute` call names.
    function preparedOperation() external view returns (address) {
        return upgradeAddresses.ecosystemUpgradeOperation;
    }

    /// @notice The engine this prepare DEPLOYED, before any object pinned it — zero when the hop
    ///         deployed none. Distinct from `committedUpgradeEngine`, which reads the pin back.
    function preparedUpgradeEngine() external view returns (address) {
        return upgradeAddresses.upgradeEngine;
    }

    /// @notice Where `deploySimpleContract("DefaultUpgrade")` WOULD land this run, so a test can
    ///         assert that an infrastructure-only hop left that address codeless.
    function predictedUpgradeEngineAddress() external view returns (address) {
        (address factory, bytes32 salt) = getCreate2FactoryParams();
        bytes memory bytecode = abi.encodePacked(
            getCreationCode("DefaultUpgrade"),
            getCreationCalldata("DefaultUpgrade")
        );
        return vm.computeCreate2Address(salt, keccak256(bytecode), factory);
    }
}

/// @notice THE infrastructure-only hop: one fresh `ValidatorTimelock` implementation behind the
///         CTM-domain proxy, and nothing else. The DECLARATION is what makes it one — the version
///         numbers are held against it, never read to derive it.
contract CTMUpgradeValidatorTimelockOnly is RecurringCTMUpgradeForTests {
    function upgradeKind() public pure override returns (UpgradeKind) {
        return UpgradeKind.InfrastructureOnly;
    }

    function deployNewCTMContracts() public override {
        super.deployNewCTMContracts();
        ctmAddresses.stateTransition.implementations.validatorTimelock = deploySimpleContract("ValidatorTimelock");
    }
}

/// @notice A chain-release hop: a fresh verifier pair, which the release then pins and the
///         transition carries across a version edge. Nothing about the CTM-domain proxies moves.
contract CTMUpgradeVerifierRelease is RecurringCTMUpgradeForTests {
    function deployNewCTMContracts() public override {
        super.deployNewCTMContracts();
        deployVerifiers();
    }
}

/// @notice A MIXED hop: the infrastructure row of the first script and the release edge of the
///         second, in one operation.
contract CTMUpgradeMixed is RecurringCTMUpgradeForTests {
    function deployNewCTMContracts() public override {
        super.deployNewCTMContracts();
        deployVerifiers();
        ctmAddresses.stateTransition.implementations.validatorTimelock = deploySimpleContract("ValidatorTimelock");
    }
}

/// @notice A chain-release hop that changes no release member: every member is reused and only
///         the version moves.
contract CTMUpgradeVersionOnly is RecurringCTMUpgradeForTests {}

/// @notice An infrastructure-only hop that deploys nothing at all — the empty operation.
contract CTMUpgradeEmpty is RecurringCTMUpgradeForTests {
    function upgradeKind() public pure override returns (UpgradeKind) {
        return UpgradeKind.InfrastructureOnly;
    }
}

/// @notice An ORPHANED deployment: a fresh `PermissionlessValidator` implementation, which no row
///         builder installs and which the version does not name as deliberately uninstalled.
contract CTMUpgradeOrphanedDeployment is RecurringCTMUpgradeForTests {
    function upgradeKind() public pure override returns (UpgradeKind) {
        return UpgradeKind.InfrastructureOnly;
    }

    function deployNewCTMContracts() public override {
        super.deployNewCTMContracts();
        ctmAddresses.stateTransition.implementations.validatorTimelock = deploySimpleContract("ValidatorTimelock");
        ctmAddresses.stateTransition.implementations.permissionlessValidator = deploySimpleContract(
            "PermissionlessValidator"
        );
    }
}

/// @notice The ecosystem side of every hop in this file: none of them changes an ecosystem
///         singleton, so nothing is deployed and no `CoreTransition` exists for the operation to
///         name. That the CTM leg alone carries the change is the point.
contract CoreUpgradeNoEcosystemLeg is DefaultCoreUpgrade {}

/// @notice A core prepare whose local `L1MessageRoot` build differs from the live one (simulated:
///         the fixture's live code is this build) while the version declares no change.
contract CoreUpgradeUndeclaredChange is CoreUpgradeNoEcosystemLeg {
    function _canReuseEcosystemImplementation(string memory _name, address _live) internal override returns (bool) {
        if (keccak256(bytes(_name)) == keccak256(bytes("L1MessageRoot"))) {
            return false;
        }
        return super._canReuseEcosystemImplementation(_name, _live);
    }
}

/// @notice The same differing build, declared as this version's change.
contract CoreUpgradeDeclaredChange is CoreUpgradeUndeclaredChange {
    function changedEcosystemImplementations() internal pure override returns (string[] memory names) {
        names = new string[](1);
        names[0] = "L1MessageRoot";
    }
}

/// @notice The two ecosystem proxies that gained row builders last (`L1InteropHandler`,
///         `ChainRegistrationSender`), their local builds differing from the live ones (simulated:
///         the fixture's live code is this build) and declared as this version's changes.
contract CoreUpgradeDeclaredInteropAndRegistration is CoreUpgradeNoEcosystemLeg {
    function _canReuseEcosystemImplementation(string memory _name, address _live) internal override returns (bool) {
        if (_isOneOfTheTwo(_name)) {
            return false;
        }
        return super._canReuseEcosystemImplementation(_name, _live);
    }

    function changedEcosystemImplementations() internal pure override returns (string[] memory names) {
        names = new string[](2);
        names[0] = "L1InteropHandler";
        names[1] = "ChainRegistrationSender";
    }

    function _isOneOfTheTwo(string memory _name) private pure returns (bool) {
        bytes32 name = keccak256(bytes(_name));
        return name == keccak256(bytes("L1InteropHandler")) || name == keccak256(bytes("ChainRegistrationSender"));
    }
}

/// @notice The ecosystem counterpart of `CTMUpgradeOrphanedDeployment`: a fresh
///         `ChainRegistrationSender` implementation whose row builder this version script dropped —
///         the shape of a row builder nobody wrote, which the check exists to catch.
contract CoreUpgradeOrphanedDeployment is DefaultCoreUpgrade {
    function deployNewEcosystemContractsL1() public override {
        coreAddresses.bridgehub.implementations.chainRegistrationSender = deploySimpleContract(
            "ChainRegistrationSender"
        );
    }

    function _coreProxyUpgradeRows() internal view override returns (ProxyUpgradeRow[] memory rows) {
        rows = super._coreProxyUpgradeRows();
        delete rows[uint256(L1EcosystemContract.ChainRegistrationSender)];
    }
}

/*//////////////////////////////////////////////////////////////
                              TESTS
//////////////////////////////////////////////////////////////*/

/// @notice RECURRING prepares run through the real production pipeline, on the registry-driven
///         ecosystem the v35 bootstrap fixture leaves behind. The subject is what preparation can
///         EMIT: an infrastructure-only operation (the fleet-wide saving the model exists for — see
///         "Infrastructure-only operations" in {protocol-docs/ecosystem-upgrade-coordination.md}),
///         a chain-release one, a mixed one, and the shapes it must refuse.
/// @dev Everything here drives `DefaultCoreUpgrade`/`DefaultCTMUpgrade` themselves; the object
///      layer is covered separately by `RegistryIndividualUpgrade.t.sol`, which cannot show that
///      PREPARATION can produce these shapes.
contract UpgradeIntegrationTestRecurringLocal is UpgradeIntegrationBootstrapFixture {
    using stdToml for string;

    /// @dev The upgrade input whose `latest_protocol_version` EQUALS the version the bootstrap
    ///      left live: what an infrastructure-only hop must be given.
    string internal constant SAME_VERSION_INPUT = "/upgrade-envs/foundry-upgrade.toml";
    /// @dev The upgrade input naming the next minor: what a chain-release hop is given.
    string internal constant NEXT_VERSION_INPUT = "/upgrade-envs/foundry-upgrade-recurring.toml";
    /// @dev The upgrade input one minor past {NEXT_VERSION_INPUT}: a hop departing from the version
    ///      a first chain-release hop left the CTM at.
    string internal constant LAGGING_CHAINS_INPUT = "/upgrade-envs/foundry-upgrade-recurring-lagging.toml";

    /// @dev The version a chain-release hop targets: {NEXT_VERSION_INPUT}'s `latest_protocol_version`, read
    ///      rather than restated so the fixture inputs alone carry the version numbers.
    function _nextVersion() internal view returns (uint256) {
        return
            vm.readFile(string.concat(vm.projectRoot(), NEXT_VERSION_INPUT)).readUint(
                "$.contracts.latest_protocol_version"
            );
    }

    /// @dev Fresh per release, as production rotates the CREATE2 salt every release — without which
    ///      a redeployment of unchanged code lands back on the live address.
    bytes32 internal constant HOP_SALT = keccak256("recurring-hop");
    /// @dev The salt of a SECOND hop in one test, rotated like `HOP_SALT` between releases.
    bytes32 internal constant SECOND_HOP_SALT = keccak256("recurring-hop-2");

    /// @dev Everything an infrastructure-only operation must leave exactly as it found it.
    struct ChainFacingState {
        uint256 ctmProtocolVersion;
        address ctmCurrentRelease;
        uint256 chainProtocolVersion;
        uint256 departingVersionDeadline;
        address committedTransitionForDepartingVersion;
        bytes32 pendingL2UpgradeTxHash;
        address chainVerifier;
    }

    /// @dev What `protocol-ops` passes a recurring prepare, resolved once from the fixture.
    struct HopInputs {
        address bridgehub;
        address ctm;
        address rollupDAManager;
        address governance;
        address eip7702Checker;
    }

    HopInputs internal inputs;
    address internal coordinator;
    address internal governanceOwner;
    address internal chainAssetHandler;
    address internal validatorTimelockProxy;

    function setUp() public override {
        super.setUp();

        string memory root = vm.projectRoot();
        string memory deployL1 = vm.readFile(string.concat(root, ECOSYSTEM_INPUT));
        string memory deployCTM = vm.readFile(string.concat(root, CTM_INPUT));
        inputs = HopInputs({
            bridgehub: deployL1.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr"),
            ctm: ctmUpgrade.getCTMAddress(),
            rollupDAManager: deployCTM.readAddress("$.deployed_addresses.blobs_zksync_os_l1_da_validator_addr"),
            governance: deployL1.readAddress("$.deployed_addresses.governance_addr"),
            // Carried forward from the previous prepare's output, as the runbook requires: a fresh
            // checker changes the Mailbox's immutable and drags a facet cut behind it.
            eip7702Checker: ctmUpgrade.getAddresses().admin.eip7702Checker
        });

        coordinator = coreUpgrade.getEcosystemUpgradeExecutor();
        governanceOwner = IOwnable(coordinator).owner();
        chainAssetHandler = IBridgehubBase(inputs.bridgehub).chainAssetHandler();
        validatorTimelockProxy = ctmUpgrade.getAddresses().stateTransition.proxies.validatorTimelock;
    }

    // ───────────────────────────── happy paths ─────────────────────────────

    /// @notice THE gap this file closes: production preparation emits an operation with an
    ///         infrastructure row and NO transition, so a `ValidatorTimelock` swap costs no
    ///         protocol version. Proves, on the prepared package and then on chain: no transition
    ///         and no engine were deployed, the operation carries the row and nothing else, and
    ///         after the coordinator's `execute` nothing chain-facing has moved.
    function test_infrastructureOnlyPrepare_swapsOneProxyAndMovesNoVersion() public {
        CoreUpgradeNoEcosystemLeg core = new CoreUpgradeNoEcosystemLeg();
        RecurringCTMUpgradeForTests hop = new CTMUpgradeValidatorTimelockOnly();
        _prepareHop(core, hop, SAME_VERSION_INPUT, "recurring-infra-only");

        // ── No chain-version machinery was deployed at all ──
        assertEq(hop.preparedTransition(), address(0), "an infrastructure-only hop deploys no transition");
        assertEq(hop.preparedUpgradeEngine(), address(0), "an infrastructure-only hop deploys no upgrade engine");
        assertEq(hop.committedUpgradeEngine(), address(0), "no engine is committed, so none may be reported");
        assertEq(
            hop.predictedUpgradeEngineAddress().code.length,
            0,
            "nothing was deployed at the address an engine would have taken"
        );
        assertEq(hop.getChainUpgradeDiamondCutData().length, 0, "no chain crosses this edge, so there is no cut");
        assertEq(address(core.coreTransition()), address(0), "this hop changes no ecosystem singleton");
        assertEq(
            hop.getNewProtocolVersion(),
            hop.getOldProtocolVersion(),
            "the prepare's own view of the edge moves no version"
        );

        // ── The operation carries the row, and nothing else ──
        IEcosystemUpgradeOperation operation = IEcosystemUpgradeOperation(hop.preparedOperation());
        assertTrue(address(operation).code.length != 0, "the prepare must deploy an operation");
        assertEq(operation.ctmTransition(), address(0), "the operation names no transition");
        assertEq(operation.coreTransition(), address(0), "the operation names no core transition");

        ProxyUpgradeRow[] memory rows = operation.ctmInfrastructureRows();
        assertEq(rows.length, 1, "exactly one participating row");
        address implNew = hop.getAddresses().stateTransition.implementations.validatorTimelock;
        assertEq(rows[0].proxy, validatorTimelockProxy, "the row names the live timelock proxy");
        assertEq(rows[0].implNew, implNew, "the row names the implementation this run deployed");
        assertEq(
            rows[0].expectedOldImpl,
            DeployScriptUtils.getImplementation(validatorTimelockProxy),
            "the row departs from what the proxy runs today"
        );
        assertTrue(implNew != rows[0].expectedOldImpl, "the fixture must actually replace the implementation");

        // ── Execute it, and hold the whole chain-facing surface still ──
        ChainFacingState memory before = _snapshotChainFacing();
        _runOperation(operation);

        assertEq(
            DeployScriptUtils.getImplementation(validatorTimelockProxy),
            implNew,
            "the timelock proxy points at the new implementation"
        );
        _assertChainFacingUnchanged(before);
    }

    /// @notice A chain-release hop through the same pipeline still works: a fresh verifier is
    ///         pinned by a new release, a transition carries the version edge, and the engine that
    ///         composes each chain's cut is deployed and committed.
    function test_chainReleasePrepare_stillDeploysTheTransitionAndEngine() public {
        uint256 liveVersion = IChainTypeManager(inputs.ctm).protocolVersion();
        address liveRelease = IChainTypeManager(inputs.ctm).currentRelease();
        CoreUpgradeNoEcosystemLeg core = new CoreUpgradeNoEcosystemLeg();
        RecurringCTMUpgradeForTests hop = new CTMUpgradeVerifierRelease();
        _prepareHop(core, hop, NEXT_VERSION_INPUT, "recurring-release");

        address transition = hop.preparedTransition();
        assertTrue(transition != address(0), "a chain-release hop deploys a transition");
        assertTrue(hop.preparedUpgradeEngine() != address(0), "a chain-release hop deploys an upgrade engine");
        assertEq(hop.committedUpgradeEngine(), hop.preparedUpgradeEngine(), "the transition pins that engine");
        assertTrue(hop.getChainUpgradeDiamondCutData().length != 0, "chains crossing the edge take a cut");
        assertEq(
            ICTMTransition(transition).oldProtocolVersion(),
            liveVersion,
            "the edge departs from the live version"
        );
        assertEq(
            ICTMTransition(transition).newProtocolVersion(),
            _nextVersion(),
            "the edge targets the input's version"
        );
        assertTrue(ICTMTransition(transition).newRelease() != liveRelease, "a changed verifier publishes a release");

        IEcosystemUpgradeOperation operation = IEcosystemUpgradeOperation(hop.preparedOperation());
        assertEq(operation.ctmTransition(), transition, "the operation names the transition");
        assertEq(operation.ctmInfrastructureRows().length, 0, "this hop changes no CTM-domain proxy");

        _runOperation(operation);
        assertEq(IChainTypeManager(inputs.ctm).protocolVersion(), _nextVersion(), "the CTM committed the edge");
        assertEq(
            IChainTypeManager(inputs.ctm).currentRelease(),
            ICTMTransition(transition).newRelease(),
            "the CTM moved to the new release"
        );
    }

    /// @notice A MIXED hop: the same operation carries an infrastructure row AND a transition. The
    ///         two legs are independent, so both land.
    function test_mixedPrepare_carriesBothTheRowAndTheTransition() public {
        CoreUpgradeNoEcosystemLeg core = new CoreUpgradeNoEcosystemLeg();
        RecurringCTMUpgradeForTests hop = new CTMUpgradeMixed();
        _prepareHop(core, hop, NEXT_VERSION_INPUT, "recurring-mixed");

        IEcosystemUpgradeOperation operation = IEcosystemUpgradeOperation(hop.preparedOperation());
        address transition = hop.preparedTransition();
        ProxyUpgradeRow[] memory rows = operation.ctmInfrastructureRows();
        assertTrue(transition != address(0), "a mixed hop still deploys its transition");
        assertEq(operation.ctmTransition(), transition, "the operation names it");
        assertEq(rows.length, 1, "and carries the infrastructure row beside it");
        assertEq(rows[0].proxy, validatorTimelockProxy, "the row names the timelock proxy");

        _runOperation(operation);

        assertEq(
            DeployScriptUtils.getImplementation(validatorTimelockProxy),
            rows[0].implNew,
            "the infrastructure leg landed"
        );
        assertEq(IChainTypeManager(inputs.ctm).protocolVersion(), _nextVersion(), "the version leg landed");
    }

    /// @notice Discovery reads a registry-era CTM's release members off its `currentRelease`, not
    ///         off "a chain at the CTM's version": once an edge is committed, no chain need be at
    ///         that version yet. A prepare against such a CTM reuses every live member and builds a
    ///         valid release over them, which the CTM then installs.
    function test_prepareWhileEveryChainLags_reusesTheLiveReleaseMembers() public {
        // A first hop commits the next version; no chain follows it.
        RecurringCTMUpgradeForTests firstHop = new CTMUpgradeVerifierRelease();
        _prepareHop(new CoreUpgradeNoEcosystemLeg(), firstHop, NEXT_VERSION_INPUT, "recurring-lagging-first");
        _runOperation(IEcosystemUpgradeOperation(firstHop.preparedOperation()));
        uint256 ctmVersion = IChainTypeManager(inputs.ctm).protocolVersion();
        assertEq(ctmVersion, _nextVersion(), "the first hop moved the CTM");
        address[] memory chains = IBridgehubBase(inputs.bridgehub).getAllZKChains();
        assertTrue(chains.length != 0, "the fixture must have chains");
        for (uint256 i = 0; i < chains.length; ++i) {
            assertTrue(IGetters(chains[i]).getProtocolVersion() < ctmVersion, "every chain lags the CTM");
        }
        ICTMRelease liveRelease = ICTMRelease(IChainTypeManager(inputs.ctm).currentRelease());

        RecurringCTMUpgradeForTests secondHop = new CTMUpgradeVersionOnly();
        _prepareHopWithSalt(
            new CoreUpgradeNoEcosystemLeg(),
            secondHop,
            LAGGING_CHAINS_INPUT,
            "recurring-lagging-second",
            SECOND_HOP_SALT
        );

        // ── Every member of the new release is the live release's ──
        ICTMRelease newRelease = ICTMRelease(secondHop.getAddresses().stateTransition.currentRelease);
        assertTrue(address(newRelease) != address(liveRelease), "a version bump pins a release of its own");
        newRelease.validate();
        assertEq(
            keccak256(abi.encode(newRelease.genesisFacets())),
            keccak256(abi.encode(liveRelease.genesisFacets())),
            "every facet row, freezability included, is the live one"
        );
        assertEq(newRelease.diamondInit(), liveRelease.diamondInit(), "DiamondInit reused");
        assertEq(newRelease.verifier(), liveRelease.verifier(), "verifier reused");
        (address newEngine, , ) = newRelease.genesisParams();
        (address liveEngine, , ) = liveRelease.genesisParams();
        assertEq(newEngine, liveEngine, "genesis engine reused");

        ICTMTransition transition = ICTMTransition(secondHop.preparedTransition());
        assertEq(transition.fromRelease(), address(liveRelease), "the edge departs from the live release");
        assertEq(transition.facetCuts().length, 0, "reusing every facet derives no facet cut");

        // ── The CTM installs it ──
        _runOperation(IEcosystemUpgradeOperation(secondHop.preparedOperation()));
        assertEq(
            IChainTypeManager(inputs.ctm).protocolVersion(),
            newRelease.protocolVersion(),
            "the CTM committed the edge"
        );
        assertEq(IChainTypeManager(inputs.ctm).currentRelease(), address(newRelease), "and installed the release");
    }

    // ───────────────────────────── ecosystem implementations and the coordinator ─────────────

    /// @notice The base core prepare deploys only what differs from the live code: on an ecosystem
    ///         already running this build it reuses every implementation and pins no core leg.
    function test_corePrepare_reusesEveryUnchangedImplementation() public {
        CoreUpgradeNoEcosystemLeg core = new CoreUpgradeNoEcosystemLeg();
        core.initializeWithArgs(
            inputs.bridgehub,
            HOP_SALT,
            SAME_VERSION_INPUT,
            "/script-out/foundry-upgrade/recurring-core-reuse-core.toml"
        );
        core.prepareEcosystemUpgrade();

        assertEq(address(core.coreTransition()), address(0), "nothing changed, so there is no core leg");
        address messageRootProxy = core.getDiscoveredBridgehub().proxies.messageRoot;
        assertEq(
            core.getDiscoveredBridgehub().implementations.messageRoot,
            DeployScriptUtils.getImplementation(messageRootProxy),
            "the live implementation is reused"
        );
        address senderProxy = core.getDiscoveredBridgehub().proxies.chainRegistrationSender;
        assertEq(
            core.getDiscoveredBridgehub().implementations.chainRegistrationSender,
            DeployScriptUtils.getImplementation(senderProxy),
            "the live ChainRegistrationSender is reused"
        );
    }

    /// @notice `L1InteropHandler` and `ChainRegistrationSender` are installable like every other
    ///         ecosystem singleton: declared and differing, each is deployed, pinned as a row departing
    ///         from its live implementation, and swapped by the core executor when the operation
    ///         executes.
    function test_corePrepare_installsTheInteropHandlerAndRegistrationSender() public {
        CoreUpgradeDeclaredInteropAndRegistration core = new CoreUpgradeDeclaredInteropAndRegistration();
        RecurringCTMUpgradeForTests hop = new CTMUpgradeEmpty();
        _prepareHop(core, hop, SAME_VERSION_INPUT, "recurring-core-interop-registration");

        address senderProxy = IBridgehubBase(inputs.bridgehub).chainRegistrationSender();
        address interopHandlerProxy = core.getDiscoveredBridges().proxies.l1InteropHandler;
        assertTrue(interopHandlerProxy != address(0), "the fixture has an L1 interop handler proxy");
        ProxyUpgradeRow[] memory rows = core.coreTransition().ecosystemRows();
        assertEq(rows.length, 2, "exactly the two declared replacements");
        address[2] memory proxies = [interopHandlerProxy, senderProxy];
        address[2] memory implsNew = [
            core.getDiscoveredBridges().implementations.l1InteropHandler,
            core.getDiscoveredBridgehub().implementations.chainRegistrationSender
        ];
        for (uint256 i = 0; i < 2; ++i) {
            assertEq(rows[i].proxy, proxies[i], "rows follow the inventory order");
            assertEq(rows[i].expectedOldImpl, DeployScriptUtils.getImplementation(proxies[i]), "from live");
            assertEq(rows[i].implNew, implsNew[i], "to this run's deployment");
            assertTrue(rows[i].implNew != rows[i].expectedOldImpl, "a real replacement");
        }

        _runOperation(IEcosystemUpgradeOperation(hop.preparedOperation()));
        for (uint256 i = 0; i < 2; ++i) {
            assertEq(DeployScriptUtils.getImplementation(proxies[i]), implsNew[i], "the core executor swapped it");
        }
    }

    /// @notice A replacement the version did not declare is refused: it is either an unintended
    ///         scope change or a local build that differs from the one that produced the live code.
    function test_corePrepare_refusesAnUndeclaredReplacement() public {
        CoreUpgradeUndeclaredChange core = new CoreUpgradeUndeclaredChange();
        core.initializeWithArgs(
            inputs.bridgehub,
            HOP_SALT,
            SAME_VERSION_INPUT,
            "/script-out/foundry-upgrade/recurring-core-undeclared-core.toml"
        );
        vm.expectRevert(
            bytes(
                "ecosystem implementation 'L1MessageRoot' would be replaced but this version does not declare it "
                "as changed. Either add it to `changedEcosystemImplementations()`, or the local build differs from "
                "the one that produced the live code."
            )
        );
        core.prepareEcosystemUpgrade();
    }

    /// @notice A declared replacement is deployed and pinned as the core leg's only row, departing
    ///         from what the proxy runs today; every undeclared implementation is reused.
    function test_corePrepare_deploysAndInstallsADeclaredReplacement() public {
        CoreUpgradeDeclaredChange core = new CoreUpgradeDeclaredChange();
        core.initializeWithArgs(
            inputs.bridgehub,
            HOP_SALT,
            SAME_VERSION_INPUT,
            "/script-out/foundry-upgrade/recurring-core-declared-core.toml"
        );
        core.prepareEcosystemUpgrade();

        assertTrue(address(core.coreTransition()) != address(0), "the declared change is a core leg");
        ProxyUpgradeRow[] memory rows = core.coreTransition().ecosystemRows();
        address messageRootProxy = core.getDiscoveredBridgehub().proxies.messageRoot;
        assertEq(rows.length, 1, "the one declared replacement is the only row");
        assertEq(rows[0].proxy, messageRootProxy, "on the message root's proxy");
        assertEq(rows[0].expectedOldImpl, DeployScriptUtils.getImplementation(messageRootProxy), "from live");
        assertEq(rows[0].implNew, core.getDiscoveredBridgehub().implementations.messageRoot, "to this run's");
        assertTrue(rows[0].implNew != rows[0].expectedOldImpl, "a real replacement");
    }

    /// @notice A recurring CTM prepare derives the coordinator from the CTM (its owner is the bound
    ///         executor, which names the coordinator) and ignores the coordinator input, which only
    ///         the bootstrap edge reads.
    function test_recurringPrepare_derivesTheCoordinatorFromTheCTM() public {
        CoreUpgradeNoEcosystemLeg core = new CoreUpgradeNoEcosystemLeg();
        RecurringCTMUpgradeForTests hop = new CTMUpgradeValidatorTimelockOnly();
        _initHop(core, hop, SAME_VERSION_INPUT, "recurring-derived-coordinator");
        hop.setEcosystemUpgradeExecutor(makeAddr("staleCoordinatorInput"));
        _finishPrepare(core, hop);

        assertEq(hop.upgradeCoordinator(), coordinator, "the coordinator the CTM's executor answers to");
        string memory output = vm.readFile(
            string.concat(vm.projectRoot(), "/script-out/foundry-upgrade/recurring-derived-coordinator-ctm.toml")
        );
        assertEq(output.readAddress("$.registry.coordinator_addr"), coordinator, "and the output names it");
        _runOperation(IEcosystemUpgradeOperation(hop.preparedOperation()));
    }

    // ───────────────────────────── refusals ─────────────────────────────

    /// @notice An operation that changes nothing is refused at PREPARATION, where the message can
    ///         name the three legs — not only by the object's constructor, whose revert reaches
    ///         the operator as an opaque CREATE2 factory failure.
    function test_emptyOperation_isRefusedAtPreparation() public {
        CoreUpgradeNoEcosystemLeg core = new CoreUpgradeNoEcosystemLeg();
        RecurringCTMUpgradeForTests hop = new CTMUpgradeEmpty();
        _initHop(core, hop, SAME_VERSION_INPUT, "recurring-empty");
        core.prepareEcosystemUpgrade();
        assertEq(address(core.coreTransition()), address(0), "the fixture must leave the ecosystem leg empty");
        hop.setCoreTransition(address(core.coreTransition()));

        vm.expectRevert("this upgrade changes nothing: no core transition, no infrastructure row and no transition");
        hop.prepareCTMUpgrade();
    }

    /// @notice The KIND is declared, so the version numbers are checked against it. An
    ///         infrastructure-only script handed an input that names another version is a
    ///         contradiction — the prepare must refuse it, not quietly prepare a release upgrade.
    function test_infrastructureOnlyDeclaration_refusesAVersionMovingInput() public {
        RecurringCTMUpgradeForTests hop = new CTMUpgradeEmpty();
        vm.expectRevert(
            bytes(
                string.concat(
                    "an infrastructure-only upgrade must not move the protocol version: the input names ",
                    vm.toString(_nextVersion()),
                    " and the ChainTypeManager runs ",
                    vm.toString(IChainTypeManager(inputs.ctm).protocolVersion())
                )
            )
        );
        _initCTMHop(hop, NEXT_VERSION_INPUT, "recurring-moving");
    }

    /// @notice The mirror image, and the reason the declaration exists: a CHAIN-RELEASE script
    ///         whose input forgot to move the version is refused too. Were the kind inferred from
    ///         the numbers, this run would silently become an infrastructure-only upgrade.
    function test_chainReleaseDeclaration_refusesAnUnmovedVersion() public {
        RecurringCTMUpgradeForTests hop = new CTMUpgradeVerifierRelease();
        vm.expectRevert("The new protocol version is already present on the ChainTypeManager");
        _initCTMHop(hop, SAME_VERSION_INPUT, "recurring-unmoved");
    }

    /// @notice The general control: a replacement this run deploys that no row installs is refused
    ///         at preparation. `PermissionlessValidator` has no row builder today, so deploying an
    ///         implementation for it produces an address the operation never references.
    function test_orphanedDeployment_isRefusedAtPreparation() public {
        CoreUpgradeNoEcosystemLeg core = new CoreUpgradeNoEcosystemLeg();
        RecurringCTMUpgradeForTests hop = new CTMUpgradeOrphanedDeployment();
        _initHop(core, hop, SAME_VERSION_INPUT, "recurring-orphan");
        core.prepareEcosystemUpgrade();
        hop.setCoreTransition(address(core.coreTransition()));

        // The message names the slot and the address so the operator can tell which of the two
        // fixes applies. The address is only known inside the reverted call, so the assertion runs
        // up to it — far enough to prove the diagnostic names the right inventory slot.
        string memory expected = string.concat(
            "orphaned CTM-domain deployment at inventory slot ",
            vm.toString(uint256(CTMContract.PermissionlessValidator)),
            " ("
        );
        try hop.prepareCTMUpgrade() {
            revert("the prepare accepted an orphaned deployment");
        } catch Error(string memory reason) {
            assertEq(_prefix(reason, bytes(expected).length), expected, string.concat("unexpected revert: ", reason));
        }
    }

    /// @notice The same control on the ECOSYSTEM side: a fresh `ChainRegistrationSender`
    ///         implementation that `_coreProxyUpgradeRows()` leaves without a row is refused rather
    ///         than written to an output key nothing reads.
    function test_orphanedEcosystemDeployment_isRefusedAtPreparation() public {
        CoreUpgradeOrphanedDeployment core = new CoreUpgradeOrphanedDeployment();
        core.initializeWithArgs(
            inputs.bridgehub,
            HOP_SALT,
            SAME_VERSION_INPUT,
            "/script-out/foundry-upgrade/recurring-core-orphan-core.toml"
        );

        string memory expected = string.concat(
            "orphaned ecosystem deployment at inventory slot ",
            vm.toString(uint256(L1EcosystemContract.ChainRegistrationSender)),
            " ("
        );
        try core.prepareEcosystemUpgrade() {
            revert("the prepare accepted an orphaned ecosystem deployment");
        } catch Error(string memory reason) {
            assertEq(_prefix(reason, bytes(expected).length), expected, string.concat("unexpected revert: ", reason));
        }
    }

    // ───────────────────────────── helpers ─────────────────────────────

    /// @dev Initializes the CTM side of a hop against the live (post-bootstrap) ecosystem exactly
    ///      as `protocol-ops` does. Kept separate from `_initHop` so a test can put
    ///      `vm.expectRevert` immediately before THIS call.
    function _initCTMHop(
        RecurringCTMUpgradeForTests _hop,
        string memory _input,
        string memory _outName
    ) internal returns (RecurringCTMUpgradeForTests) {
        return _initCTMHopWithSalt(_hop, _input, _outName, HOP_SALT);
    }

    function _initCTMHopWithSalt(
        RecurringCTMUpgradeForTests _hop,
        string memory _input,
        string memory _outName,
        bytes32 _salt
    ) internal returns (RecurringCTMUpgradeForTests) {
        // solhint-disable-next-line func-named-parameters
        _hop.initializeWithArgs(
            inputs.ctm,
            inputs.rollupDAManager,
            _salt,
            _input,
            string.concat("/script-out/foundry-upgrade/", _outName, "-ctm.toml"),
            inputs.governance,
            bytes32(uint256(1)),
            true
        );
        _hop.setEIP7702Checker(inputs.eip7702Checker);
        return _hop;
    }

    function _initHop(
        CoreUpgradeNoEcosystemLeg _core,
        RecurringCTMUpgradeForTests _hop,
        string memory _input,
        string memory _outName
    ) internal {
        _core.initializeWithArgs(
            inputs.bridgehub,
            HOP_SALT,
            _input,
            string.concat("/script-out/foundry-upgrade/", _outName, "-core.toml")
        );
        _initCTMHop(_hop, _input, _outName);
    }

    /// @dev `_initHop` plus both prepares, wired the way the CLI wires them: the core prepare's
    ///      coordinator and registry are the CTM prepare's inputs.
    function _prepareHop(
        CoreUpgradeNoEcosystemLeg _core,
        RecurringCTMUpgradeForTests _hop,
        string memory _input,
        string memory _outName
    ) internal {
        _initHop(_core, _hop, _input, _outName);
        _finishPrepare(_core, _hop);
    }

    /// @dev {_prepareHop} under `_salt` for both prepares.
    function _prepareHopWithSalt(
        CoreUpgradeNoEcosystemLeg _core,
        RecurringCTMUpgradeForTests _hop,
        string memory _input,
        string memory _outName,
        bytes32 _salt
    ) internal {
        _core.initializeWithArgs(
            inputs.bridgehub,
            _salt,
            _input,
            string.concat("/script-out/foundry-upgrade/", _outName, "-core.toml")
        );
        _initCTMHopWithSalt(_hop, _input, _outName, _salt);
        _finishPrepare(_core, _hop);
    }

    function _finishPrepare(CoreUpgradeNoEcosystemLeg _core, RecurringCTMUpgradeForTests _hop) internal {
        _core.prepareEcosystemUpgrade();
        _hop.setCoreTransition(address(_core.coreTransition()));
        _hop.prepareCTMUpgrade();
    }

    /// @dev The one governance call a registry-driven upgrade emits, and nothing else.
    function _runOperation(IEcosystemUpgradeOperation _operation) internal {
        bool pausedBefore = IChainAssetHandlerBase(chainAssetHandler).migrationPausedFor(inputs.ctm);
        vm.prank(governanceOwner);
        EcosystemUpgradeExecutor(payable(coordinator)).execute(_operation);
        assertEq(
            IChainAssetHandlerBase(chainAssetHandler).migrationPausedFor(inputs.ctm),
            pausedBefore,
            "an operation neither takes nor lifts a migration pause"
        );
    }

    function _snapshotChainFacing() internal view returns (ChainFacingState memory state) {
        uint256 liveVersion = IChainTypeManager(inputs.ctm).protocolVersion();
        state.ctmProtocolVersion = liveVersion;
        state.ctmCurrentRelease = IChainTypeManager(inputs.ctm).currentRelease();
        state.chainProtocolVersion = IGetters(_eraDiamond).getProtocolVersion();
        state.departingVersionDeadline = IChainTypeManager(inputs.ctm).protocolVersionDeadline(liveVersion);
        state.committedTransitionForDepartingVersion = IChainTypeManager(inputs.ctm).upgradeTransition(liveVersion);
        state.pendingL2UpgradeTxHash = IGetters(_eraDiamond).getL2SystemContractsUpgradeTxHash();
        state.chainVerifier = address(IGetters(_eraDiamond).getVerifier());
    }

    function _assertChainFacingUnchanged(ChainFacingState memory _before) internal view {
        assertEq(
            IChainTypeManager(inputs.ctm).protocolVersion(),
            _before.ctmProtocolVersion,
            "the CTM protocol version must not move"
        );
        assertEq(
            IChainTypeManager(inputs.ctm).currentRelease(),
            _before.ctmCurrentRelease,
            "the release pointer must not move"
        );
        assertEq(IGetters(_eraDiamond).getProtocolVersion(), _before.chainProtocolVersion, "no chain version may move");
        assertEq(
            IChainTypeManager(inputs.ctm).protocolVersionDeadline(_before.ctmProtocolVersion),
            _before.departingVersionDeadline,
            "no adoption deadline may move"
        );
        assertEq(
            IChainTypeManager(inputs.ctm).upgradeTransition(_before.ctmProtocolVersion),
            _before.committedTransitionForDepartingVersion,
            "no transition may be committed"
        );
        assertEq(
            IGetters(_eraDiamond).getL2SystemContractsUpgradeTxHash(),
            _before.pendingL2UpgradeTxHash,
            "a pending L2 upgrade must survive untouched"
        );
        assertEq(address(IGetters(_eraDiamond).getVerifier()), _before.chainVerifier, "the verifier is untouched");
    }

    function _prefix(string memory _value, uint256 _length) private pure returns (string memory) {
        bytes memory raw = bytes(_value);
        if (raw.length < _length) {
            return _value;
        }
        bytes memory out = new bytes(_length);
        for (uint256 i = 0; i < _length; ++i) {
            out[i] = raw[i];
        }
        return string(out);
    }
}
