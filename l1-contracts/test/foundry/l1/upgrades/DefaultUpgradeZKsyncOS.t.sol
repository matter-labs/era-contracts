// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DefaultUpgradeZKsyncOS} from "contracts/upgrades/DefaultUpgradeZKsyncOS.sol";
import {IL2V32Upgrade} from "contracts/upgrades/IL2V32Upgrade.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {ZKChainSpecificForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";
import {ETH_TOKEN_ADDRESS, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {UnexpectedUpgradeSelector} from "contracts/common/L1ContractErrors.sol";
import {UnexpectedZKsyncOSFlag} from "contracts/upgrades/ZkSyncUpgradeErrors.sol";
import {NotAllBatchesExecuted} from "contracts/state-transition/L1StateTransitionErrors.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";

contract DummyDefaultUpgradeZKsyncOS is DefaultUpgradeZKsyncOS, BaseUpgradeUtils {
    function setBridgehub(address _bridgehub) public {
        s.bridgehub = _bridgehub;
    }

    function setChainId(uint256 _chainId) public {
        s.chainId = _chainId;
    }

    function setZKsyncOS(bool _zksyncOS) public {
        s.zksyncOS = _zksyncOS;
    }

    function setBatchCounters(uint256 _committed, uint256 _executed) public {
        s.totalBatchesCommitted = _committed;
        s.totalBatchesExecuted = _executed;
    }

    function getL2SystemContractsUpgradeTxHash() public view returns (bytes32) {
        return s.l2SystemContractsUpgradeTxHash;
    }
}

/// @notice Unit tests for the ZKsync OS per-chain upgrade: the outstanding-batches precondition it enforces
///         before the generic upgrade runs, and the per-chain force-deployments-data substitution it does.
/// @dev The ecosystem contracts the substitution reads (bridgehub, asset router, native token vault) are
///      mocked: the behaviour under test is which values end up in the rewritten transaction, not how the
///      vault stores them. The end-to-end composition is covered by the anvil `v31 -> v32` scenario.
contract DefaultUpgradeZKsyncOSTest is BaseUpgrade {
    DummyDefaultUpgradeZKsyncOS internal upgradeContract;

    address internal mockChainTypeManager = makeAddr("mockChainTypeManager");
    address internal mockVerifier = makeAddr("mockVerifier");
    address internal mockBridgehub = makeAddr("mockBridgehub");
    address internal mockAssetRouter = makeAddr("mockAssetRouter");
    address internal mockNativeTokenVault = makeAddr("mockNativeTokenVault");
    address internal ctmDeployer = makeAddr("ctmDeployer");
    address internal delegateTo = makeAddr("l2V32UpgradeDelegate");

    uint256 internal constant CHAIN_ID = 271;
    uint256 internal constant BASE_TOKEN_ORIGIN_CHAIN_ID = 1;
    bytes32 internal constant BASE_TOKEN_ASSET_ID = keccak256("baseTokenAssetId");
    bytes internal constant FIXED_FORCE_DEPLOYMENTS_DATA = hex"c0ffee";

    function setUp() public {
        upgradeContract = new DummyDefaultUpgradeZKsyncOS();

        _prepareProposedUpgrade();

        upgradeContract.setPriorityTxMaxGasLimit(1 ether);
        upgradeContract.setPriorityTxMaxPubdata(1000000);
        upgradeContract.setChainTypeManager(mockChainTypeManager);
        upgradeContract.mockProtocolVersionVerifier(protocolVersion, mockVerifier);

        upgradeContract.setBridgehub(mockBridgehub);
        upgradeContract.setChainId(CHAIN_ID);
        upgradeContract.setZKsyncOS(true);
        // The default shape: every committed batch processed.
        upgradeContract.setBatchCounters(7, 7);
        _mockEcosystemForSubstitution();

        proposedUpgrade.l2ProtocolUpgradeTx.data = _placeholderUpgradeTxData();
        // ZKsync OS chains use their own system-upgrade transaction type.
        proposedUpgrade.l2ProtocolUpgradeTx.txType = ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE;
    }

    function test_upgradesWhenEveryCommittedBatchIsProcessed() public {
        bytes32 result = upgradeContract.upgrade(proposedUpgrade);

        assertEq(result, Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);
        assertEq(upgradeContract.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
    }

    /// @dev Includes the fresh-chain boundary (0/0), where a chain has committed nothing yet.
    function testFuzz_outstandingBatchesGuard(uint256 _committed, uint256 _executed) public {
        _committed = bound(_committed, 0, type(uint128).max);
        _executed = bound(_executed, 0, _committed);
        upgradeContract.setBatchCounters(_committed, _executed);

        if (_committed != _executed) {
            vm.expectRevert(NotAllBatchesExecuted.selector);
            upgradeContract.upgrade(proposedUpgrade);
        } else {
            assertEq(upgradeContract.upgrade(proposedUpgrade), Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);
        }
    }

    /// @notice `upgrade()` must record the rewritten transaction, not the placeholder it was handed. This is
    ///         the whole point of the contract, so it is asserted through `upgrade()` rather than through a
    ///         direct `getL2UpgradeTxData` call.
    function test_upgradeRecordsTheRewrittenTransaction() public {
        L2CanonicalTransaction memory expectedTx = proposedUpgrade.l2ProtocolUpgradeTx;
        bytes32 placeholderHash = keccak256(abi.encode(expectedTx));
        expectedTx.data = upgradeContract.getL2UpgradeTxData(mockBridgehub, CHAIN_ID, true, expectedTx.data);

        upgradeContract.upgrade(proposedUpgrade);

        bytes32 recorded = upgradeContract.getL2SystemContractsUpgradeTxHash();
        assertEq(recorded, keccak256(abi.encode(expectedTx)), "the placeholder tx was recorded");
        assertTrue(recorded != placeholderHash, "rewrite produced the placeholder");
    }

    /// @notice A verifier-only upgrade carries no L2 upgrade transaction, so there is nothing to substitute and
    ///         the rewrite — which would reject the empty transaction data — must be skipped.
    function test_upgradeWithoutAnL2TransactionSkipsTheRewrite() public {
        assertEq(upgradeContract.upgradeVerifierOnly(protocolVersion), Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);

        assertEq(upgradeContract.getProtocolVersion(), protocolVersion);
        assertEq(upgradeContract.getVerifier(), mockVerifier);
        assertEq(upgradeContract.getL2SystemContractsUpgradeTxHash(), bytes32(0), "an upgrade tx was recorded");
    }

    /// @dev The generic upgrade installs the new protocol version's verifier, a freshly deployed contract in
    ///      this release, so batches still awaiting proof under the old one would stop being provable.
    function test_revertWhen_aCommittedBatchIsNotProcessed() public {
        upgradeContract.setBatchCounters(8, 7);

        vm.expectRevert(NotAllBatchesExecuted.selector);
        upgradeContract.upgrade(proposedUpgrade);
    }

    function test_revertWhen_theOuterSelectorIsNotForceDeployAndUpgradeUniversal() public {
        bytes memory wrongOuter = abi.encodeCall(IL2V32Upgrade.upgrade, (true, ctmDeployer, hex"", hex""));

        vm.expectRevert(UnexpectedUpgradeSelector.selector);
        upgradeContract.getL2UpgradeTxData(mockBridgehub, CHAIN_ID, true, wrongOuter);
    }

    function test_revertWhen_theWrappedCalldataIsNotTheL2Upgrade() public {
        bytes memory wrongInner = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgradeUniversal,
            (
                new IComplexUpgrader.UniversalContractUpgradeInfo[](0),
                delegateTo,
                abi.encodeCall(
                    IComplexUpgrader.forceDeployAndUpgradeUniversal,
                    (new IComplexUpgrader.UniversalContractUpgradeInfo[](0), delegateTo, hex"")
                )
            )
        );

        vm.expectRevert(UnexpectedUpgradeSelector.selector);
        upgradeContract.getL2UpgradeTxData(mockBridgehub, CHAIN_ID, true, wrongInner);
    }

    /// @dev This contract only serves ZKsync OS chains, so a caller claiming otherwise is rejected.
    function test_revertWhen_theCallerSaysTheChainIsNotZKsyncOS() public {
        vm.expectRevert(abi.encodeWithSelector(UnexpectedZKsyncOSFlag.selector, true, false));
        upgradeContract.getL2UpgradeTxData(mockBridgehub, CHAIN_ID, false, _placeholderUpgradeTxData());
    }

    /// @dev The flag encoded in the ecosystem-wide transaction must agree with the chain being upgraded.
    function test_revertWhen_theWrappedFlagDisagreesWithTheChain() public {
        bytes memory eraShapedInner = abi.encodeCall(
            IL2V32Upgrade.upgrade,
            (false, ctmDeployer, FIXED_FORCE_DEPLOYMENTS_DATA, hex"00")
        );
        bytes memory placeholder = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgradeUniversal,
            (new IComplexUpgrader.UniversalContractUpgradeInfo[](0), delegateTo, eraShapedInner)
        );

        vm.expectRevert(abi.encodeWithSelector(UnexpectedZKsyncOSFlag.selector, true, false));
        upgradeContract.getL2UpgradeTxData(mockBridgehub, CHAIN_ID, true, placeholder);
    }

    /// @notice The placeholder per-chain data is replaced with this chain's, and nothing else in the
    ///         ecosystem-wide transaction changes.
    function test_substitutesThisChainsForceDeploymentsData() public {
        bytes memory placeholder = _placeholderUpgradeTxData();

        bytes memory rewritten = upgradeContract.getL2UpgradeTxData(mockBridgehub, CHAIN_ID, true, placeholder);

        assertTrue(keccak256(rewritten) != keccak256(placeholder), "the placeholder was not substituted");
        assertEq(bytes4(rewritten), IComplexUpgrader.forceDeployAndUpgradeUniversal.selector);

        (
            IComplexUpgrader.UniversalContractUpgradeInfo[] memory forceDeployments,
            address rewrittenDelegateTo,
            bytes memory innerCalldata
        ) = abi.decode(_sliceSelector(rewritten), (IComplexUpgrader.UniversalContractUpgradeInfo[], address, bytes));

        // The ecosystem-wide parts are carried over untouched.
        assertEq(forceDeployments.length, 0, "force deployments changed");
        assertEq(rewrittenDelegateTo, delegateTo, "delegate target changed");
        assertEq(bytes4(innerCalldata), IL2V32Upgrade.upgrade.selector);

        (bool isZKsyncOS, address rewrittenCtmDeployer, bytes memory fixedData, bytes memory perChainData) = abi.decode(
            _sliceSelector(innerCalldata),
            (bool, address, bytes, bytes)
        );
        assertTrue(isZKsyncOS, "chain type changed");
        assertEq(rewrittenCtmDeployer, ctmDeployer, "ctm deployer changed");
        assertEq(fixedData, FIXED_FORCE_DEPLOYMENTS_DATA, "ecosystem-wide data changed");

        // Only the per-chain half is rebuilt, from this chain's base token.
        ZKChainSpecificForceDeploymentsData memory data = abi.decode(
            perChainData,
            (ZKChainSpecificForceDeploymentsData)
        );
        assertEq(data.baseTokenBridgingData.assetId, BASE_TOKEN_ASSET_ID, "wrong base token asset id");
        assertEq(data.baseTokenBridgingData.originChainId, BASE_TOKEN_ORIGIN_CHAIN_ID, "wrong origin chain");
        assertEq(data.baseTokenBridgingData.originToken, ETH_TOKEN_ADDRESS, "wrong origin token");
        assertEq(data.baseTokenL1Address, ETH_TOKEN_ADDRESS, "wrong L1 base token address");
        assertEq(data.baseTokenMetadata.symbol, "ETH", "wrong base token symbol");
        assertEq(data.baseTokenMetadata.decimals, 18, "wrong base token decimals");
    }

    /// @notice For a chain whose base token is not ETH the metadata comes from the token's local bridged
    ///         representation (`tokenAddress`), not from `originToken`, which may have no code on L1.
    function test_readsBaseTokenMetadataFromTheLocalTokenForABridgedBaseToken() public {
        address originToken = makeAddr("originTokenOnItsOwnChain");
        address localToken = makeAddr("localBridgedToken");
        uint256 originChainId = 271;

        vm.mockCall(
            mockNativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originToken.selector, BASE_TOKEN_ASSET_ID),
            abi.encode(originToken)
        );
        vm.mockCall(
            mockNativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originChainId.selector, BASE_TOKEN_ASSET_ID),
            abi.encode(originChainId)
        );
        vm.mockCall(
            mockNativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.tokenAddress.selector, BASE_TOKEN_ASSET_ID),
            abi.encode(localToken)
        );
        vm.mockCall(localToken, abi.encodeWithSelector(IERC20Metadata.name.selector), abi.encode("Local Token"));
        vm.mockCall(localToken, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode("LOC"));
        vm.mockCall(localToken, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(6)));

        ZKChainSpecificForceDeploymentsData memory data = _decodePerChainData(
            upgradeContract.getL2UpgradeTxData(mockBridgehub, CHAIN_ID, true, _placeholderUpgradeTxData())
        );

        assertEq(data.baseTokenMetadata.name, "Local Token", "metadata not read from the local token");
        assertEq(data.baseTokenMetadata.symbol, "LOC", "wrong symbol");
        assertEq(data.baseTokenMetadata.decimals, 6, "wrong decimals");
        // The bridging data still describes the token on its origin chain.
        assertEq(data.baseTokenL1Address, originToken, "wrong L1 base token address");
        assertEq(data.baseTokenBridgingData.originToken, originToken, "wrong origin token");
        assertEq(data.baseTokenBridgingData.originChainId, originChainId, "wrong origin chain");
    }

    /// @dev The chain the transaction is rewritten for is read from diamond storage, so two chains of the
    ///      same ecosystem must not receive the same per-chain payload.
    function test_substitutionIsPerChain() public {
        uint256 otherChainId = CHAIN_ID + 1;
        bytes32 otherAssetId = keccak256("otherBaseTokenAssetId");
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, otherChainId),
            abi.encode(otherAssetId)
        );
        _mockBaseToken(otherAssetId, BASE_TOKEN_ORIGIN_CHAIN_ID);

        bytes memory placeholder = _placeholderUpgradeTxData();
        bytes memory forThisChain = upgradeContract.getL2UpgradeTxData(mockBridgehub, CHAIN_ID, true, placeholder);
        bytes memory forOtherChain = upgradeContract.getL2UpgradeTxData(mockBridgehub, otherChainId, true, placeholder);

        assertEq(
            _decodePerChainData(forThisChain).baseTokenBridgingData.assetId,
            BASE_TOKEN_ASSET_ID,
            "this chain's payload must carry its own base-token asset id"
        );
        assertEq(
            _decodePerChainData(forOtherChain).baseTokenBridgingData.assetId,
            otherAssetId,
            "the other chain's payload must carry the other base-token asset id"
        );
    }

    function _decodePerChainData(
        bytes memory _rewritten
    ) internal pure returns (ZKChainSpecificForceDeploymentsData memory) {
        (, , bytes memory innerCalldata) = abi.decode(
            _sliceSelector(_rewritten),
            (IComplexUpgrader.UniversalContractUpgradeInfo[], address, bytes)
        );
        (, , , bytes memory perChainData) = abi.decode(_sliceSelector(innerCalldata), (bool, address, bytes, bytes));
        return abi.decode(perChainData, (ZKChainSpecificForceDeploymentsData));
    }

    function _placeholderUpgradeTxData() internal view returns (bytes memory) {
        bytes memory innerCalldata = abi.encodeCall(
            IL2V32Upgrade.upgrade,
            (true, ctmDeployer, FIXED_FORCE_DEPLOYMENTS_DATA, hex"00")
        );
        return
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (new IComplexUpgrader.UniversalContractUpgradeInfo[](0), delegateTo, innerCalldata)
            );
    }

    function _mockEcosystemForSubstitution() internal {
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehubBase.assetRouter.selector),
            abi.encode(mockAssetRouter)
        );
        vm.mockCall(
            mockAssetRouter,
            abi.encodeWithSelector(IL1AssetRouter.nativeTokenVault.selector),
            abi.encode(mockNativeTokenVault)
        );
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, CHAIN_ID),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );
        _mockBaseToken(BASE_TOKEN_ASSET_ID, BASE_TOKEN_ORIGIN_CHAIN_ID);
    }

    function _mockBaseToken(bytes32 _assetId, uint256 _originChainId) internal {
        vm.mockCall(
            mockNativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originToken.selector, _assetId),
            abi.encode(ETH_TOKEN_ADDRESS)
        );
        vm.mockCall(
            mockNativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originChainId.selector, _assetId),
            abi.encode(_originChainId)
        );
    }

    function _sliceSelector(bytes memory _data) internal pure returns (bytes memory sliced) {
        sliced = new bytes(_data.length - 4);
        for (uint256 i = 0; i < sliced.length; ++i) {
            sliced[i] = _data[i + 4];
        }
    }
}
