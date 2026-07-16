// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "../../state-transition/ChainTypeManager/_ChainTypeManager_Shared.t.sol";
import {ZKsyncOSChainTypeManagerSharedTest} from "../../state-transition/ChainTypeManager/_ZKsyncOSChainTypeManager_Shared.t.sol";
import {Call} from "contracts/governance/Common.sol";
import {UpgradeExecutor} from "contracts/governance/UpgradeExecutor.sol";
import {CTMUpgradeModule} from "contracts/upgrades/registry/CTMUpgradeModule.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/CTMUpgradeComposer.sol";
import {CTMRelease} from "contracts/upgrades/registry/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/CTMTransition.sol";
import {ICTMTransition, L2Deployment} from "contracts/upgrades/registry/ICTMTransition.sol";
import {GenesisFacet} from "contracts/upgrades/registry/ICTMRelease.sol";
import {L2EcosystemContract, CodehashPin} from "contracts/upgrades/registry/ContractIdentifiers.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {UpgradeFacetSwap} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {
    PRIORITY_TX_MAX_GAS_LIMIT,
    SYSTEM_UPGRADE_L2_TX_TYPE,
    ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE
} from "contracts/common/Config.sol";
import {ProtocolIdMismatch} from "contracts/common/L1ContractErrors.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";

