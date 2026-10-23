// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    L2_ASSET_ROUTER_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
    L2_FORCE_DEPLOYER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_MESSAGE_ROOT_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2ComplexUpgrader} from "contracts/l2-upgrades/L2ComplexUpgrader.sol";
import {L2DefaultUpgrade} from "contracts/l2-upgrades/L2DefaultUpgrade.sol";
import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";
import {MockContractDeployer} from "contracts/dev-contracts/MockContractDeployer.sol";
import {ISystemContractDeployer} from "contracts/l2-system/zksync-os/interfaces/ISystemContractDeployer.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {ZKSyncOSBytecodeInfo} from "contracts/common/libraries/ZKSyncOSBytecodeInfo.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/libraries/CTMUpgradeComposer.sol";
import {L2_ECOSYSTEM_CONTRACT_COUNT} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {
    AuthoredL2Plan,
    GenesisFacet,
    L2UpgradePlan,
    ReleaseGenesisData,
    ReleaseManifest
} from "contracts/upgrades/registry/RegistryTypes.sol";
import {RegistryObjectsFixture} from "foundry-test/l1/upgrades/_SharedRegistryObjects.t.sol";
import {L2PlanFixtures} from "foundry-test/l1/unit/concrete/Upgrades/registry/L2PlanFixtures.sol";
import {MockAcceptAll, MockL2DefaultUpgradeNativeTokenVault} from "./L2DefaultUpgrade.t.sol";

