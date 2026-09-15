// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseZkSyncUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {IL1GenesisUpgrade} from "contracts/upgrades/IL1GenesisUpgrade.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {PreviousUpgradeBatchNotCleared, PreviousUpgradeNotFinalized} from "contracts/upgrades/ZkSyncUpgradeErrors.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {
    IL2GenesisUpgrade,
    ZKChainSpecificForceDeploymentsData
} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {L2_GENESIS_UPGRADE_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";
import {RegistryObjectsFixture} from "./_SharedRegistryObjects.t.sol";
import {LegacyGenesisComposition} from "./_LegacyGenesisComposition.t.sol";

contract DummyL1GenesisUpgrade is L1GenesisUpgrade, BaseUpgradeUtils {}

contract DummyDefaultUpgradeForGenesis is DefaultUpgrade, BaseUpgradeUtils {}

/// @notice `L1GenesisUpgrade` as the initialization path of the release a CTM pins: the transaction
///         it composes, the view that serves the same composition, and the genesis-only execution
///         rules. The engine under test plays the chain diamond (it is called directly, so its own
///         diamond storage is the chain's), the way `DefaultUpgrade.t.sol` does for the upgrade
///         path. The full flow through a real CTM and a real diamond proxy is covered by
///         `CreateNewChain.t.sol`.
/// @dev The ecosystem behind the Bridgehub is mocked by the shared fixture; the base tokens are
///      real contracts, since their returndata is exactly what the metadata probe reacts to.
contract L1GenesisUpgradeTest is BaseUpgrade, RegistryObjectsFixture {
    DummyL1GenesisUpgrade internal engine;
    CTMRelease internal release;
    address internal releaseVerifier;
    address internal mockBridgehub = makeAddr("mockGenesisBridgehub");
    address internal mockCtm = makeAddr("mockGenesisCtm");

    function setUp() public {
        engine = new DummyL1GenesisUpgrade();
        _prepareUpgrade();
        engine.setPriorityTxMaxGasLimit(1 ether);
        engine.setPriorityTxMaxPubdata(1000000);
        engine.setBridgehub(mockBridgehub);
        engine.setChainTypeManager(mockCtm);
        engine.setChainId(ETH_CHAIN_ID);
        // The composed transaction carries the ZKsync OS upgrade type, which the chain accepts
        // only when it runs ZKsync OS itself.
        engine.setZKsyncOS(true);

        _setUpRegistryObjects("");
        _mockEcosystemForComposer(mockBridgehub, ctmDeployerStub);
        releaseVerifier = _pinned("genesisVerifier");
        release = _release(_arrivingFacets(), releaseVerifier);
        vm.mockCall(mockCtm, abi.encodeCall(IChainTypeManager.currentRelease, ()), abi.encode(address(release)));

        // `DiamondInit` has already installed the version and the release's verifier; genesis runs
        // at that same version, which is the genesis-only relaxation of the version rule.
        engine.setProtocolVersion(protocolVersion);
        engine.setVerifier(releaseVerifier);
    }

    function _composedGenesisTx(uint256 _chainId) internal view returns (L2CanonicalTransaction memory) {
        return engine.genesisUpgradeTx(address(release), mockBridgehub, _chainId, protocolVersion);
    }

    // ─────────────────────────────── execution ───────────────────────────────

    /// @dev The whole genesis edge: the version it was initialized at stays, the verifier
    ///      `DiamondInit` installed is left alone, and the composed transaction is committed.
    function test_genesisUpgrade_commitsTheComposedGenesisTransaction() public {
        L2CanonicalTransaction memory expectedTx = _composedGenesisTx(ETH_CHAIN_ID);
        bytes32 expectedHash = keccak256(abi.encode(expectedTx));

        vm.expectEmit(address(engine));
        emit BaseZkSyncUpgrade.UpgradeComplete(protocolVersion, expectedHash, expectedTx);
        vm.expectEmit(address(engine));
        emit IL1GenesisUpgrade.GenesisUpgrade(address(engine), expectedTx, protocolVersion);
        bytes32 result = engine.genesisUpgrade();

        assertEq(result, Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE, "the diamond-init success value");
        assertEq(engine.getProtocolVersion(), protocolVersion, "genesis keeps the initialized version");
        assertEq(engine.getVerifier(), releaseVerifier, "genesis must not touch the installed verifier");
        assertEq(engine.getL2SystemContractsUpgradeTxHash(), expectedHash, "the composed transaction is committed");
    }

    /// @dev Execution and inspection are one construction: what the view serves is what the chain
    ///      stores the hash of.
    function test_genesisUpgradeTx_isTheTransactionExecutionCommits() public {
        engine.genesisUpgrade();

        assertEq(
            engine.getL2SystemContractsUpgradeTxHash(),
            keccak256(abi.encode(_composedGenesisTx(ETH_CHAIN_ID))),
            "the served view is the committed transaction"
        );
    }

    /// @dev The inner call is the genesis one, NOT a deployment plan: a new chain has nothing
    ///      force-deployed yet, so it goes through `IComplexUpgrader.upgrade` into the L2 genesis
    ///      upgrade, with the release's fixed blob and this chain's own data.
    function test_genesisUpgradeTx_delegatesToTheL2GenesisUpgrade() public {
        L2CanonicalTransaction memory transaction = _composedGenesisTx(ETH_CHAIN_ID);

        assertEq(
            transaction.data,
            abi.encodeCall(
                IComplexUpgrader.upgrade,
                (
                    L2_GENESIS_UPGRADE_ADDR,
                    abi.encodeCall(
                        IL2GenesisUpgrade.genesisUpgrade,
                        (
                            ETH_CHAIN_ID,
                            ctmDeployerStub,
                            FIXED_FORCE_DEPLOYMENTS_DATA,
                            _expectedPerChainData(ETH_CHAIN_ID)
                        )
                    )
                )
            ),
            "the genesis call is composed from the release, the Bridgehub and the chain"
        );
        assertEq(transaction.factoryDeps.length, 0, "genesis factory deps are published out of band");
    }

    /// @dev Nothing is cached: two chains of one ecosystem get transactions that differ in exactly
    ///      the per-chain half.
    function test_genesisUpgradeTx_isComposedPerChain() public {
        L2CanonicalTransaction memory forEthChain = _composedGenesisTx(ETH_CHAIN_ID);
        L2CanonicalTransaction memory forErc20Chain = _composedGenesisTx(ERC20_CHAIN_ID);

        assertTrue(keccak256(forEthChain.data) != keccak256(forErc20Chain.data), "two chains must not share a call");
        assertEq(_genesisPerChainData(forEthChain).baseTokenL1Address, ETH_TOKEN_ADDRESS);
        assertEq(_genesisPerChainData(forErc20Chain).baseTokenL1Address, address(erc20LocalToken));
    }

    // ────────────────────── equivalence with the retired composition ──────────────────────

    /// @dev The refactoring must be observably a no-op: the transaction is byte-identical to what
    ///      the pre-refactor struct literal and metadata probe produced for the same inputs (see
    ///      {LegacyGenesisComposition}).
    function test_genesisUpgradeTx_isByteIdenticalToTheRetiredComposition() public {
        uint256[4] memory chainIds = [ETH_CHAIN_ID, ERC20_CHAIN_ID, NO_METADATA_CHAIN_ID, BYTES32_METADATA_CHAIN_ID];
        bytes32[4] memory assetIds = [
            ETH_BASE_TOKEN_ASSET_ID,
            ERC20_BASE_TOKEN_ASSET_ID,
            NO_METADATA_BASE_TOKEN_ASSET_ID,
            BYTES32_METADATA_BASE_TOKEN_ASSET_ID
        ];
        for (uint256 i = 0; i < chainIds.length; ++i) {
            L2CanonicalTransaction memory legacyTx = LegacyGenesisComposition.genesisUpgradeTx({
                _bridgehub: mockBridgehub,
                _chainId: chainIds[i],
                _baseTokenAssetId: assetIds[i],
                _protocolVersion: protocolVersion,
                _fixedForceDeploymentsData: FIXED_FORCE_DEPLOYMENTS_DATA
            });

            assertEq(
                abi.encode(_composedGenesisTx(chainIds[i])),
                abi.encode(legacyTx),
                "the genesis transaction changed"
            );
        }
    }

    /// @dev The two paths agree on the nonce for a reason, not by coincidence: the shared
    ///      `protocolUpgradeNonce` is `major << 32 | minor`, and genesis rejects a non-zero major,
    ///      so it equals the bare minor version the retired code used.
    function test_genesisUpgradeTx_nonceIsTheMinorVersion() public {
        uint256 version = SemVer.packSemVer(0, 27, 5);

        // slither-disable-next-line unused-return
        (, uint32 minorVersion, ) = SemVer.unpackSemVer(uint96(version));
        assertEq(
            engine.genesisUpgradeTx(address(release), mockBridgehub, ETH_CHAIN_ID, version).nonce,
            minorVersion,
            "the shared nonce must equal the minor version genesis used"
        );
    }

    // ─────────────────────── the envelope the two paths share ───────────────────────

    /// @dev Genesis and a registry-driven upgrade differ ONLY in the call the `L2ComplexUpgrader`
    ///      performs (and the factory deps an upgrade plan carries). Every other field of the
    ///      canonical transaction comes from the one shared envelope.
    function test_genesisAndUpgradePathsShareTheEnvelope() public {
        DummyDefaultUpgradeForGenesis upgradeEngine = new DummyDefaultUpgradeForGenesis();
        CTMTransition transition = _transition(
            _release(_departingFacets(), _pinned("fromVerifier")),
            release,
            0,
            protocolVersion,
            0,
            address(upgradeEngine),
            _v34Plan()
        );

        L2CanonicalTransaction memory genesisTx = _composedGenesisTx(ETH_CHAIN_ID);
        L2CanonicalTransaction memory upgradeTx = upgradeEngine.l2UpgradeTx(
            address(transition),
            mockBridgehub,
            ETH_CHAIN_ID
        );

        assertEq(genesisTx.txType, upgradeTx.txType, "txType");
        assertEq(genesisTx.from, upgradeTx.from, "from");
        assertEq(genesisTx.to, upgradeTx.to, "to");
        assertEq(genesisTx.gasLimit, upgradeTx.gasLimit, "gasLimit");
        assertEq(genesisTx.gasPerPubdataByteLimit, upgradeTx.gasPerPubdataByteLimit, "gasPerPubdataByteLimit");
        assertEq(genesisTx.maxFeePerGas, upgradeTx.maxFeePerGas, "maxFeePerGas");
        assertEq(genesisTx.maxPriorityFeePerGas, upgradeTx.maxPriorityFeePerGas, "maxPriorityFeePerGas");
        assertEq(genesisTx.paymaster, upgradeTx.paymaster, "paymaster");
        assertEq(genesisTx.nonce, upgradeTx.nonce, "nonce");
        assertEq(genesisTx.value, upgradeTx.value, "value");
        assertEq(abi.encode(genesisTx.reserved), abi.encode(upgradeTx.reserved), "reserved");
        assertEq(genesisTx.signature, upgradeTx.signature, "signature");
        assertEq(genesisTx.paymasterInput, upgradeTx.paymasterInput, "paymasterInput");
        assertEq(genesisTx.reservedDynamic, upgradeTx.reservedDynamic, "reservedDynamic");
        // The inner call is the deliberate difference, and it is preserved: both decoders below
        // reject a payload that is not the call shape they name.
        (address genesisDelegateTo, ) = this.decodeComplexUpgraderUpgrade(genesisTx.data);
        assertEq(genesisDelegateTo, L2_GENESIS_UPGRADE_ADDR, "genesis installs through the L2 genesis upgrade");
        // slither-disable-next-line unused-return
        this.decodeUniversalCall(upgradeTx.data);
    }

    /// @dev Release equivalence: a chain created at release R and a chain upgraded to R receive the
    ///      same contract set — the same pinned fixed blob, the same CTM deployment tracker and the
    ///      same per-chain data — even though the calls that carry them differ.
    function test_creatingAtAReleaseInstallsWhatUpgradingToItInstalls() public {
        DummyDefaultUpgradeForGenesis upgradeEngine = new DummyDefaultUpgradeForGenesis();
        CTMTransition transition = _transition(
            _release(_departingFacets(), _pinned("fromVerifierForEquivalence")),
            release,
            0,
            protocolVersion,
            0,
            address(upgradeEngine),
            _v34Plan()
        );

        (
            uint256 genesisChainId,
            address genesisDeployer,
            bytes memory genesisFixed,
            bytes memory genesisPerChain
        ) = this.decodeGenesisUpgrade(_innerCalldata(_composedGenesisTx(ERC20_CHAIN_ID).data));
        (address upgradeDeployer, bytes memory upgradeFixed, bytes memory upgradePerChain) = this.decodeV34Upgrade(
            _delegateCalldata(upgradeEngine.l2UpgradeTx(address(transition), mockBridgehub, ERC20_CHAIN_ID).data)
        );

        assertEq(genesisChainId, ERC20_CHAIN_ID, "the genesis call names the chain it is composed for");
        assertEq(genesisDeployer, upgradeDeployer, "the CTM deployment tracker must match");
        assertEq(genesisFixed, upgradeFixed, "the release's pinned force-deployments must match");
        assertEq(genesisPerChain, upgradePerChain, "the per-chain data must match");
        assertEq(genesisFixed, FIXED_FORCE_DEPLOYMENTS_DATA, "and it is the release's own blob");
    }

    // ─────────────────────────── base-token tolerance ───────────────────────────

    /// @dev A chain created on a base token that serves no metadata: genesis composes the ERC20
    ///      defaults rather than reverting, and the upgrade path recomposes exactly the same data,
    ///      so such a chain is upgradeable afterwards.
    function test_aBaseTokenWithoutMetadataComposesOnBothPaths() public {
        _assertTolerated(NO_METADATA_CHAIN_ID, address(noMetadataToken));
    }

    /// @dev The same for a Maker-style token whose `name()`/`symbol()` answer with a `bytes32`.
    function test_aBytes32MetadataBaseTokenComposesOnBothPaths() public {
        _assertTolerated(BYTES32_METADATA_CHAIN_ID, address(bytes32MetadataToken));
    }

    /// @dev The genesis path and the upgrade path both compose for `_chainId`, and both land on the
    ///      defaults — which is what keeps the chain's L2 base-token metadata stable across the
    ///      upgrade that rewrites it.
    function _assertTolerated(uint256 _chainId, address _token) internal {
        ZKChainSpecificForceDeploymentsData memory genesisData = _genesisPerChainData(_composedGenesisTx(_chainId));
        ZKChainSpecificForceDeploymentsData memory upgradeData = abi.decode(
            _upgradePathPerChainData(_chainId),
            (ZKChainSpecificForceDeploymentsData)
        );

        assertEq(genesisData.baseTokenL1Address, _token, "the token is recorded even without metadata");
        assertEq(genesisData.baseTokenMetadata.name, DEFAULT_BASE_TOKEN_NAME, "wrong default name");
        assertEq(genesisData.baseTokenMetadata.symbol, DEFAULT_BASE_TOKEN_SYMBOL, "wrong default symbol");
        assertEq(genesisData.baseTokenMetadata.decimals, COMPOSED_DECIMALS, "wrong default decimals");
        assertEq(abi.encode(genesisData), abi.encode(upgradeData), "the two paths must compose the same data");
    }

    // ─────────────────────────── genesis-only execution rules ───────────────────────────

    /// @dev Genesis refuses to overwrite an outstanding upgrade transaction: the chain would
    ///      otherwise silently skip it.
    function test_revertWhen_aPreviousUpgradeTransactionIsStillPending() public {
        bytes32 pendingHash = bytes32(bytes("pendingUpgradeTx"));
        engine.setL2SystemContractsUpgradeTxHash(pendingHash);

        vm.expectRevert(abi.encodeWithSelector(PreviousUpgradeNotFinalized.selector, pendingHash));
        engine.genesisUpgrade();
    }

    /// @dev And it refuses while the batch of a previous upgrade has not been cleared either.
    function test_revertWhen_aPreviousUpgradeBatchIsNotCleared() public {
        engine.setL2SystemContractsUpgradeBatchNumber(7);

        vm.expectRevert(abi.encodeWithSelector(PreviousUpgradeBatchNotCleared.selector));
        engine.genesisUpgrade();
    }

    // ─────────────────────────── helpers ───────────────────────────

    /// @dev The per-chain half of a composed GENESIS payload (the upgrade-path reader in the shared
    ///      fixture unwraps the other inner call).
    function _genesisPerChainData(
        L2CanonicalTransaction memory _transaction
    ) internal view returns (ZKChainSpecificForceDeploymentsData memory) {
        (, , , bytes memory perChainData) = this.decodeGenesisUpgrade(_innerCalldata(_transaction.data));
        return abi.decode(perChainData, (ZKChainSpecificForceDeploymentsData));
    }

    /// @dev What the v34 delegate composer produces for `_chainId` at the same release — the
    ///      upgrade path's answer to the same question genesis answers.
    function _upgradePathPerChainData(uint256 _chainId) internal view returns (bytes memory) {
        (, , bytes memory perChainData) = this.decodeV34Upgrade(
            v34Composer.composeDelegateCalldata(release, mockBridgehub, _chainId)
        );
        return perChainData;
    }

    /// @dev The calldata inside a composed `IComplexUpgrader.upgrade` payload.
    function _innerCalldata(bytes memory _txData) internal view returns (bytes memory innerCalldata) {
        (, innerCalldata) = this.decodeComplexUpgraderUpgrade(_txData);
    }

    /// @dev Decodes an `IComplexUpgrader.upgrade` payload; external so the selector can be sliced.
    function decodeComplexUpgraderUpgrade(
        bytes calldata _data
    ) external pure returns (address delegateTo, bytes memory delegateCalldata) {
        require(bytes4(_data[:4]) == IComplexUpgrader.upgrade.selector, "not a ComplexUpgrader.upgrade payload");
        return abi.decode(_data[4:], (address, bytes));
    }

    /// @dev Decodes an `IL2GenesisUpgrade.genesisUpgrade` call into its arguments.
    function decodeGenesisUpgrade(
        bytes calldata _data
    ) external pure returns (uint256 chainId, address ctmDeployer, bytes memory fixedData, bytes memory perChainData) {
        require(bytes4(_data[:4]) == IL2GenesisUpgrade.genesisUpgrade.selector, "not a genesisUpgrade call");
        return abi.decode(_data[4:], (uint256, address, bytes, bytes));
    }
}
