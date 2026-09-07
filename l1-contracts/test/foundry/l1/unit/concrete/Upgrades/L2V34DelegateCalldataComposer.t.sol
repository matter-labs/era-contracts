// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2V34DelegateCalldataComposer} from "contracts/upgrades/L2V34DelegateCalldataComposer.sol";
import {IL2V34Upgrade} from "contracts/upgrades/IL2V34Upgrade.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/libraries/CTMUpgradeComposer.sol";
import {
    CTM_CONTRACT_COUNT,
    L2_ECOSYSTEM_CONTRACT_COUNT
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {
    AuthoredL2Plan,
    GenesisFacet,
    L2UpgradePlan,
    PinnedContract,
    ProxyUpgradeRow,
    ReleaseGenesisData,
    ReleaseManifest,
    TransitionManifest
} from "contracts/upgrades/registry/RegistryTypes.sol";
import {L2PlanFixtures} from "./registry/L2PlanFixtures.sol";
import {MockSelfDescribingFacet} from "contracts/dev-contracts/test/MockSelfDescribingFacet.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

/// @notice The v34 delegate-calldata composer: the pinned code that DEFINES what `L2V34Upgrade`
///         is called with, from the target release and the ecosystem's Bridgehub — see
///         {docs/upgrade-stage-lifecycle.md} §4.6.
/// @dev The releases are real write-once `CTMRelease` objects. The Bridgehub is a mocked getter:
///      the composer reads exactly one live value from it (`l1CtmDeployer`), and this suite isolates
///      the composition from the ecosystem wiring behind that address.
contract L2V34DelegateCalldataComposerTest is Test {
    L2V34DelegateCalldataComposer internal composer;
    CTMRelease internal release;

    address internal bridgehub;
    address internal ctmDeployer;
    address internal diamondInit;
    address internal facet;
    address internal verifier;
    address internal genesisUpgrade;

    bytes internal constant FIXED_FORCE_DEPLOYMENTS_DATA = hex"f1f2f3f4";
    bytes internal constant OTHER_FIXED_FORCE_DEPLOYMENTS_DATA = hex"0a0b";
    /// @dev Dummy EVM bytecode of the upgrade delegate a transition pins (see {L2PlanFixtures}).
    bytes internal constant DELEGATE_CODE = hex"c0de34";

    function setUp() public {
        composer = new L2V34DelegateCalldataComposer();

        ctmDeployer = makeAddr("ctmDeployer");
        bridgehub = makeAddr("bridgehub");
        _mockCtmDeployer(bridgehub, ctmDeployer);

        // A release's pins must point at code: facets self-describe, the rest are etched stand-ins.
        facet = address(new MockSelfDescribingFacet(_selectors1(bytes4(uint32(1)))));
        verifier = _pinned("verifier");
        genesisUpgrade = _pinned("genesisUpgrade");
        diamondInit = address(new DiamondInit(true));

        release = new CTMRelease(_releaseManifest(FIXED_FORCE_DEPLOYMENTS_DATA, verifier));
    }

    // ─────────────────────────── the composed call ───────────────────────────

    function test_composesV34UpgradeCallFromReleaseAndBridgehub() public {
        // The composer takes its inputs live: the release's pinned data and the Bridgehub getter.
        vm.expectCall(bridgehub, abi.encodeCall(IBridgehubBase.l1CtmDeployer, ()));
        vm.expectCall(address(release), abi.encodeCall(ICTMRelease.fixedForceDeploymentsData, ()));
        bytes memory composed = composer.composeDelegateCalldata(ICTMRelease(address(release)), bridgehub);

        assertEq(
            composed,
            abi.encodeCall(IL2V34Upgrade.upgrade, (true, ctmDeployer, FIXED_FORCE_DEPLOYMENTS_DATA, "")),
            "the v34 delegate call must be the ZKsync OS upgrade with the release's fixed data"
        );
        assertEq(bytes4(composed), IL2V34Upgrade.upgrade.selector, "selector");
        (bool isZKsyncOS, address deployer, bytes memory fixedData, bytes memory chainData) = _decodeUpgradeArgs(
            composed
        );
        assertTrue(isZKsyncOS, "the repository is ZKsync-OS-only, so the VM flag is fixed");
        assertEq(deployer, ctmDeployer, "the CTM deployer is the Bridgehub's live tracker");
        assertEq(fixedData, FIXED_FORCE_DEPLOYMENTS_DATA, "the fixed data is the release's pinned payload");
        assertEq(chainData.length, 0, "the per-chain data stays a placeholder for the L2 engine to fill");
    }

    /// @dev Nothing is cached in the composer: a different release or a Bridgehub naming another
    ///      tracker composes different arguments from the same code.
    function test_composesFromLiveInputs() public {
        CTMRelease otherRelease = new CTMRelease(_releaseManifest(OTHER_FIXED_FORCE_DEPLOYMENTS_DATA, verifier));
        address otherBridgehub = makeAddr("otherBridgehub");
        address otherDeployer = makeAddr("otherCtmDeployer");
        _mockCtmDeployer(otherBridgehub, otherDeployer);

        assertEq(
            composer.composeDelegateCalldata(ICTMRelease(address(otherRelease)), bridgehub),
            abi.encodeCall(IL2V34Upgrade.upgrade, (true, ctmDeployer, OTHER_FIXED_FORCE_DEPLOYMENTS_DATA, "")),
            "the fixed data follows the release"
        );
        assertEq(
            composer.composeDelegateCalldata(ICTMRelease(address(release)), otherBridgehub),
            abi.encodeCall(IL2V34Upgrade.upgrade, (true, otherDeployer, FIXED_FORCE_DEPLOYMENTS_DATA, "")),
            "the CTM deployer follows the Bridgehub"
        );
    }

    /// @dev Fail fast: an input the composer cannot read is an error, never a default. (A Bridgehub
    ///      without the getter is modelled by making the call revert.)
    function test_revertWhen_bridgehubDoesNotServeTheCtmDeployer() public {
        address brokenBridgehub = makeAddr("brokenBridgehub");
        vm.etch(brokenBridgehub, hex"00");
        vm.mockCallRevert(brokenBridgehub, abi.encodeCall(IBridgehubBase.l1CtmDeployer, ()), "");

        vm.expectRevert();
        composer.composeDelegateCalldata(ICTMRelease(address(release)), brokenBridgehub);
    }

    // ─────────────────────────── through a pinned transition ───────────────────────────

    /// @dev The production path: a transition pins the composer by codehash and
    ///      `CTMUpgradeComposer` asks it for the delegate calldata with the TARGET release and the
    ///      Bridgehub it is handed. The composed L2 transaction therefore carries the v34 call.
    function test_transitionPinningTheComposerComposesTheV34Call() public {
        CTMRelease fromRelease = new CTMRelease(_releaseManifest(FIXED_FORCE_DEPLOYMENTS_DATA, _pinned("verifierV33")));
        CTMTransition transition = new CTMTransition(_transitionManifest(address(fromRelease), address(release)));
        transition.validate();
        assertTrue(transition.verifyAll(), "the pinned composer must verify against its live code");

        L2UpgradePlan memory plan = transition.l2Plan();
        assertEq(plan.delegateComposer, address(composer));
        L2CanonicalTransaction memory transaction = CTMUpgradeComposer.buildL2UpgradeTx(
            ICTMTransition(address(transition)),
            bridgehub
        );
        assertEq(
            transaction.data,
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (
                    plan.deployments,
                    plan.delegateTo,
                    abi.encodeCall(IL2V34Upgrade.upgrade, (true, ctmDeployer, FIXED_FORCE_DEPLOYMENTS_DATA, ""))
                )
            ),
            "the L2 transaction delegates to the v34 upgrade with the composed arguments"
        );
    }

    // ─────────────────────────── fixtures ───────────────────────────

    /// @dev The Bridgehub is reduced to the one getter the composer reads; the address carries code
    ///      so the call is a real external call, not a call into an empty account.
    function _mockCtmDeployer(address _bridgehub, address _ctmDeployer) internal {
        vm.etch(_bridgehub, hex"00");
        vm.mockCall(_bridgehub, abi.encodeCall(IBridgehubBase.l1CtmDeployer, ()), abi.encode(_ctmDeployer));
    }

    /// @dev Deploys a distinct-bytecode stand-in at a labelled address so EXTCODEHASH pins are real.
    function _pinned(string memory _name) internal returns (address addr) {
        addr = makeAddr(_name);
        vm.etch(addr, bytes.concat(hex"00", bytes(_name)));
    }

    function _pin(address _addr) internal view returns (PinnedContract memory) {
        return PinnedContract({addr: _addr, codehash: _addr.codehash});
    }

    function _releaseManifest(
        bytes memory _fixedForceDeploymentsData,
        address _verifier
    ) internal view returns (ReleaseManifest memory) {
        GenesisFacet[] memory facets = new GenesisFacet[](1);
        facets[0] = GenesisFacet({facet: _pin(facet), isFreezable: false});
        return
            ReleaseManifest({
                diamondInit: _pin(diamondInit),
                verifier: _pin(_verifier),
                genesisUpgrade: _pin(genesisUpgrade),
                genesisFacets: facets,
                genesis: ReleaseGenesisData({
                    fixedForceDeploymentsData: _fixedForceDeploymentsData,
                    genesisBatchHash: bytes32(uint256(1)),
                    genesisBatchCommitment: bytes32(uint256(1)),
                    genesisIndexRepeatedStorageChanges: 54
                }),
                l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT)
            });
    }

    /// @dev A v33 -> v34 hop whose L2 side is the minimal well-formed plan: the delegate's own Unsafe
    ///      deployment (its bytecode the one factory dependency) and the pinned v34 composer.
    function _transitionManifest(
        address _fromRelease,
        address _newRelease
    ) internal returns (TransitionManifest memory) {
        IComplexUpgrader.UniversalContractUpgradeInfo[]
            memory extras = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        extras[0] = L2PlanFixtures.unsafeDeployment(DELEGATE_CODE);
        return
            TransitionManifest({
                oldProtocolVersion: SemVer.packSemVer(0, 33, 0),
                newProtocolVersion: SemVer.packSemVer(0, 34, 0),
                fromRelease: _fromRelease,
                newRelease: _newRelease,
                upgradeEngine: _pin(_pinned("upgradeEngine")),
                proxyUpgrades: new ProxyUpgradeRow[](CTM_CONTRACT_COUNT),
                oldProtocolVersionDeadline: type(uint256).max,
                upgradeTimestamp: 0,
                l2Plan: AuthoredL2Plan({
                    extraDeployments: extras,
                    delegateTo: extras[0].newAddress,
                    delegateComposer: _pin(address(composer)),
                    factoryDepHashes: L2PlanFixtures.factoryDepHashes(L2PlanFixtures.codes(DELEGATE_CODE))
                }),
                coreRegistry: PinnedContract({addr: address(0), codehash: bytes32(0)}),
                upgradeTimer: _pin(_pinned("upgradeTimer"))
            });
    }

    function _selectors1(bytes4 _a) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = _a;
    }

    /// @dev Splits an ABI-encoded `IL2V34Upgrade.upgrade` call into its arguments.
    function _decodeUpgradeArgs(
        bytes memory _call
    ) internal pure returns (bool isZKsyncOS, address ctmDeployer_, bytes memory fixedData, bytes memory chainData) {
        bytes memory args = new bytes(_call.length - 4);
        for (uint256 i = 0; i < args.length; ++i) {
            args[i] = _call[i + 4];
        }
        (isZKsyncOS, ctmDeployer_, fixedData, chainData) = abi.decode(args, (bool, address, bytes, bytes));
    }
}