/// @notice The composed L2 protocol upgrade transaction of a transition, executed on L2: the
///         transaction `CTMUpgradeComposer` builds for one chain is sent from the force deployer to
///         `L2ComplexUpgrader`, which force-deploys the plan and delegatecalls `L2DefaultUpgrade`.
///         It runs with the calldata the default composer composes, and the same deployments with
///         EMPTY delegate calldata (what a plan with a delegate but no composer used to compose)
///         revert, because `L2DefaultUpgrade` has no fallback. That is why `L2PlanLib.build` refuses
///         a delegate without a composer.
/// @dev L2 in L1 context, in the same harness style as `L2DefaultUpgrade.t.sol`: the L1 side is the
///      shared registry fixture (real releases, transition and default composer over a mocked
///      Bridgehub ecosystem); the L2 built-ins the upgrade path touches are mocks etched at their
///      system addresses, with the native token vault recording what it is updated with. The
///      ZKsync OS deployer places force-deployed code through a system hook the EVM lacks, so the
///      deployer is `MockContractDeployer` (a no-op) and the test places the delegate's code at
///      its derived address beforehand, as the anvil harness does with `anvil_setCode`.
contract ComposedL2UpgradeTxExecutionTest is RegistryObjectsFixture {
    uint256 internal constant L1_CHAIN_ID = 9;
    uint256 internal constant MAX_NUMBER_OF_ZKCHAINS = 100;
    address internal constant L1_ASSET_ROUTER = address(0xAA01);
    address internal constant ALIASED_L1_GOVERNANCE = address(0xAA02);
    address internal constant ALIASED_CHAIN_REGISTRATION_SENDER = address(0xAA03);
    /// @dev The vault's live WETH, so the upgrade path keeps it instead of deploying one.
    address internal constant PREDEPLOYED_WETH = address(0xdead);

    address internal bridgehub;
    CTMTransition internal transition;
    MockL2DefaultUpgradeNativeTokenVault internal nativeTokenVault;

    function setUp() public {
        _setUpRegistryObjects("");
        bridgehub = makeAddr("bridgehub");
        _mockEcosystemForComposer(bridgehub, ctmDeployerStub);

        address verifier = _deployedStub("verifier");
        CTMRelease fromRelease = new CTMRelease(_releaseManifest(verifier, SemVer.packSemVer(0, 34, 0)));
        CTMRelease newRelease = new CTMRelease(_releaseManifest(verifier, SemVer.packSemVer(0, 35, 0)));
        // The delegate is the real `L2DefaultUpgrade`, named by its runtime bytecode's info, and the
        // composer is the real default one.
        AuthoredL2Plan memory plan = AuthoredL2Plan({
            delegateBytecodeInfo: L2PlanFixtures.bytecodeInfo(type(L2DefaultUpgrade).runtimeCode),
            extraBytecodeInfos: new bytes[](0),
            delegateComposer: address(defaultComposer)
        });
        transition = _transition(fromRelease, newRelease, 0, _deployedStub("upgradeEngine"), plan);

        _setUpL2();
    }

    // ─────────────────────────────── happy path ───────────────────────────────

    function test_composedTransactionExecutesOnL2() public {
        L2UpgradePlan memory plan = transition.l2Plan();
        L2CanonicalTransaction memory transaction = CTMUpgradeComposer.buildL2UpgradeTx(
            ICTMTransition(address(transition)),
            bridgehub,
            ETH_CHAIN_ID
        );
        assertEq(address(uint160(transaction.from)), L2_FORCE_DEPLOYER_ADDR, "sent by the force deployer");
        assertEq(address(uint160(transaction.to)), L2_COMPLEX_UPGRADER_ADDR, "to the complex upgrader");
        assertEq(plan.deployments.length, 1, "the delegate is the plan's one deployment");

        (bytes32 blakeHash, uint256 length, bytes32 observableHash) = ZKSyncOSBytecodeInfo.decodeZKSyncOSBytecodeInfo(
            plan.deployments[0].deployedBytecodeInfo
        );
        vm.expectCall(
            L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
            abi.encodeCall(
                ISystemContractDeployer.setBytecodeDetailsEVM,
                (plan.delegateTo, blakeHash, uint32(length), observableHash)
            )
        );
        vm.expectEmit(true, true, true, true, L2_COMPLEX_UPGRADER_ADDR);
        emit L2GenesisForceDeploymentsHelper.ContractUpgraded(
            IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
            plan.delegateTo
        );
        vm.expectEmit(true, true, true, true, L2_COMPLEX_UPGRADER_ADDR);
        emit L2GenesisForceDeploymentsHelper.ForceDeployedContractsInitialized(false);
        (bool success, bytes memory returnData) = _send(transaction.data, plan);

        assertTrue(success, string(returnData));
        // The chain's composed data reached L2: the vault was updated once, with the ETH chain's
        // base token as the default composer read it off the Bridgehub.
        assertEq(nativeTokenVault.updateCalls(), 1, "the vault is updated exactly once");
        assertEq(nativeTokenVault.lastOriginChainId(), ETH_ORIGIN_CHAIN_ID, "the base token's origin chain");
        assertEq(nativeTokenVault.BASE_TOKEN_NAME(), "Ether", "the base token's name");
        assertEq(nativeTokenVault.BASE_TOKEN_SYMBOL(), "ETH", "the base token's symbol");
        assertEq(nativeTokenVault.BASE_TOKEN_DECIMALS(), 18, "the base token's decimals");
    }

    // ─────────────────────────────── unhappy path ───────────────────────────────

    /// @dev The same transaction with empty delegate calldata reaches `L2DefaultUpgrade`'s missing
    ///      fallback: the delegatecall reverts without data, the upgrader bubbles that, and nothing
    ///      is initialized. On a real chain the L2 upgrade transaction could never execute.
    function test_emptyDelegateCalldataRevertsOnL2() public {
        L2UpgradePlan memory plan = transition.l2Plan();
        bytes memory uncomposed = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgradeUniversal,
            (plan.deployments, plan.delegateTo, bytes(""))
        );

        (bool success, bytes memory returnData) = _send(uncomposed, plan);

        assertFalse(success, "the delegate rejects empty calldata");
        assertEq(returnData.length, 0, "the revert is the delegate's own empty one, bubbled");
        assertEq(nativeTokenVault.updateCalls(), 0, "nothing is initialized");
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    /// @dev Sends `_data` to the complex upgrader as the force deployer, the delegate's code in
    ///      place at its derived address (see the contract docs).
    function _send(bytes memory _data, L2UpgradePlan memory _plan) internal returns (bool, bytes memory) {
        vm.etch(_plan.delegateTo, type(L2DefaultUpgrade).runtimeCode);
        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        return L2_COMPLEX_UPGRADER_ADDR.call(_data);
    }

    function _setUpL2() internal {
        vm.etch(L2_COMPLEX_UPGRADER_ADDR, address(new L2ComplexUpgrader()).code);
        vm.etch(L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, address(new MockContractDeployer()).code);

        address acceptAll = address(new MockAcceptAll());
        address[] memory acceptAllAddresses = new address[](6);
        acceptAllAddresses[0] = L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR;
        acceptAllAddresses[1] = L2_MESSAGE_ROOT_ADDR;
        acceptAllAddresses[2] = L2_BRIDGEHUB_ADDR;
        acceptAllAddresses[3] = L2_ASSET_ROUTER_ADDR;
        acceptAllAddresses[4] = L2_CHAIN_ASSET_HANDLER_ADDR;
        acceptAllAddresses[5] = L2_INTEROP_HANDLER_ADDR;
        for (uint256 i = 0; i < acceptAllAddresses.length; ++i) {
            vm.etch(acceptAllAddresses[i], acceptAll.code);
        }

        vm.etch(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            address(new MockL2DefaultUpgradeNativeTokenVault(ETH_BASE_TOKEN_ASSET_ID, L1_CHAIN_ID, PREDEPLOYED_WETH))
                .code
        );
        nativeTokenVault = MockL2DefaultUpgradeNativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
    }

    /// @dev A release at `_protocolVersion` with an empty L2 table whose fixed force-deployments
    ///      data the L2 upgrade path accepts (a nonzero aliased governance among them).
    function _releaseManifest(
        address _verifier,
        uint256 _protocolVersion
    ) internal view returns (ReleaseManifest memory) {
        GenesisFacet[] memory facets = new GenesisFacet[](1);
        facets[0] = GenesisFacet({facet: facetShared, isFreezable: false});
        return
            ReleaseManifest({
                protocolVersion: _protocolVersion,
                diamondInit: diamondInit,
                verifier: _verifier,
                genesisUpgrade: genesisUpgradeStub,
                genesisFacets: facets,
                genesis: ReleaseGenesisData({
                    fixedForceDeploymentsData: _l2FixedForceDeploymentsData(),
                    genesisBatchHash: bytes32(uint256(1)),
                    genesisIndexRepeatedStorageChanges: 54
                }),
                l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT),
                l2SystemProxyBytecodeInfo: ""
            });
    }

    /// @dev Empty bytecode infos, as the release's empty table requires.
    function _l2FixedForceDeploymentsData() internal pure returns (bytes memory) {
        FixedForceDeploymentsData memory data;
        data.l1ChainId = L1_CHAIN_ID;
        data.l1AssetRouter = L1_ASSET_ROUTER;
        data.aliasedL1Governance = ALIASED_L1_GOVERNANCE;
        data.maxNumberOfZKChains = MAX_NUMBER_OF_ZKCHAINS;
        data.aliasedChainRegistrationSender = ALIASED_CHAIN_REGISTRATION_SENDER;
        return abi.encode(data);
    }
}
