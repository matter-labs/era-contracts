// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {BaseZkSyncUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {DefaultUpgradeZKsyncOS} from "contracts/upgrades/DefaultUpgradeZKsyncOS.sol";
import {V34UpgradeZKsyncOS} from "contracts/upgrades/V34UpgradeZKsyncOS.sol";
import {IL2DefaultUpgrade} from "contracts/upgrades/IL2DefaultUpgrade.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {
    DEFAULT_PRIORITY_TX_MAX_PUBDATA,
    ETH_TOKEN_ADDRESS,
    PRIORITY_TX_MAX_GAS_LIMIT,
    UPGRADE_TX_MAX_GAS_LIMIT
} from "contracts/common/Config.sol";
import {TooMuchGas} from "contracts/common/L1ContractErrors.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {LEGACY_PRIORITY_TX_MAX_GAS_LIMIT, TEST_CHAIN_CONFIG_UPGRADE_VERSION} from "../../TestConstants.sol";
import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";

// Isolate upgrade behavior from batch proving and CTM verifier registration.
contract V34UpgradeTestUtils is BaseUpgradeUtils {
    function setBridgehubAndChainId(address _bridgehub, uint256 _chainId) external {
        s.bridgehub = _bridgehub;
        s.chainId = _chainId;
    }

    function getUpgradeTxHash() external view returns (bytes32) {
        return s.l2SystemContractsUpgradeTxHash;
    }
}

contract DummyV34Upgrade is V34UpgradeZKsyncOS, V34UpgradeTestUtils {}

contract DummyDefaultUpgrade is DefaultUpgradeZKsyncOS, V34UpgradeTestUtils {}