/// @notice The first full registry-driven upgrade, end to end: a real chain diamond is taken
///         v32 -> v33 entirely through `UpgradeExecutor` -> `CTMUpgradeModule`, with every
///         payload composed from registry constants and actually EXECUTED (facet cuts applied,
///         the real `DefaultUpgrade` init delegatecalled, the L2 protocol upgrade transaction
///         committed on the chain).
/// @dev Abstract over the VM: the same two hops run against an Era CTM/chain
///      (`RegistryDrivenUpgradeEraTest`) and a ZKsyncOS CTM/chain
///      (`RegistryDrivenUpgradeZKsyncOSTest`). The virtual hooks below pin down every
///      per-VM difference: the fixture, the registry's `isZKsyncOS` flag, the L2 upgrade-tx
///      type the chain must commit, the force-deployment flavor and the genesis params the CTM
///      accepts.
/// @dev The fixture chain starts at protocol version 0, so "v32" is reached by a first
///      registry-driven hop (0.0.0 -> 0.32.0, L1-only: no facet changes, no L2 transaction, new
///      verifier). The second hop (0.32.0 -> 0.33.0) is the full minor upgrade: a real facet
///      replacement plus the composed L2 protocol upgrade transaction (nonce = 33). Two hops
///      also prove consecutive registry-driven upgrades sequence correctly.
/// @dev The registry is a storage-backed double (fixture addresses are dynamic), but everything
///      it pins here is real: live facet addresses/selectors, a real replacement `AdminFacet`,
///      the real `DefaultUpgrade`, real verifier contracts.
abstract contract RegistryDrivenUpgradeTestBase is ChainTypeManagerTest {
    UpgradeExecutor internal ctmExecutor;
    CTMUpgradeModule internal module;
    CTMTransition internal transitionV32;
    CTMTransition internal transitionV33;

    address internal chainAddress;
    address internal newAdminFacet;
    address internal verifierV32;
    address internal verifierV33;
    address internal defaultUpgrade;

    uint256 internal constant V32 = uint256(32) << 32; // 0.32.0
    uint256 internal constant V33 = uint256(33) << 32; // 0.33.0

    // ---------------------------------------------------------------------------------------
    // Per-VM hooks
    // ---------------------------------------------------------------------------------------

    /// @dev Deploys the CTM fixture (ecosystem + ChainTypeManager) for the VM under test.
    function _deployFixture() internal virtual;

    /// @dev The registry's `isZKsyncOS()` flag; it selects the composed L2 upgrade-tx type.
    function _isZKsyncOSVariant() internal pure virtual returns (bool);

    /// @dev The L2 upgrade-transaction type the chain must commit for this VM.
    function _expectedL2UpgradeTxType() internal pure virtual returns (uint256);

    /// @dev The force-deployment flavor the registry pins for the L2 side of the upgrade.
    function _l2DeploymentType() internal pure virtual returns (IComplexUpgrader.ContractUpgradeType);

    /// @dev The pinned `deployedBytecodeInfo` — opaque on L1 (only decoded on L2), so any
    ///      VM-shaped payload is enough here.
    function _l2DeployedBytecodeInfo() internal pure virtual returns (bytes memory);

    /// @dev The `genesisBatchCommitment` the registry pins in its genesis params —
    ///      `applyCTMUpgrade` feeds it to `setChainCreationParams`, which ZKsyncOS CTMs only
    ///      accept as exactly `bytes32(uint256(1))`.
    function _registryGenesisBatchCommitment() internal pure virtual returns (bytes32);

    // ---------------------------------------------------------------------------------------
    // Shared fixture
    // ---------------------------------------------------------------------------------------

    function setUp() public {
        _deployFixture();
        // Fixture sanity: the CTM under test must match the VM variant. The chain-side
        // `s.zksyncOS` flag is asserted end-to-end below — the chain only accepts the upgrade
        // transaction type of its own VM (`InvalidTxType` otherwise).
        assertEq(
            IChainTypeManager(address(chainContractAddress)).isZKsyncOS(),
            _isZKsyncOSVariant(),
            "fixture must deploy the CTM of the VM under test"
        );
        chainAddress = createNewChain(getDiamondCutData(diamondInit));
        _mockGetZKChainFromBridgehub(chainAddress);
        _mockMigrationPausedFromBridgehub();

        module = new CTMUpgradeModule();
        ctmExecutor = new UpgradeExecutor(governor);

        // Real v33 artifacts: a fresh AdminFacet implementation (same selectors, new address)
        // and the plain DefaultUpgrade as the upgrade-init contract.
        newAdminFacet = address(new AdminFacet(block.chainid, RollupDAManager(address(0))));
        defaultUpgrade = address(new DefaultUpgrade());
        verifierV32 = address(new EraTestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));
        verifierV33 = address(new EraTestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));

        // Hand CTM ownership to the executor (acceptOwnership through the escape hatch) and
        // raise the chain's priority-tx gas limit to fit the composed upgrade transaction —
        // both raw calls a real handover/preparation would ship.
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(ctmExecutor));
        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(chainContractAddress.acceptOwnership, ())
        });
        calls[1] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(IChainTypeManager.setPriorityTxMaxGasLimit, (chainId, PRIORITY_TX_MAX_GAS_LIMIT))
        });
        vm.prank(governor);
        ctmExecutor.forward(calls);

        // The chain's genesis upgrade transaction is still pending: on a real chain the server
        // finalizes it by executing the first batch, which is out of scope for an L1 unit test.
        // Clearing it via the UtilsFacet simulates exactly that batch execution; without it any
        // subsequent minor upgrade correctly reverts with PreviousUpgradeNotFinalized.
        UtilsFacet(chainAddress).util_setL2SystemContractsUpgradeTxHash(bytes32(0));

        // The first hop departs from the fixture CTM's genesis (current) release; V33 then
        // transitions from the V32 release the first hop pinned.
        transitionV32 = _makeTransition(0, V32, verifierV32, chainContractAddress.currentRelease(), address(0));
        transitionV33 = _makeTransition(V32, V33, verifierV33, transitionV32.newRelease(), newAdminFacet);
    }

    /// @dev Builds a registry for one hop. When `_newAdminFacet` is zero the AdminFacet is
    ///      unchanged by the hop, so it appears on the new side only (no old row — an EMPTY
    ///      facet plan -> L1-only upgrade with empty cuts); otherwise the plan holds exactly one
    ///      row replacing the chain's REAL AdminFacet by the given implementation. A non-zero
    ///      `_newAdminFacet` hop also carries an L2 force-deployment, making it a full minor
    ///      upgrade.
    function _makeTransition(
        uint256 _oldVersion,
        uint256 _newVersion,
        address _verifier,
        address _fromRelease,
        address _newAdminFacet
    ) internal returns (CTMTransition transition) {
        address liveAdminFacet = facetCuts[1].facet;
        bytes4[] memory adminSelectors = Utils.getAdminSelectors();
        GenesisFacet[] memory genesisFacets = new GenesisFacet[](1);
        genesisFacets[0] = GenesisFacet({
            facet: _newAdminFacet == address(0) ? liveAdminFacet : _newAdminFacet,
            isFreezable: false,
            selectors: _newAdminFacet == address(0) ? adminSelectors : new bytes4[](0)
        });
        CTMRelease release = new CTMRelease();
        release.initialize(
            CTMRelease.ReleaseManifest({
                isZKsyncOS: _isZKsyncOSVariant(),
                diamondInit: diamondInit,
                genesisFacets: genesisFacets,
                bootloaderHash: bytes32(0),
                defaultAccountHash: bytes32(0),
                evmEmulatorHash: bytes32(0),
                fixedForceDeploymentsData: hex"f1f2",
                genesisUpgrade: makeAddr("genesisUpgrade"),
                genesisBatchHash: bytes32(uint256(1)),
                genesisBatchCommitment: _registryGenesisBatchCommitment(),
                genesisIndexRepeatedStorageChanges: 54,
                codehashPins: new CodehashPin[](0)
            })
        );

        UpgradeFacetSwap[] memory facetTransitions = new UpgradeFacetSwap[](_newAdminFacet == address(0) ? 0 : 1);
        if (_newAdminFacet != address(0)) {
            facetTransitions[0] = UpgradeFacetSwap({
                oldFacet: liveAdminFacet,
                newFacet: _newAdminFacet,
                isFreezable: false,
                oldSelectors: adminSelectors,
                newSelectors: new bytes4[](0)
            });
        }

        L2Deployment[] memory deployments = new L2Deployment[](_newAdminFacet == address(0) ? 0 : 1);

        if (_newAdminFacet != address(0)) {
            deployments[0] = L2Deployment({
                key: L2EcosystemContract.L2Bridgehub,
                info: IComplexUpgrader.UniversalContractUpgradeInfo({
                    upgradeType: _l2DeploymentType(),
                    deployedBytecodeInfo: _l2DeployedBytecodeInfo(),
                    newAddress: makeAddr("l2Bridgehub")
                }),
                bytecodeHash: bytes32(uint256(0x0100000000000000000000000000000000000000000000000000000000000001))
            });
        }

        transition = new CTMTransition();
        transition.initialize(
            CTMTransition.TransitionManifest({
                ctmProxy: address(chainContractAddress),
                oldProtocolVersion: _oldVersion,
                newProtocolVersion: _newVersion,
                verifier: _verifier,
                fromRelease: _fromRelease,
                newRelease: address(release),
                defaultUpgrade: defaultUpgrade,
                oldProtocolVersionDeadline: 1000,
                upgradeTimestamp: 0,
                facetTransitions: facetTransitions,
                l2Deployments: deployments,
                l2UpgradeDelegateTo: address(0),
                l2UpgradeDelegateCalldata: hex"",
                factoryDepHashes: new uint256[](0),
                bootloaderHash: bytes32(0),
                defaultAccountHash: bytes32(0),
                evmEmulatorHash: bytes32(0),
                codehashPins: new CodehashPin[](0)
            })
        );
    }

    function _runHop(CTMTransition _transition) internal {
        vm.startPrank(governor);
        ctmExecutor.execute(
            address(module),
            abi.encodeCall(CTMUpgradeModule.applyCTMUpgrade, (ICTMTransition(address(_transition))))
        );
        ctmExecutor.execute(
            address(module),
            abi.encodeCall(CTMUpgradeModule.upgradeChain, (ICTMTransition(address(_transition)), chainId))
        );
        vm.stopPrank();
    }

    function test_registryDrivenUpgrade_v32ThenV33_endToEnd() public {
        // Hop 1 (0.0.0 -> 0.32.0): L1-only registry-driven upgrade — no facet changes, no L2
        // transaction, new verifier. The cut executes on the real chain with the real
        // DefaultUpgrade init.
        _runHop(transitionV32);

        assertEq(chainContractAddress.protocolVersion(), V32, "hop 1 must bump the CTM to v32");
        assertEq(IGetters(chainAddress).getProtocolVersion(), V32, "hop 1 must bump the chain to v32");
        assertEq(address(IGetters(chainAddress).getVerifier()), verifierV32, "hop 1 must install the v32 verifier");
        assertEq(
            IGetters(chainAddress).getL2SystemContractsUpgradeTxHash(),
            bytes32(0),
            "an L1-only upgrade must not set an L2 upgrade transaction"
        );

        // Hop 2 (0.32.0 -> 0.33.0): the full minor upgrade — AdminFacet actually replaced and
        // the composed L2 protocol upgrade transaction (nonce = 33) committed on the chain.
        _runHop(transitionV33);

        assertEq(chainContractAddress.protocolVersion(), V33, "hop 2 must bump the CTM to v33");
        assertEq(IGetters(chainAddress).getProtocolVersion(), V33, "hop 2 must bump the chain to v33");
        (, uint32 minor, ) = SemVer.unpackSemVer(uint96(V33));
        assertEq(minor, 33);
        assertEq(address(IGetters(chainAddress).getVerifier()), verifierV33, "hop 2 must install the v33 verifier");
        assertEq(
            IGetters(chainAddress).facetAddress(IAdmin.acceptAdmin.selector),
            newAdminFacet,
            "the AdminFacet must be re-pointed to the v33 implementation"
        );

        // The committed L2 upgrade transaction is exactly the registry-composed one, carrying
        // the VM's upgrade-transaction type (254 for Era, 126 for ZKsyncOS).
        L2CanonicalTransaction memory expectedTx = CTMUpgradeComposer.buildL2UpgradeTx(
            ICTMTransition(address(transitionV33))
        );
        assertEq(expectedTx.txType, _expectedL2UpgradeTxType(), "the upgrade tx must carry the VM's upgrade tx type");
        assertEq(expectedTx.nonce, 33, "upgrade tx nonce must equal the new minor version");
        assertEq(
            IGetters(chainAddress).getL2SystemContractsUpgradeTxHash(),
            keccak256(abi.encode(expectedTx)),
            "the chain must commit the registry-composed L2 upgrade transaction"
        );
    }

    function test_revertWhen_hopReplayed() public {
        _runHop(transitionV32);

        // Replaying the chain upgrade of a completed hop fails the chain's own version check.
        vm.expectRevert(abi.encodeWithSelector(ProtocolIdMismatch.selector, V32, 0));
        vm.prank(governor);
        ctmExecutor.execute(
            address(module),
            abi.encodeCall(CTMUpgradeModule.upgradeChain, (ICTMTransition(address(transitionV32)), chainId))
        );
    }
}

