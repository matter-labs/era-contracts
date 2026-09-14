// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL2V34Upgrade} from "contracts/upgrades/IL2V34Upgrade.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/libraries/CTMUpgradeComposer.sol";
import {L2_ECOSYSTEM_CONTRACT_COUNT} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {
    GenesisFacet,
    L2UpgradePlan,
    ReleaseGenesisData,
    ReleaseManifest
} from "contracts/upgrades/registry/RegistryTypes.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {ZKChainSpecificForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {RegistryObjectsFixture} from "foundry-test/l1/upgrades/_SharedRegistryObjects.t.sol";

/// @notice The v34 delegate-calldata composer: the pinned code that DEFINES what `L2V34Upgrade`
///         is called with, from the target release, the ecosystem's Bridgehub and the chain the
///         transaction is composed for — see {docs/upgrade-stage-lifecycle.md} §4.6.
/// @dev The releases are real write-once `CTMRelease` objects. The ecosystem behind the Bridgehub
///      (its CTM deployer, asset router and native token vault) is mocked by the shared fixture,
///      which has no live vault; the ERC20 base token IS real, since its metadata is what the
///      composer reads. Under test is which values the composer puts in the call.
contract L2V34DelegateCalldataComposerTest is RegistryObjectsFixture {
    CTMRelease internal release;
    address internal bridgehub;

    bytes internal constant OTHER_FIXED_FORCE_DEPLOYMENTS_DATA = hex"0a0b";

    function setUp() public {
        _setUpRegistryObjects(true, "");
        bridgehub = makeAddr("bridgehub");
        _mockEcosystemForComposer(bridgehub, ctmDeployerStub);
        release = new CTMRelease(_releaseManifest(FIXED_FORCE_DEPLOYMENTS_DATA, _pinned("verifier")));
    }

    // ─────────────────────────── the composed call ───────────────────────────

    function test_composesV34UpgradeCallFromReleaseBridgehubAndChain() public {
        // The composer takes its inputs live: the release's pinned data, the Bridgehub's tracker
        // and the chain's base-token registration.
        vm.expectCall(bridgehub, abi.encodeCall(IBridgehubBase.l1CtmDeployer, ()));
        vm.expectCall(bridgehub, abi.encodeCall(IBridgehubBase.baseTokenAssetId, (ETH_CHAIN_ID)));
        vm.expectCall(address(release), abi.encodeCall(ICTMRelease.fixedForceDeploymentsData, ()));
        bytes memory composed = v34Composer.composeDelegateCalldata(
            ICTMRelease(address(release)),
            bridgehub,
            ETH_CHAIN_ID
        );

        assertEq(
            composed,
            abi.encodeCall(
                IL2V34Upgrade.upgrade,
                (true, ctmDeployerStub, FIXED_FORCE_DEPLOYMENTS_DATA, _expectedPerChainData(ETH_CHAIN_ID))
            ),
            "the v34 delegate call must be the ZKsync OS upgrade with the release's fixed data and the chain's data"
        );
        (bool isZKsyncOS, address deployer, bytes memory fixedData, bytes memory chainData) = this.decodeV34Upgrade(
            composed
        );
        assertTrue(isZKsyncOS, "the repository is ZKsync-OS-only, so the VM flag is fixed");
        assertEq(deployer, ctmDeployerStub, "the CTM deployer is the Bridgehub's live tracker");
        assertEq(fixedData, FIXED_FORCE_DEPLOYMENTS_DATA, "the fixed data is the release's pinned payload");
        ZKChainSpecificForceDeploymentsData memory data = abi.decode(chainData, (ZKChainSpecificForceDeploymentsData));
        assertEq(data.l2LegacySharedBridge, address(0), "the legacy bridge slot is always zero");
        assertEq(data.predeployedL2WethAddress, address(0), "the deprecated WETH slot is always zero");
        assertEq(data.baseTokenL1Address, ETH_TOKEN_ADDRESS, "wrong L1 base token address");
        assertEq(data.baseTokenMetadata.name, "Ether", "wrong base token name");
        assertEq(data.baseTokenMetadata.symbol, "ETH", "wrong base token symbol");
        assertEq(data.baseTokenMetadata.decimals, 18, "wrong base token decimals");
        assertEq(data.baseTokenBridgingData.assetId, ETH_BASE_TOKEN_ASSET_ID, "wrong base token asset id");
        assertEq(data.baseTokenBridgingData.originChainId, ETH_ORIGIN_CHAIN_ID, "wrong origin chain");
        assertEq(data.baseTokenBridgingData.originToken, ETH_TOKEN_ADDRESS, "wrong origin token");
    }

    /// @dev For a chain whose base token is not ETH the metadata comes from the token's local
    ///      bridged representation (`tokenAddress`), not from `originToken`, which may have no
    ///      code on this layer; the bridging data still describes the token on its origin chain.
    function test_readsAnERC20BaseTokenFromItsLocalRepresentation() public {
        bytes memory composed = v34Composer.composeDelegateCalldata(
            ICTMRelease(address(release)),
            bridgehub,
            ERC20_CHAIN_ID
        );

        assertEq(
            composed,
            abi.encodeCall(
                IL2V34Upgrade.upgrade,
                (true, ctmDeployerStub, FIXED_FORCE_DEPLOYMENTS_DATA, _expectedPerChainData(ERC20_CHAIN_ID))
            )
        );
        (, , , bytes memory chainData) = this.decodeV34Upgrade(composed);
        ZKChainSpecificForceDeploymentsData memory data = abi.decode(chainData, (ZKChainSpecificForceDeploymentsData));
        assertEq(data.baseTokenMetadata.name, ERC20_NAME, "metadata not read from the local token");
        assertEq(data.baseTokenMetadata.symbol, ERC20_SYMBOL, "wrong symbol");
        assertEq(data.baseTokenMetadata.decimals, ERC20_DECIMALS, "wrong decimals");
        assertEq(data.baseTokenL1Address, erc20OriginToken, "wrong L1 base token address");
        assertEq(data.baseTokenBridgingData.originToken, erc20OriginToken, "wrong origin token");
        assertEq(data.baseTokenBridgingData.originChainId, ERC20_ORIGIN_CHAIN_ID, "wrong origin chain");
        assertEq(data.baseTokenBridgingData.assetId, ERC20_BASE_TOKEN_ASSET_ID, "wrong base token asset id");
    }

    /// @dev Nothing is cached in the composer: a different release or a Bridgehub naming another
    ///      tracker composes different arguments from the same code.
    function test_composesFromLiveInputs() public {
        CTMRelease otherRelease = new CTMRelease(
            _releaseManifest(OTHER_FIXED_FORCE_DEPLOYMENTS_DATA, _pinned("otherVerifier"))
        );
        address otherBridgehub = makeAddr("otherBridgehub");
        address otherDeployer = makeAddr("otherCtmDeployer");
        _mockEcosystemForComposer(otherBridgehub, otherDeployer);

        assertEq(
            v34Composer.composeDelegateCalldata(ICTMRelease(address(otherRelease)), bridgehub, ETH_CHAIN_ID),
            abi.encodeCall(
                IL2V34Upgrade.upgrade,
                (true, ctmDeployerStub, OTHER_FIXED_FORCE_DEPLOYMENTS_DATA, _expectedPerChainData(ETH_CHAIN_ID))
            ),
            "the fixed data follows the release"
        );
        assertEq(
            v34Composer.composeDelegateCalldata(ICTMRelease(address(release)), otherBridgehub, ETH_CHAIN_ID),
            abi.encodeCall(
                IL2V34Upgrade.upgrade,
                (true, otherDeployer, FIXED_FORCE_DEPLOYMENTS_DATA, _expectedPerChainData(ETH_CHAIN_ID))
            ),
            "the CTM deployer follows the Bridgehub"
        );
    }

    /// @dev Two chains of one ecosystem: the ecosystem-wide arguments are shared, only the
    ///      per-chain data differs.
    function test_composesPerChain() public {
        bytes memory forEthChain = v34Composer.composeDelegateCalldata(
            ICTMRelease(address(release)),
            bridgehub,
            ETH_CHAIN_ID
        );
        bytes memory forErc20Chain = v34Composer.composeDelegateCalldata(
            ICTMRelease(address(release)),
            bridgehub,
            ERC20_CHAIN_ID
        );

        assertTrue(keccak256(forEthChain) != keccak256(forErc20Chain), "two chains must not share a call");
        (bool ethFlag, address ethDeployer, bytes memory ethFixed, bytes memory ethChainData) = this.decodeV34Upgrade(
            forEthChain
        );
        (bool erc20Flag, address erc20Deployer, bytes memory erc20Fixed, bytes memory erc20ChainData) = this
            .decodeV34Upgrade(forErc20Chain);
        assertEq(ethFlag, erc20Flag, "the VM flag is ecosystem-wide");
        assertEq(ethDeployer, erc20Deployer, "the CTM deployer is ecosystem-wide");
        assertEq(ethFixed, erc20Fixed, "the fixed data is ecosystem-wide");
        assertEq(ethChainData, _expectedPerChainData(ETH_CHAIN_ID), "the ETH chain's data");
        assertEq(erc20ChainData, _expectedPerChainData(ERC20_CHAIN_ID), "the ERC20 chain's data");
    }

    /// @dev Fail fast: an input the composer cannot read is an error, never a default. (A Bridgehub
    ///      without the getter is modelled by making the call revert.)
    function test_revertWhen_bridgehubDoesNotServeTheCtmDeployer() public {
        address brokenBridgehub = makeAddr("brokenBridgehub");
        vm.etch(brokenBridgehub, hex"00");
        vm.mockCallRevert(brokenBridgehub, abi.encodeCall(IBridgehubBase.l1CtmDeployer, ()), "");

        vm.expectRevert();
        v34Composer.composeDelegateCalldata(ICTMRelease(address(release)), brokenBridgehub, ETH_CHAIN_ID);
    }

    /// @dev A chain the ecosystem does not know has no base token to read: the composition
    ///      reverts rather than composing a transaction for nobody.
    function test_revertWhen_chainIsNotRegistered() public {
        uint256 unknownChainId = 999;

        vm.expectRevert();
        v34Composer.composeDelegateCalldata(ICTMRelease(address(release)), bridgehub, unknownChainId);
    }

    // ─────────────────────────── through a pinned transition ───────────────────────────

    /// @dev The production path: a transition pins the composer by codehash and
    ///      `CTMUpgradeComposer` asks it for the delegate calldata with the TARGET release, the
    ///      Bridgehub and the chain it is handed. The composed L2 transaction therefore carries the
    ///      v34 call with that chain's data.
    function test_transitionPinningTheComposerComposesTheV34Call() public {
        CTMRelease fromRelease = new CTMRelease(_releaseManifest(FIXED_FORCE_DEPLOYMENTS_DATA, _pinned("verifierV33")));
        CTMTransition transition = _transition(
            fromRelease,
            release,
            SemVer.packSemVer(0, 33, 0),
            SemVer.packSemVer(0, 34, 0),
            0,
            _pinned("upgradeEngine"),
            _v34Plan()
        );
        transition.validate();
        assertTrue(transition.verifyAll(), "the pinned composer must verify against its live code");

        L2UpgradePlan memory plan = transition.l2Plan();
        assertEq(plan.delegateComposer, address(v34Composer));
        L2CanonicalTransaction memory transaction = CTMUpgradeComposer.buildL2UpgradeTx(
            ICTMTransition(address(transition)),
            bridgehub,
            ETH_CHAIN_ID
        );
        assertEq(
            transaction.data,
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (
                    plan.deployments,
                    plan.delegateTo,
                    abi.encodeCall(
                        IL2V34Upgrade.upgrade,
                        (true, ctmDeployerStub, FIXED_FORCE_DEPLOYMENTS_DATA, _expectedPerChainData(ETH_CHAIN_ID))
                    )
                )
            ),
            "the L2 transaction delegates to the v34 upgrade with the composed arguments"
        );
    }

    // ─────────────────────────── fixtures ───────────────────────────

    /// @dev A release over the shared fixture's facet and stand-ins, pinning `_fixedForceDeploymentsData`
    ///      (the one input of the composer that differs between releases here).
    function _releaseManifest(
        bytes memory _fixedForceDeploymentsData,
        address _verifier
    ) internal view returns (ReleaseManifest memory) {
        GenesisFacet[] memory facets = new GenesisFacet[](1);
        facets[0] = GenesisFacet({facet: _pin(facetShared), isFreezable: false});
        return
            ReleaseManifest({
                diamondInit: _pin(diamondInit),
                verifier: _pin(_verifier),
                genesisUpgrade: _pin(genesisUpgradeStub),
                genesisFacets: facets,
                genesis: ReleaseGenesisData({
                    fixedForceDeploymentsData: _fixedForceDeploymentsData,
                    genesisBatchHash: bytes32(uint256(1)),
                    genesisBatchCommitment: bytes32(uint256(1)),
                    genesisIndexRepeatedStorageChanges: 54
                }),
                l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT),
                l2SystemProxyBytecodeInfo: ""
            });
    }
}
