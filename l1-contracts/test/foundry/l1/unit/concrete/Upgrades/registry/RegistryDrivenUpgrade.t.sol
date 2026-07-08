// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "../../state-transition/ChainTypeManager/_ChainTypeManager_Shared.t.sol";
import {TestCTMRegistry} from "./TestRegistries.sol";

import {Call} from "contracts/governance/Common.sol";
import {UpgradeExecutor} from "contracts/governance/UpgradeExecutor.sol";
import {CTMUpgradeModule} from "contracts/upgrades/registry/CTMUpgradeModule.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/CTMUpgradeComposer.sol";
import {CTMContract, CoreContract} from "contracts/upgrades/registry/ContractIdentifiers.sol";
import {ICTMRegistry} from "contracts/upgrades/registry/ICTMRegistry.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
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
import {PRIORITY_TX_MAX_GAS_LIMIT} from "contracts/common/Config.sol";
import {ProtocolIdMismatch} from "contracts/common/L1ContractErrors.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";

/// @notice The first full registry-driven upgrade, end to end: a real chain diamond is taken
///         v32 -> v33 entirely through `UpgradeExecutor` -> `CTMUpgradeModule`, with every
///         payload composed from registry constants and actually EXECUTED (facet cuts applied,
///         the real `DefaultUpgrade` init delegatecalled, the L2 protocol upgrade transaction
///         committed on the chain).
/// @dev The fixture chain starts at protocol version 0, so "v32" is reached by a first
///      registry-driven hop (0.0.0 -> 0.32.0, L1-only: no facet changes, no L2 transaction, new
///      verifier). The second hop (0.32.0 -> 0.33.0) is the full minor upgrade: a real facet
///      replacement plus the composed L2 protocol upgrade transaction (nonce = 33). Two hops
///      also prove consecutive registry-driven upgrades sequence correctly.
/// @dev The registry is a storage-backed double (fixture addresses are dynamic), but everything
///      it pins here is real: live facet addresses/selectors, a real replacement `AdminFacet`,
///      the real `DefaultUpgrade`, real verifier contracts.
contract RegistryDrivenUpgradeTest is ChainTypeManagerTest {
    UpgradeExecutor internal ctmExecutor;
    CTMUpgradeModule internal module;
    TestCTMRegistry internal registryV32;
    TestCTMRegistry internal registryV33;

    address internal chainAddress;
    address internal newAdminFacet;
    address internal verifierV32;
    address internal verifierV33;
    address internal defaultUpgrade;

    uint256 internal constant V32 = uint256(32) << 32; // 0.32.0
    uint256 internal constant V33 = uint256(33) << 32; // 0.33.0

    function setUp() public {
        deploy();
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

        registryV32 = _makeRegistry(0, V32, verifierV32, address(0));
        registryV33 = _makeRegistry(V32, V33, verifierV33, newAdminFacet);
    }

    /// @dev Builds a registry for one hop. The facet plan pins the chain's REAL AdminFacet
    ///      (address + selectors as installed by the fixture); when `_newAdminFacet` is zero the
    ///      facet is unchanged between the versions (skipped -> L1-only upgrade with empty cuts),
    ///      otherwise it is replaced by the given implementation. A non-zero `_newAdminFacet` hop
    ///      also carries an L2 force-deployment, making it a full minor upgrade.
    function _makeRegistry(
        uint256 _oldVersion,
        uint256 _newVersion,
        address _verifier,
        address _newAdminFacet
    ) internal returns (TestCTMRegistry registry) {
        registry = new TestCTMRegistry();
        registry.setBase(false, _oldVersion, _newVersion, address(chainContractAddress));
        registry.setVerifier(_newVersion, _verifier);
        registry.setCtmAddress(CTMContract.DefaultUpgrade, _newVersion, defaultUpgrade);
        registry.setCtmAddress(CTMContract.DiamondInit, _newVersion, diamondInit);

        // The live AdminFacet the fixture installed at chain creation.
        address liveAdminFacet = facetCuts[1].facet;
        bytes4[] memory adminSelectors = Utils.getAdminSelectors();
        registry.setCtmAddress(CTMContract.AdminFacet, _oldVersion, liveAdminFacet);
        registry.setCtmAddress(
            CTMContract.AdminFacet,
            _newVersion,
            _newAdminFacet == address(0) ? liveAdminFacet : _newAdminFacet
        );
        // Old side: pinned list (the bootstrap override — the fixture installs a subset of the
        // facet's full ABI, and old facet versions may predate ISelfDescribingFacet anyway).
        registry.addFacet(_oldVersion, CTMContract.AdminFacet, adminSelectors);
        // New side: NO pinned list — the composer reads the replacement facet's own
        // ISelfDescribingFacet.selectors() (its full ABI), exercising the facet-default path.
        registry.addFacet(_newVersion, CTMContract.AdminFacet, new bytes4[](0));

        registry.setBaseSystemContractHashes(bytes32(0), bytes32(0), bytes32(0)); // no updates
        registry.setChainCreationData(hex"f1f2", hex"c1c2");
        registry.setGenesis(makeAddr("genesisUpgrade"), bytes32(uint256(1)), bytes32(uint256(2)), 54);
        registry.setL2UpgradeDelegate(address(0), hex"");

        if (_newAdminFacet != address(0)) {
            // Full minor upgrade: one L2 force-deployment rides in the upgrade transaction.
            registry.addL2ForceDeployment(
                CoreContract.L2Bridgehub,
                IComplexUpgrader.UniversalContractUpgradeInfo({
                    upgradeType: IComplexUpgrader.ContractUpgradeType.EraForceDeployment,
                    deployedBytecodeInfo: hex"aa01",
                    newAddress: makeAddr("l2Bridgehub")
                }),
                bytes32(uint256(0x0100000000000000000000000000000000000000000000000000000000000001))
            );
        }
        // No factory dependencies: their hashes are validated on L2, not here, and none of the
        // pinned deployments require new bytecode publication in this test.
    }

    function _runHop(TestCTMRegistry _registry) internal {
        vm.startPrank(governor);
        ctmExecutor.execute(
            address(module),
            abi.encodeCall(CTMUpgradeModule.applyCTMUpgrade, (ICTMRegistry(address(_registry)), 1000, 0))
        );
        ctmExecutor.execute(
            address(module),
            abi.encodeCall(CTMUpgradeModule.upgradeChain, (ICTMRegistry(address(_registry)), chainId, 0))
        );
        vm.stopPrank();
    }

    function test_registryDrivenUpgrade_v32ThenV33_endToEnd() public {
        // Hop 1 (0.0.0 -> 0.32.0): L1-only registry-driven upgrade — no facet changes, no L2
        // transaction, new verifier. The cut executes on the real chain with the real
        // DefaultUpgrade init.
        _runHop(registryV32);

        assertEq(IGetters(chainAddress).getProtocolVersion(), V32, "hop 1 must bump the chain to v32");
        assertEq(address(IGetters(chainAddress).getVerifier()), verifierV32, "hop 1 must install the v32 verifier");
        assertEq(
            IGetters(chainAddress).getL2SystemContractsUpgradeTxHash(),
            bytes32(0),
            "an L1-only upgrade must not set an L2 upgrade transaction"
        );

        // Hop 2 (0.32.0 -> 0.33.0): the full minor upgrade — AdminFacet actually replaced and
        // the composed L2 protocol upgrade transaction (nonce = 33) committed on the chain.
        _runHop(registryV33);

        assertEq(IGetters(chainAddress).getProtocolVersion(), V33, "hop 2 must bump the chain to v33");
        (, uint32 minor, ) = SemVer.unpackSemVer(uint96(V33));
        assertEq(minor, 33);
        assertEq(address(IGetters(chainAddress).getVerifier()), verifierV33, "hop 2 must install the v33 verifier");
        assertEq(
            IGetters(chainAddress).facetAddress(IAdmin.acceptAdmin.selector),
            newAdminFacet,
            "the AdminFacet must be re-pointed to the v33 implementation"
        );

        // The committed L2 upgrade transaction is exactly the registry-composed one.
        L2CanonicalTransaction memory expectedTx = CTMUpgradeComposer.buildL2UpgradeTx(
            ICTMRegistry(address(registryV33))
        );
        assertEq(expectedTx.nonce, 33, "upgrade tx nonce must equal the new minor version");
        assertEq(
            IGetters(chainAddress).getL2SystemContractsUpgradeTxHash(),
            keccak256(abi.encode(expectedTx)),
            "the chain must commit the registry-composed L2 upgrade transaction"
        );
    }

    function test_revertWhen_hopReplayed() public {
        _runHop(registryV32);

        // Replaying the chain upgrade of a completed hop fails the chain's own version check.
        vm.expectRevert(abi.encodeWithSelector(ProtocolIdMismatch.selector, V32, 0));
        vm.prank(governor);
        ctmExecutor.execute(
            address(module),
            abi.encodeCall(CTMUpgradeModule.upgradeChain, (ICTMRegistry(address(registryV32)), chainId, 0))
        );
    }
}