contract V34UpgradeZKsyncOSTest is BaseUpgrade {
    uint256 internal constant CHAIN_ID = 271;
    bytes32 internal constant BASE_TOKEN_ASSET_ID = keccak256("baseTokenAssetId");
    uint256 internal constant BASE_TOKEN_ORIGIN_CHAIN_ID = 1;

    DummyV34Upgrade internal upgrade;
    address internal mockVerifier = makeAddr("verifier");
    uint256 internal previousVersion;

    function setUp() public {
        upgrade = new DummyV34Upgrade();
        _prepareEmptyProposedUpgrade();
        previousVersion = SemVer.packSemVer(0, TEST_CHAIN_CONFIG_UPGRADE_VERSION - 1, 0);
        protocolVersion = SemVer.packSemVer(0, TEST_CHAIN_CONFIG_UPGRADE_VERSION, 0);
        proposedUpgrade.newProtocolVersion = protocolVersion;
        upgrade.setProtocolVersion(previousVersion);
        upgrade.setChainTypeManager(makeAddr("ctm"));
        upgrade.mockProtocolVersionVerifier(protocolVersion, mockVerifier);
    }

    function test_ClampsLegacyPriorityTxMaxGasLimit() public {
        _assertClampsGasLimit(LEGACY_PRIORITY_TX_MAX_GAS_LIMIT);
    }

    function testFuzz_ClampsHigherPriorityTxMaxGasLimit(uint256 _storedLimit) public {
        _assertClampsGasLimit(bound(_storedLimit, PRIORITY_TX_MAX_GAS_LIMIT + 1, type(uint256).max));
    }

    // The clamp composes with the inherited per-chain rewrite of the L2 upgrade transaction.
    function test_ClampsWithL2UpgradeTransaction() public {
        _prepareL2UpgradeTx();
        L2CanonicalTransaction memory expectedTx = proposedUpgrade.l2ProtocolUpgradeTx;
        expectedTx.data = upgrade.getL2UpgradeTxData(makeAddr("bridgehub"), CHAIN_ID, expectedTx.data);

        _assertClampsGasLimit(LEGACY_PRIORITY_TX_MAX_GAS_LIMIT);
        assertEq(upgrade.getUpgradeTxHash(), keccak256(abi.encode(expectedTx)));
    }

    function test_ClampsOnVerifierOnlyUpgrade() public {
        upgrade.setPriorityTxMaxGasLimit(LEGACY_PRIORITY_TX_MAX_GAS_LIMIT);

        vm.expectEmit(false, false, false, true, address(upgrade));
        emit IAdmin.NewPriorityTxMaxGasLimit(LEGACY_PRIORITY_TX_MAX_GAS_LIMIT, PRIORITY_TX_MAX_GAS_LIMIT);
        assertEq(upgrade.upgradeVerifierOnly(protocolVersion), Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);

        assertEq(upgrade.getProtocolVersion(), protocolVersion);
        assertEq(upgrade.getPriorityTxMaxGasLimit(), PRIORITY_TX_MAX_GAS_LIMIT);
    }

    function test_PreservesZeroPriorityTxMaxGasLimit() public {
        _assertPreservesGasLimit(0);
    }

    function test_PreservesPriorityTxMaxGasLimitAtCeiling() public {
        _assertPreservesGasLimit(PRIORITY_TX_MAX_GAS_LIMIT);
    }

    function testFuzz_PreservesLowerPriorityTxMaxGasLimit(uint256 _storedLimit) public {
        _assertPreservesGasLimit(bound(_storedLimit, 0, PRIORITY_TX_MAX_GAS_LIMIT));
    }

    // A rejected upgrade tx must roll back the clamp together with the rest of the upgrade.
    function test_RevertsWhenUpgradeTxExceedsUpgradeGasCeiling() public {
        _prepareL2UpgradeTx();
        proposedUpgrade.l2ProtocolUpgradeTx.gasLimit = UPGRADE_TX_MAX_GAS_LIMIT + 1;
        upgrade.setPriorityTxMaxGasLimit(LEGACY_PRIORITY_TX_MAX_GAS_LIMIT);

        vm.expectRevert(TooMuchGas.selector);
        upgrade.upgrade(proposedUpgrade);

        assertEq(upgrade.getProtocolVersion(), previousVersion);
        assertEq(upgrade.getPriorityTxMaxGasLimit(), LEGACY_PRIORITY_TX_MAX_GAS_LIMIT);
        assertEq(upgrade.getUpgradeTxHash(), bytes32(0));
    }

    // The clamp is v34-only: the CTM's default upgrade leaves the stored limit alone.
    function test_DefaultUpgradeDoesNotClamp() public {
        DummyDefaultUpgrade defaultUpgrade = new DummyDefaultUpgrade();
        defaultUpgrade.setProtocolVersion(protocolVersion);
        defaultUpgrade.setChainTypeManager(makeAddr("ctm"));
        defaultUpgrade.setPriorityTxMaxGasLimit(LEGACY_PRIORITY_TX_MAX_GAS_LIMIT);
        uint256 patchVersion = SemVer.packSemVer(0, TEST_CHAIN_CONFIG_UPGRADE_VERSION, 1);
        defaultUpgrade.mockProtocolVersionVerifier(patchVersion, mockVerifier);

        vm.recordLogs();
        assertEq(defaultUpgrade.upgradeVerifierOnly(patchVersion), Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);

        assertEq(defaultUpgrade.getProtocolVersion(), patchVersion);
        assertEq(defaultUpgrade.getPriorityTxMaxGasLimit(), LEGACY_PRIORITY_TX_MAX_GAS_LIMIT);
        _assertNoGasLimitEvent(vm.getRecordedLogs());
    }

    function _assertClampsGasLimit(uint256 _storedLimit) internal {
        upgrade.setPriorityTxMaxGasLimit(_storedLimit);
        vm.recordLogs();
        _upgradeSuccessfully();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory lastLog = logs[logs.length - 1];
        assertEq(lastLog.emitter, address(upgrade));
        assertEq(lastLog.topics[0], IAdmin.NewPriorityTxMaxGasLimit.selector);
        assertEq(lastLog.data, abi.encode(_storedLimit, PRIORITY_TX_MAX_GAS_LIMIT));
        assertEq(upgrade.getPriorityTxMaxGasLimit(), PRIORITY_TX_MAX_GAS_LIMIT);
    }

    function _assertPreservesGasLimit(uint256 _storedLimit) internal {
        upgrade.setPriorityTxMaxGasLimit(_storedLimit);
        vm.recordLogs();
        _upgradeSuccessfully();
        assertEq(upgrade.getPriorityTxMaxGasLimit(), _storedLimit);
        _assertNoGasLimitEvent(vm.getRecordedLogs());
    }

    function _assertNoGasLimitEvent(Vm.Log[] memory _logs) internal pure {
        for (uint256 i; i < _logs.length; ++i) {
            assertNotEq(_logs[i].topics[0], IAdmin.NewPriorityTxMaxGasLimit.selector);
        }
    }

    function _prepareL2UpgradeTx() internal {
        _prepareProposedUpgrade();
        protocolVersion = SemVer.packSemVer(0, TEST_CHAIN_CONFIG_UPGRADE_VERSION, 0);
        proposedUpgrade.newProtocolVersion = protocolVersion;
        proposedUpgrade.l2ProtocolUpgradeTx.nonce = TEST_CHAIN_CONFIG_UPGRADE_VERSION;
        proposedUpgrade.l2ProtocolUpgradeTx.to = uint256(uint160(L2_COMPLEX_UPGRADER_ADDR));
        proposedUpgrade.l2ProtocolUpgradeTx.data = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgradeUniversal,
            (
                new IComplexUpgrader.UniversalContractUpgradeInfo[](0),
                makeAddr("l2DefaultUpgrade"),
                abi.encodeCall(IL2DefaultUpgrade.upgrade, (makeAddr("ctmDeployer"), hex"c0ffee", hex""))
            )
        );
        upgrade.setPriorityTxMaxPubdata(DEFAULT_PRIORITY_TX_MAX_PUBDATA);
        upgrade.setBridgehubAndChainId(_mockEcosystem(), CHAIN_ID);
    }

    // The bridgehub, asset router and vault are mocked: the per-chain rewrite is covered in
    // DefaultUpgradeZKsyncOS.t.sol, these tests only need it to succeed.
    function _mockEcosystem() internal returns (address bridgehub) {
        bridgehub = makeAddr("bridgehub");
        address assetRouter = makeAddr("assetRouter");
        address nativeTokenVault = makeAddr("nativeTokenVault");
        vm.mockCall(bridgehub, abi.encodeWithSelector(IBridgehubBase.assetRouter.selector), abi.encode(assetRouter));
        vm.mockCall(
            assetRouter,
            abi.encodeWithSelector(IL1AssetRouter.nativeTokenVault.selector),
            abi.encode(nativeTokenVault)
        );
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, CHAIN_ID),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );
        vm.mockCall(
            nativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originToken.selector, BASE_TOKEN_ASSET_ID),
            abi.encode(ETH_TOKEN_ADDRESS)
        );
        vm.mockCall(
            nativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originChainId.selector, BASE_TOKEN_ASSET_ID),
            abi.encode(BASE_TOKEN_ORIGIN_CHAIN_ID)
        );
    }

    function _upgradeSuccessfully() internal {
        vm.expectEmit(true, true, false, true, address(upgrade));
        emit BaseZkSyncUpgrade.NewProtocolVersion(previousVersion, protocolVersion);
        vm.expectEmit(true, true, false, true, address(upgrade));
        emit BaseZkSyncUpgrade.NewVerifier(address(0), mockVerifier);
        assertEq(upgrade.upgrade(proposedUpgrade), Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);
        assertEq(upgrade.getProtocolVersion(), protocolVersion);
        assertEq(upgrade.getVerifier(), mockVerifier);
    }
}
