// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {MockSelfDescribingFacet} from "contracts/dev-contracts/test/MockSelfDescribingFacet.sol";
import {FixedDelegateCalldataComposer} from "contracts/dev-contracts/FixedDelegateCalldataComposer.sol";
import {L2V34DelegateCalldataComposer} from "contracts/upgrades/L2V34DelegateCalldataComposer.sol";
import {IL2V34Upgrade} from "contracts/upgrades/IL2V34Upgrade.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {ZKChainSpecificForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {L2CanonicalTransactionLib} from "contracts/state-transition/libraries/L2CanonicalTransactionLib.sol";
import {L2CanonicalTransaction, TokenBridgingData, TokenMetadata} from "contracts/common/Messaging.sol";
import {
    ETH_TOKEN_ADDRESS,
    PRIORITY_TX_MAX_GAS_LIMIT,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE
} from "contracts/common/Config.sol";
import {L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SEMVER_MINOR_OFFSET} from "contracts/common/libraries/SemVer.sol";
import {
    AuthoredL2Plan,
    BootstrapManifest,
    GenesisFacet,
    L2UpgradePlan,
    PinnedContract,
    ProxyUpgradeRow,
    ReleaseGenesisData,
    ReleaseManifest,
    TransitionManifest
} from "contracts/upgrades/registry/RegistryTypes.sol";
import {
    CTM_CONTRACT_COUNT,
    CTMContract,
    L2_ECOSYSTEM_CONTRACT_COUNT
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {L2PlanFixtures} from "foundry-test/l1/unit/concrete/upgrades/registry/L2PlanFixtures.sol";

/// @notice Real, minimal registry objects for the upgrade-engine unit tests: two releases that
///         differ in one facet and their verifier, the transition between them, and a bootstrap
///         manifest toward one of them. Everything an engine reads at execution is a real
///         write-once object; only the CTM-side authorities a manifest has to name (CTM, admins,
///         executors, timer) are labelled stand-ins the engine never touches.
abstract contract RegistryObjectsFixture is Test {
    // Real self-describing facets — the routing the registry objects read and the engines apply.
    address internal facetShared; // in both releases
    address internal facetDeparting; // only in the departing release
    address internal facetArriving; // only in the target release
    /// @dev A real DiamondInit, the one every fixture release pins.
    address internal diamondInit;
    address internal genesisUpgradeStub;
    address internal upgradeTimerStub;
    address internal ctmStub;
    /// @dev Returns `fixtureDelegateCalldata` regardless of its inputs — the stand-in for a
    ///      version-specific composer, so plans can pin a real composer without an L2 migration.
    FixedDelegateCalldataComposer internal delegateComposer;
    bytes internal fixtureDelegateCalldata;

    /// @dev The REAL v34 composer, for the per-chain composition tests. The ecosystem it reads
    ///      through the Bridgehub — the CTM deployer, the asset router and the native token vault —
    ///      is mocked by {_mockEcosystemForComposer}: this fixture has no live vault, and what is
    ///      under test is which values land in the composed transaction, not how the vault stores
    ///      them. The ERC20 base token IS real, since its metadata is what the composer reads.
    L2V34DelegateCalldataComposer internal v34Composer;
    address internal mockAssetRouter = makeAddr("mockAssetRouter");
    address internal mockNativeTokenVault = makeAddr("mockNativeTokenVault");
    address internal ctmDeployerStub = makeAddr("ctmDeployer");
    address internal erc20OriginToken = makeAddr("erc20OriginToken");
    TestnetERC20Token internal erc20LocalToken;

    bytes4 internal constant SEL_SHARED_A = bytes4(uint32(0x11));
    bytes4 internal constant SEL_SHARED_B = bytes4(uint32(0x12));
    bytes4 internal constant SEL_DEPARTING = bytes4(uint32(0x21));
    bytes4 internal constant SEL_ARRIVING = bytes4(uint32(0x31));

    /// @dev Dummy EVM bytecode standing in for the authored L2 upgrade delegate (see {L2PlanFixtures}).
    bytes internal constant DELEGATE_CODE = hex"aa01";
    /// @dev The fixed force-deployments blob every fixture release pins.
    bytes internal constant FIXED_FORCE_DEPLOYMENTS_DATA = hex"f1f2";

    // The two chains the mocked ecosystem knows: one ETH-based, one whose base token is an ERC20
    // bridged from another chain (so its metadata lives on a LOCAL representation).
    uint256 internal constant ETH_CHAIN_ID = 271;
    uint256 internal constant ERC20_CHAIN_ID = 272;
    uint256 internal constant ETH_ORIGIN_CHAIN_ID = 1;
    uint256 internal constant ERC20_ORIGIN_CHAIN_ID = 300;
    bytes32 internal constant ETH_BASE_TOKEN_ASSET_ID = keccak256("ethBaseTokenAssetId");
    bytes32 internal constant ERC20_BASE_TOKEN_ASSET_ID = keccak256("erc20BaseTokenAssetId");
    string internal constant ERC20_NAME = "Local Token";
    string internal constant ERC20_SYMBOL = "LOC";
    uint256 internal constant ERC20_DECIMALS = 6;

    function _setUpRegistryObjects(bytes memory _delegateCalldata) internal {
        fixtureDelegateCalldata = _delegateCalldata;
        facetShared = address(new MockSelfDescribingFacet(_selectors2(SEL_SHARED_A, SEL_SHARED_B)));
        facetDeparting = address(new MockSelfDescribingFacet(_selectors1(SEL_DEPARTING)));
        facetArriving = address(new MockSelfDescribingFacet(_selectors1(SEL_ARRIVING)));
        diamondInit = address(new DiamondInit());
        genesisUpgradeStub = _pinned("genesisUpgrade");
        upgradeTimerStub = _pinned("upgradeTimer");
        ctmStub = makeAddr("ctm");
        delegateComposer = new FixedDelegateCalldataComposer(_delegateCalldata);
        v34Composer = new L2V34DelegateCalldataComposer();
        erc20LocalToken = new TestnetERC20Token(ERC20_NAME, ERC20_SYMBOL, uint8(ERC20_DECIMALS));
    }

    /// @dev Mocks the ecosystem behind `_bridgehub` for the two fixture chains (see {v34Composer}).
    function _mockEcosystemForComposer(address _bridgehub, address _ctmDeployer) internal {
        vm.mockCall(_bridgehub, abi.encodeCall(IBridgehubBase.l1CtmDeployer, ()), abi.encode(_ctmDeployer));
        vm.mockCall(_bridgehub, abi.encodeCall(IBridgehubBase.assetRouter, ()), abi.encode(mockAssetRouter));
        vm.mockCall(
            mockAssetRouter,
            abi.encodeCall(IL1AssetRouter.nativeTokenVault, ()),
            abi.encode(mockNativeTokenVault)
        );
        _mockBaseToken(
            _bridgehub,
            ETH_CHAIN_ID,
            ETH_BASE_TOKEN_ASSET_ID,
            ETH_TOKEN_ADDRESS,
            ETH_ORIGIN_CHAIN_ID,
            ETH_TOKEN_ADDRESS
        );
        _mockBaseToken(
            _bridgehub,
            ERC20_CHAIN_ID,
            ERC20_BASE_TOKEN_ASSET_ID,
            erc20OriginToken,
            ERC20_ORIGIN_CHAIN_ID,
            address(erc20LocalToken)
        );
    }

    function _mockBaseToken(
        address _bridgehub,
        uint256 _chainId,
        bytes32 _assetId,
        address _originToken,
        uint256 _originChainId,
        address _localToken
    ) internal {
        vm.mockCall(_bridgehub, abi.encodeCall(IBridgehubBase.baseTokenAssetId, (_chainId)), abi.encode(_assetId));
        vm.mockCall(
            mockNativeTokenVault,
            abi.encodeCall(INativeTokenVaultBase.originToken, (_assetId)),
            abi.encode(_originToken)
        );
        vm.mockCall(
            mockNativeTokenVault,
            abi.encodeCall(INativeTokenVaultBase.originChainId, (_assetId)),
            abi.encode(_originChainId)
        );
        vm.mockCall(
            mockNativeTokenVault,
            abi.encodeCall(INativeTokenVaultBase.tokenAddress, (_assetId)),
            abi.encode(_localToken)
        );
    }

    // ─────────────────────────────── objects ───────────────────────────────

    /// @dev A release pinning `_facets` (all non-freezable), `_verifier`, the fixture's DiamondInit
    ///      and an empty L2 table.
    function _release(address[] memory _facets, address _verifier) internal returns (CTMRelease) {
        GenesisFacet[] memory rows = new GenesisFacet[](_facets.length);
        for (uint256 i = 0; i < _facets.length; ++i) {
            rows[i] = GenesisFacet({facet: _pin(_facets[i]), isFreezable: false});
        }
        return
            new CTMRelease(
                ReleaseManifest({
                    diamondInit: _pin(diamondInit),
                    verifier: _pin(_verifier),
                    genesisUpgrade: _pin(genesisUpgradeStub),
                    genesisFacets: rows,
                    genesis: ReleaseGenesisData({
                        fixedForceDeploymentsData: FIXED_FORCE_DEPLOYMENTS_DATA,
                        genesisBatchHash: bytes32(uint256(1)),
                        genesisBatchCommitment: bytes32(uint256(1)),
                        genesisIndexRepeatedStorageChanges: 54
                    }),
                    l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT),
                    l2SystemProxyBytecodeInfo: ""
                })
            );
    }

    function _departingFacets() internal view returns (address[] memory facets) {
        facets = new address[](2);
        facets[0] = facetShared;
        facets[1] = facetDeparting;
    }

    function _arrivingFacets() internal view returns (address[] memory facets) {
        facets = new address[](2);
        facets[0] = facetShared;
        facets[1] = facetArriving;
    }

    /// @dev No authored L2 side: an L1-only edge.
    function _emptyPlan() internal pure returns (AuthoredL2Plan memory) {
        return L2PlanFixtures.emptyPlan();
    }

    /// @dev The minimal authored L2 side: the delegate's bytecode info (the object constructs its
    ///      Unsafe deployment at the bytecode-derived address and pins its bytecode as the one
    ///      factory dependency) and the pinned composer defining its calldata.
    function _delegatePlan() internal view returns (AuthoredL2Plan memory) {
        return _planPinning(address(delegateComposer));
    }

    /// @dev {_delegatePlan} with the REAL v34 composer pinned in place of the fixed stand-in.
    function _v34Plan() internal view returns (AuthoredL2Plan memory) {
        return _planPinning(address(v34Composer));
    }

    function _planPinning(address _composer) internal view returns (AuthoredL2Plan memory) {
        return L2PlanFixtures.delegatePlan(DELEGATE_CODE, _pin(_composer));
    }

    function _transition(
        CTMRelease _fromRelease,
        CTMRelease _newRelease,
        uint256 _oldProtocolVersion,
        uint256 _newProtocolVersion,
        uint256 _upgradeTimestamp,
        address _upgradeEngine,
        AuthoredL2Plan memory _plan
    ) internal returns (CTMTransition) {
        return
            new CTMTransition(
                TransitionManifest({
                    oldProtocolVersion: _oldProtocolVersion,
                    newProtocolVersion: _newProtocolVersion,
                    fromRelease: address(_fromRelease),
                    newRelease: address(_newRelease),
                    upgradeEngine: _pin(_upgradeEngine),
                    proxyUpgrades: new ProxyUpgradeRow[](CTM_CONTRACT_COUNT),
                    oldProtocolVersionDeadline: type(uint256).max,
                    upgradeTimestamp: _upgradeTimestamp,
                    l2Plan: _plan,
                    upgradeTimer: _pin(upgradeTimerStub)
                })
            );
    }

    /// @dev A bootstrap manifest toward `_release`. The CTM-side authorities are labelled
    ///      stand-ins: the engine reads only the version edge, the schedule, the release and the
    ///      L2 plan; the one participating proxy row exists because the object refuses an edge
    ///      without implementation swaps.
    function _bootstrapManifest(
        CTMRelease _release,
        uint256 _oldProtocolVersion,
        uint256 _newProtocolVersion,
        uint256 _upgradeTimestamp,
        address _upgradeEngine,
        AuthoredL2Plan memory _plan
    ) internal returns (BootstrapManifest memory) {
        ProxyUpgradeRow[] memory rows = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        rows[uint256(CTMContract.ChainTypeManager)] = ProxyUpgradeRow({
            proxy: makeAddr("ctmProxy"),
            expectedOldImpl: makeAddr("ctmImplOld"),
            implNew: _pin(_pinned("ctmImplNew")),
            callInitializeUpgrade: false,
            admin: ProxyAdmin(address(0))
        });
        return
            BootstrapManifest({
                ctm: ctmStub,
                expectedProtocolVersion: _oldProtocolVersion,
                ctmProxyAdmin: ProxyAdmin(makeAddr("ctmProxyAdmin")),
                proxyUpgrades: rows,
                currentRelease: _pin(address(_release)),
                newProtocolVersion: _newProtocolVersion,
                oldProtocolVersionDeadline: type(uint256).max,
                upgradeEngine: _pin(_upgradeEngine),
                l2Plan: _plan,
                upgradeTimestamp: _upgradeTimestamp,
                ctmExecutor: _pin(_pinned("ctmExecutor")),
                ctmExecutorOwner: makeAddr("governor"),
                coordinator: makeAddr("coordinator"),
                upgradeTimer: _pin(upgradeTimerStub)
            });
    }

    // ─────────────────────────────── expectations ───────────────────────────────

    /// @dev The transaction the composer builds for a FINAL plan at `_newProtocolVersion` with the
    ///      fixed stand-in composer, assembled from the constants it reads rather than through the
    ///      library under test, so equality against it is a real check of the composition.
    function _expectedL2Tx(
        L2UpgradePlan memory _plan,
        uint256 _newProtocolVersion
    ) internal view returns (L2CanonicalTransaction memory) {
        return _expectedL2TxWithDelegateCalldata(_plan, _newProtocolVersion, fixtureDelegateCalldata);
    }

    /// @dev {_expectedL2Tx} for a plan pinning the REAL v34 composer: the delegate is called with
    ///      the release's fixed data and the per-chain data of `_chainId` read off the mocked
    ///      ecosystem.
    function _expectedV34L2Tx(
        L2UpgradePlan memory _plan,
        uint256 _newProtocolVersion,
        uint256 _chainId
    ) internal view returns (L2CanonicalTransaction memory) {
        return
            _expectedL2TxWithDelegateCalldata(
                _plan,
                _newProtocolVersion,
                abi.encodeCall(
                    IL2V34Upgrade.upgrade,
                    (ctmDeployerStub, FIXED_FORCE_DEPLOYMENTS_DATA, _expectedPerChainData(_chainId))
                )
            );
    }

    function _expectedL2TxWithDelegateCalldata(
        L2UpgradePlan memory _plan,
        uint256 _newProtocolVersion,
        bytes memory _delegateCalldata
    ) internal pure returns (L2CanonicalTransaction memory transaction) {
        transaction = L2CanonicalTransactionLib.emptyL2CanonicalTransaction();
        transaction.txType = ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE;
        transaction.from = uint256(uint160(L2_FORCE_DEPLOYER_ADDR));
        transaction.to = uint256(uint160(L2_COMPLEX_UPGRADER_ADDR));
        transaction.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        transaction.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        transaction.nonce = _newProtocolVersion >> SEMVER_MINOR_OFFSET;
        transaction.data = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgradeUniversal,
            (_plan.deployments, _plan.delegateTo, _delegateCalldata)
        );
        transaction.factoryDeps = _plan.factoryDepHashes;
    }

    /// @dev The `ZKChainSpecificForceDeploymentsData` of one of the two fixture chains, as the v34
    ///      composer must read it off the mocked ecosystem.
    function _expectedPerChainData(uint256 _chainId) internal view returns (bytes memory) {
        bool isEthChain = _chainId == ETH_CHAIN_ID;
        address originToken = isEthChain ? ETH_TOKEN_ADDRESS : erc20OriginToken;
        TokenMetadata memory metadata;
        if (isEthChain) {
            metadata = TokenMetadata({name: "Ether", symbol: "ETH", decimals: 18});
        } else {
            metadata = TokenMetadata({name: ERC20_NAME, symbol: ERC20_SYMBOL, decimals: ERC20_DECIMALS});
        }
        return
            abi.encode(
                ZKChainSpecificForceDeploymentsData({
                    l2LegacySharedBridge: address(0),
                    predeployedL2WethAddress: address(0),
                    baseTokenL1Address: originToken,
                    baseTokenMetadata: metadata,
                    baseTokenBridgingData: TokenBridgingData({
                        assetId: isEthChain ? ETH_BASE_TOKEN_ASSET_ID : ERC20_BASE_TOKEN_ASSET_ID,
                        originChainId: isEthChain ? ETH_ORIGIN_CHAIN_ID : ERC20_ORIGIN_CHAIN_ID,
                        originToken: originToken
                    })
                })
            );
    }

    // ─────────────────────────────── composed-payload readers ───────────────────────────────

    /// @dev The delegate calldata inside a composed `forceDeployAndUpgradeUniversal` payload.
    function _delegateCalldata(bytes memory _txData) internal view returns (bytes memory delegateCalldata) {
        (, , delegateCalldata) = this.decodeUniversalCall(_txData);
    }

    /// @dev The per-chain half of a composed v34 payload.
    function _perChainData(bytes memory _txData) internal view returns (ZKChainSpecificForceDeploymentsData memory) {
        (, , bytes memory perChainData) = this.decodeV34Upgrade(_delegateCalldata(_txData));
        return abi.decode(perChainData, (ZKChainSpecificForceDeploymentsData));
    }

    /// @dev Decodes a `forceDeployAndUpgradeUniversal` payload; external so the selector can be
    ///      sliced off calldata.
    function decodeUniversalCall(
        bytes calldata _data
    ) external pure returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory, address, bytes memory) {
        assertEq(
            bytes32(bytes4(_data[:4])),
            bytes32(IComplexUpgrader.forceDeployAndUpgradeUniversal.selector),
            "L2 tx selector"
        );
        return abi.decode(_data[4:], (IComplexUpgrader.UniversalContractUpgradeInfo[], address, bytes));
    }

    /// @dev Decodes an `IL2V34Upgrade.upgrade` call into its arguments.
    function decodeV34Upgrade(
        bytes calldata _data
    ) external pure returns (address ctmDeployer, bytes memory fixedData, bytes memory chainData) {
        assertEq(bytes32(bytes4(_data[:4])), bytes32(IL2V34Upgrade.upgrade.selector), "delegate selector");
        return abi.decode(_data[4:], (address, bytes, bytes));
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    /// @dev Deploys a distinct-bytecode stand-in at a labelled address so EXTCODEHASH pins are
    ///      real (an empty address would pin the zero hash).
    function _pinned(string memory _name) internal returns (address addr) {
        addr = makeAddr(_name);
        vm.etch(addr, bytes.concat(hex"00", bytes(_name)));
    }

    function _pin(address _addr) internal view returns (PinnedContract memory) {
        return PinnedContract({addr: _addr, codehash: _addr.codehash});
    }

    function _noPin() internal pure returns (PinnedContract memory) {
        return PinnedContract({addr: address(0), codehash: bytes32(0)});
    }

    function _selectors1(bytes4 _a) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = _a;
    }

    function _selectors2(bytes4 _a, bytes4 _b) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = _a;
        selectors[1] = _b;
    }
}
