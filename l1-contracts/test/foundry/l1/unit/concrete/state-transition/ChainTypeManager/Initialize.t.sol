// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {IChainTypeManager, ChainTypeManagerInitializeData} from "contracts/state-transition/IChainTypeManager.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {GenesisFacet, ReleaseGenesisData, ReleaseManifest} from "contracts/upgrades/registry/RegistryTypes.sol";
import {L2_ECOSYSTEM_CONTRACT_COUNT} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {MockSelfDescribingFacet} from "contracts/dev-contracts/test/MockSelfDescribingFacet.sol";
import {RegistryEmptySelectors, RegistryTargetHasNoCode} from "contracts/common/L1ContractErrors.sol";
import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {L2PlanFixtures} from "foundry-test/l1/unit/concrete/Upgrades/registry/L2PlanFixtures.sol";

/// @notice The CTM keeps no genesis-param checks of its own: the release it installs refuses a
///         zero genesis batch hash at construction, and the release's `validate()` — which the CTM
///         runs before installing any release — refuses a codeless member and a selector-less
///         facet. These tests initialize a CTM over REAL releases (unlike the rest of this suite,
///         which mocks the release) to show that coverage holds through the CTM: a release that
///         fails it is never installed, so `DiamondInit` never builds a chain from one.
contract ChainTypeManagerInitializeTest is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    /// @dev A valid version-0 release over the fixture's facets, DiamondInit, verifier and
    ///      genesis upgrade. The fixture facets do not all self-describe, so their routing is mocked
    ///      from the cut (see `_mockFacetSelfDescriptions`).
    function _validReleaseManifest() internal returns (ReleaseManifest memory manifest) {
        _mockFacetSelfDescriptions(facetCuts);
        GenesisFacet[] memory genesisFacets = new GenesisFacet[](facetCuts.length);
        for (uint256 i = 0; i < facetCuts.length; ++i) {
            genesisFacets[i] = GenesisFacet({facet: facetCuts[i].facet, isFreezable: facetCuts[i].isFreezable});
        }
        manifest = ReleaseManifest({
            protocolVersion: 0,
            diamondInit: diamondInit,
            verifier: testnetVerifier,
            genesisUpgrade: address(genesisUpgradeContract),
            genesisFacets: genesisFacets,
            genesis: ReleaseGenesisData({
                fixedForceDeploymentsData: L2PlanFixtures.emptyTableForceDeploymentsData(),
                genesisBatchHash: bytes32(uint256(0x01)),
                genesisIndexRepeatedStorageChanges: 0x01
            }),
            l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT),
            l2SystemProxyBytecodeInfo: ""
        });
    }

    function _initializeData(address _release) internal view returns (bytes memory) {
        return
            abi.encodeCall(
                IChainTypeManager.initialize,
                ChainTypeManagerInitializeData({
                    owner: governor,
                    validatorTimelock: validator,
                    currentRelease: _release,
                    serverNotifier: serverNotifier
                })
            );
    }

    function test_initializesFromAValidRelease() public {
        CTMRelease release = new CTMRelease(_validReleaseManifest());

        vm.expectEmit(true, true, false, false);
        emit IChainTypeManager.NewCurrentRelease(0, address(release));
        ChainTypeManager ctm = ChainTypeManager(
            address(
                new TransparentUpgradeableProxy(address(chainTypeManager), admin, _initializeData(address(release)))
            )
        );

        assertEq(ctm.currentRelease(), address(release), "the release is installed");
        assertEq(ctm.l1GenesisUpgrade(), address(genesisUpgradeContract), "genesis reads the release's engine");
        assertEq(ctm.protocolVersion(), 0, "the CTM starts at the release's version");
    }

    /// @dev A zero genesis upgrade is refused by the release constructor (`ZeroAddress`); the one
    ///      that reaches the CTM is a nonzero address without code, which `validate()` refuses.
    function test_RevertWhen_releaseGenesisUpgradeHasNoCode() public {
        ReleaseManifest memory manifest = _validReleaseManifest();
        address codeless = makeAddr("codelessGenesisUpgrade");
        manifest.genesisUpgrade = codeless;
        CTMRelease release = new CTMRelease(manifest);

        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, codeless));
        new TransparentUpgradeableProxy(address(chainTypeManager), admin, _initializeData(address(release)));
    }

    /// @dev A selector-less facet would reach `DiamondInit` as an empty `Add` cut, which every
    ///      chain creation would then revert on. The CTM refuses to install such a release at all.
    function test_RevertWhen_releaseHasASelectorlessFacet() public {
        ReleaseManifest memory manifest = _validReleaseManifest();
        address emptyFacet = address(new MockSelfDescribingFacet(new bytes4[](0)));
        manifest.genesisFacets[0].facet = emptyFacet;
        CTMRelease release = new CTMRelease(manifest);

        vm.expectRevert(abi.encodeWithSelector(RegistryEmptySelectors.selector, emptyFacet));
        new TransparentUpgradeableProxy(address(chainTypeManager), admin, _initializeData(address(release)));
    }
}