/// @notice The registry-driven upgrade run against an Era CTM and chain: the chain commits a
///         `SYSTEM_UPGRADE_L2_TX_TYPE` (254) transaction with an Era force-deployment.
contract RegistryDrivenUpgradeEraTest is RegistryDrivenUpgradeTestBase {
    function _deployFixture() internal override {
        deploy();
    }

    function _isZKsyncOSVariant() internal pure override returns (bool) {
        return false;
    }

    function _expectedL2UpgradeTxType() internal pure override returns (uint256) {
        return SYSTEM_UPGRADE_L2_TX_TYPE;
    }

    function _l2DeploymentType() internal pure override returns (IComplexUpgrader.ContractUpgradeType) {
        return IComplexUpgrader.ContractUpgradeType.EraForceDeployment;
    }

    function _l2DeployedBytecodeInfo() internal pure override returns (bytes memory) {
        // For Era this is the abi-encoded bytecode hash of the force-deployed contract.
        return abi.encode(bytes32(uint256(0x0100000000000000000000000000000000000000000000000000000000000001)));
    }

    function _registryGenesisBatchCommitment() internal pure override returns (bytes32) {
        return bytes32(uint256(2));
    }
}

/// @notice The registry-driven upgrade run against a ZKsyncOS CTM and chain: the chain commits
///         a `ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE` (126) transaction with a
///         `ZKsyncOSSystemProxyUpgrade` deployment, and the registry's genesis params carry the
///         `genesisBatchCommitment == 1` that `ZKsyncOSChainTypeManager` enforces.
contract RegistryDrivenUpgradeZKsyncOSTest is ZKsyncOSChainTypeManagerSharedTest, RegistryDrivenUpgradeTestBase {
    function _deployFixture() internal override {
        deployZKsyncOS();
    }

    function _isZKsyncOSVariant() internal pure override returns (bool) {
        return true;
    }

    function _expectedL2UpgradeTxType() internal pure override returns (uint256) {
        return ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE;
    }

    function _l2DeploymentType() internal pure override returns (IComplexUpgrader.ContractUpgradeType) {
        return IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade;
    }

    function _l2DeployedBytecodeInfo() internal pure override returns (bytes memory) {
        // For ZKsyncOS this is the abi-encoded (bytecodeHash, bytecodeLength, observableHash)
        // tuple of the new implementation.
        return abi.encode(bytes32(uint256(0xb001)), uint32(64), bytes32(uint256(0xb002)));
    }

    function _registryGenesisBatchCommitment() internal pure override returns (bytes32) {
        // ZKsyncOSChainTypeManager requires the genesis batch commitment to be exactly 1.
        return bytes32(uint256(1));
    }
}
