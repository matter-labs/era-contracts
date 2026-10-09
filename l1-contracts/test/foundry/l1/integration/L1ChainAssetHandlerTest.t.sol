// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, stdStorage} from "forge-std/Test.sol";

import {SimpleExecutor} from "contracts/dev-contracts/SimpleExecutor.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";

import {
    L2_ASSET_ROUTER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {IChainAssetHandlerBase, MigrationInterval} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {BridgehubMintCTMAssetData} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {
    MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER,
    MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1
} from "contracts/common/Config.sol";
import {MigrationNumberMismatch, NotSystemContext} from "contracts/core/bridgehub/L1BridgehubErrors.sol";
import {NotAssetRouter, MigrationPaused, ChainMigrationsDisabled} from "contracts/common/L1ContractErrors.sol";

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {IL1ChainAssetHandler} from "contracts/core/chain-asset-handler/IL1ChainAssetHandler.sol";
import {IL2ChainAssetHandler} from "contracts/core/chain-asset-handler/IL2ChainAssetHandler.sol";
import {L2ChainAssetHandler} from "contracts/core/chain-asset-handler/L2ChainAssetHandler.sol";
import {L1ChainAssetHandlerDev} from "contracts/dev-contracts/L1ChainAssetHandlerDev.sol";
import {L2ChainAssetHandlerDev} from "contracts/dev-contracts/L2ChainAssetHandlerDev.sol";

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {Vm} from "forge-std/Vm.sol";
import {LogFinder} from "test-utils/LogFinder.sol";

interface IPausable {
    function pause() external;
    function unpause() external;
}

contract L1ChainAssetHandlerTest is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    using stdStorage for StdStorage;
    using LogFinder for Vm.Log[];

    uint256 internal constant TEST_USERS_COUNT = 10;
    address[] public users;
    address[] public l2ContractAddresses;
    bytes32 public l2TokenAssetId;
    address public tokenL1Address;
    SimpleExecutor internal simpleExecutor;

    IL2ChainAssetHandler public l2ChainAssetHandler;

    function _generateUserAddresses() internal {
        require(users.length == 0, "Addresses already generated");

        for (uint256 i = 0; i < TEST_USERS_COUNT; i++) {
            address newAddress = makeAddr(string(abi.encode("account", i)));
            users.push(newAddress);
        }
    }

    function prepare() public {
        _generateUserAddresses();

        _deployL1Contracts();
        _deployEra();
    }

    function setUp() public {
        prepare();

        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler),
            abi.encodeWithSelector(IChainAssetHandlerBase.migrationNumber.selector),
            abi.encode(0)
        );
        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.messageRoot),
            abi.encodeWithSelector(IL1MessageRoot.v31UpgradeChainBatchNumber.selector),
            abi.encode(10)
        );

        vm.prank(Ownable2StepUpgradeable(addresses.l1NativeTokenVault).pendingOwner());
        Ownable2StepUpgradeable(addresses.l1NativeTokenVault).acceptOwnership();

        l2ChainAssetHandler = IL2ChainAssetHandler(address(new L2ChainAssetHandler()));
        address owner = _owner();
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2ChainAssetHandler(address(l2ChainAssetHandler)).initL2(block.chainid, owner);
    }

    function test_pauseMigration_byOwner() public {
        address handler = address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler);
        address owner = Ownable2StepUpgradeable(handler).owner();

        assertTrue(owner != address(0), "Owner should be a valid address");

        assertFalse(
            IChainAssetHandlerBase(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).migrationPaused(),
            "Migration should not be paused initially"
        );

        vm.recordLogs();
        vm.prank(owner);
        IChainAssetHandlerBase(handler).pauseMigration();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(
            IChainAssetHandlerBase(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).migrationPaused(),
            "Migration should be paused after calling pauseMigration"
        );

        Vm.Log memory pauseLog = logs.requireOneFrom("PausedMigration(address)", handler);
        assertEq(pauseLog.topics[1], bytes32(uint256(uint160(owner))), "PausedMigration pauser mismatch");
    }

    function test_unpauseMigration_byOwner() public {
        address handler = address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler);
        address owner = Ownable2StepUpgradeable(handler).owner();

        vm.prank(owner);
        IChainAssetHandlerBase(handler).pauseMigration();

        assertTrue(IChainAssetHandlerBase(handler).migrationPaused(), "Migration should be paused before unpause");

        vm.recordLogs();
        vm.prank(owner);
        IChainAssetHandlerBase(handler).unpauseMigration();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(
            IChainAssetHandlerBase(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).migrationPaused(),
            "Migration should not be paused after calling unpauseMigration"
        );

        Vm.Log memory unpauseLog = logs.requireOneFrom("UnpausedMigration(address)", handler);
        assertEq(unpauseLog.topics[1], bytes32(uint256(uint160(owner))), "UnpausedMigration pauser mismatch");
    }

    function test_pause_byOwner() public {
        address owner = Ownable2StepUpgradeable(address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler))
            .owner();

        assertTrue(owner != address(0), "Owner should be a valid address");

        assertFalse(
            PausableUpgradeable(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).paused(),
            "Contract should not be paused initially"
        );

        vm.prank(owner);
        IPausable(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).pause();

        assertTrue(
            PausableUpgradeable(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).paused(),
            "Contract should be paused after calling pause()"
        );

        vm.prank(owner);
        IPausable(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).unpause();

        assertFalse(
            PausableUpgradeable(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).paused(),
            "Contract should not be paused after calling unpause()"
        );
    }

    function test_bridgeBurn_revertWhen_notAssetRouter() public {
        vm.expectRevert(abi.encodeWithSelector(NotAssetRouter.selector, address(this), L2_ASSET_ROUTER_ADDR));
        IChainAssetHandlerBase(address(l2ChainAssetHandler)).bridgeBurn(eraZKChainId, 0, 0, address(0), "");
    }

    function test_bridgeBurn_revertWhen_migrationPaused() public {
        vm.prank(_owner());
        IChainAssetHandlerBase(address(l2ChainAssetHandler)).pauseMigration();

        vm.expectRevert(abi.encodeWithSelector(MigrationPaused.selector));
        vm.prank(L2_ASSET_ROUTER_ADDR);
        IChainAssetHandlerBase(address(l2ChainAssetHandler)).bridgeBurn(eraZKChainId, 0, 0, address(0), "");
    }

    // Chain migrations are explicitly disabled in the v33 release, in which all chains settle
    // on L1 (see `CHAIN_MIGRATIONS_ENABLED` in `Config.sol`). The following tests pin the
    // release-level ban on the production (non-Dev) chain asset handlers on both layers.

    function test_bridgeBurn_revertWhen_chainMigrationsDisabled_L2() public {
        vm.expectRevert(abi.encodeWithSelector(ChainMigrationsDisabled.selector));
        vm.prank(L2_ASSET_ROUTER_ADDR);
        IChainAssetHandlerBase(address(l2ChainAssetHandler)).bridgeBurn(eraZKChainId, 0, 0, address(0), "");
    }

    function test_bridgeMint_revertWhen_chainMigrationsDisabled_L2() public {
        vm.expectRevert(abi.encodeWithSelector(ChainMigrationsDisabled.selector));
        vm.prank(L2_ASSET_ROUTER_ADDR);
        IChainAssetHandlerBase(address(l2ChainAssetHandler)).bridgeMint(eraZKChainId, bytes32(0), "");
    }

    function test_bridgeBurn_revertWhen_chainMigrationsDisabled_L1() public {
        address handler = ecosystemAddresses.bridgehub.proxies.chainAssetHandler;
        vm.expectRevert(abi.encodeWithSelector(ChainMigrationsDisabled.selector));
        vm.prank(address(addresses.sharedBridge));
        IChainAssetHandlerBase(handler).bridgeBurn(eraZKChainId, 0, 0, address(0), "");
    }

    function test_bridgeMint_revertWhen_chainMigrationsDisabled_L1() public {
        address handler = ecosystemAddresses.bridgehub.proxies.chainAssetHandler;
        vm.expectRevert(abi.encodeWithSelector(ChainMigrationsDisabled.selector));
        vm.prank(address(addresses.sharedBridge));
        IChainAssetHandlerBase(handler).bridgeMint(eraZKChainId, bytes32(0), "");
    }

    function test_migrationsEnabled_falseOnProductionHandlers() public view {
        address handler = ecosystemAddresses.bridgehub.proxies.chainAssetHandler;
        assertFalse(
            IChainAssetHandlerBase(handler).migrationsEnabled(),
            "Chain migrations must be disabled on the production L1 chain asset handler"
        );
        assertFalse(
            IChainAssetHandlerBase(address(l2ChainAssetHandler)).migrationsEnabled(),
            "Chain migrations must be disabled on the production L2 chain asset handler"
        );
    }

    function test_migrationsEnabled_trueOnDevHandler() public {
        // The Dev variant re-enables migrations so the migration machinery, which is preserved
        // for future releases, stays covered by the gateway and interop test harnesses.
        L2ChainAssetHandlerDev devHandler = new L2ChainAssetHandlerDev();
        assertTrue(devHandler.migrationsEnabled(), "Chain migrations should be enabled on the Dev chain asset handler");
    }

    function test_setSettlementLayerChainId_sameChainId() public {
        uint256 migrationNumBefore = IChainAssetHandlerBase(address(l2ChainAssetHandler)).migrationNumber(
            block.chainid
        );

        vm.prank(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR);
        l2ChainAssetHandler.setSettlementLayerChainId(eraZKChainId, eraZKChainId);

        uint256 migrationNumAfter = IChainAssetHandlerBase(address(l2ChainAssetHandler)).migrationNumber(block.chainid);
        assertEq(
            migrationNumAfter,
            migrationNumBefore,
            "Migration number should remain unchanged when settlement layer doesn't change"
        );
    }

    function test_setSettlementLayerChainId_differentChainId() public {
        uint256 migrationNumBefore = IChainAssetHandlerBase(address(l2ChainAssetHandler)).migrationNumber(
            block.chainid
        );

        uint256 previousChainId = 100;
        uint256 currentChainId = 200;

        vm.prank(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR);
        l2ChainAssetHandler.setSettlementLayerChainId(previousChainId, currentChainId);

        uint256 migrationNumAfter = IChainAssetHandlerBase(address(l2ChainAssetHandler)).migrationNumber(block.chainid);
        assertEq(
            migrationNumAfter,
            migrationNumBefore + 1,
            "Migration number should increment when settlement layer changes"
        );
    }

    function test_setSettlementLayerChainId_NotSystemContext() public {
        address notSystemContext = makeAddr("notSystemContext");
        vm.expectRevert(abi.encodeWithSelector(NotSystemContext.selector, notSystemContext));
        vm.prank(notSystemContext);
        l2ChainAssetHandler.setSettlementLayerChainId(eraZKChainId, eraZKChainId);
    }

    /*//////////////////////////////////////////////////////////////
                        isValidSettlementLayer
    //////////////////////////////////////////////////////////////*/

    function _l1ChainAssetHandler() internal view returns (IL1ChainAssetHandler) {
        return IL1ChainAssetHandler(ecosystemAddresses.bridgehub.proxies.chainAssetHandler);
    }

    function _owner() internal view returns (address) {
        return Ownable2StepUpgradeable(address(_l1ChainAssetHandler())).owner();
    }

    /// @dev Any chain ID other than L1's, so that L1 and the settlement layer are distinguishable.
    uint256 internal constant SETTLEMENT_LAYER_CHAIN_ID = 506;

    /// @dev Production records migration intervals only while a chain migrates, which these tests don't do,
    /// so the proxy is switched to the Dev implementation, whose setters reproduce that state. Only the
    /// implementation is swapped; proxy state and immutable values stay identical to production.
    function _installDevHandler() internal returns (L1ChainAssetHandlerDev handler) {
        address cahProxy = address(_l1ChainAssetHandler());
        L1ChainAssetHandlerDev devImpl = new L1ChainAssetHandlerDev(
            _owner(),
            ecosystemAddresses.bridgehub.proxies.bridgehub
        );
        ProxyAdmin proxyAdmin = ProxyAdmin(ecosystemAddresses.shared.transparentProxyAdmin);
        vm.prank(proxyAdmin.owner());
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(payable(cahProxy)), address(devImpl));
        handler = L1ChainAssetHandlerDev(cahProxy);
    }

    function test_isValidSettlementLayer_noMigration() public {
        // Clear the mock so the real function is called
        vm.clearMockedCalls();

        bool result = _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 5, block.chainid, 0);
        assertTrue(result, "Batch should be on L1 when no migration is set");

        result = _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 5, 999, 0);
        assertFalse(result, "Claiming wrong SL should return false");
    }

    function test_isValidSettlementLayer_afterMigrationRoundTrip() public {
        // Clear mocks so real functions are called
        vm.clearMockedCalls();

        // The chain moved to the settlement layer after batch 10 and returned after batch 50.
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 10,
            migrateFromGWBatchNumber: 50,
            settlementLayerBatchLowerBound: 100,
            settlementLayerBatchUpperBound: 200,
            settlementLayerChainId: SETTLEMENT_LAYER_CHAIN_ID,
            isActive: false
        });
        L1ChainAssetHandlerDev handler = _installDevHandler();
        vm.startPrank(_owner());
        handler.setMigrationIntervalForTesting(eraZKChainId, MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER, interval);
        handler.setMigrationNumberForTesting(eraZKChainId, MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1);
        vm.stopPrank();

        MigrationInterval memory stored = _l1ChainAssetHandler().migrationInterval(
            eraZKChainId,
            MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER
        );
        assertEq(stored.migrateToGWBatchNumber, 10, "migrateToGWBatchNumber mismatch");
        assertEq(stored.migrateFromGWBatchNumber, 50, "migrateFromGWBatchNumber mismatch");
        assertEq(stored.settlementLayerBatchLowerBound, 100, "settlementLayerBatchLowerBound mismatch");
        assertEq(stored.settlementLayerBatchUpperBound, 200, "settlementLayerBatchUpperBound mismatch");
        assertEq(stored.settlementLayerChainId, SETTLEMENT_LAYER_CHAIN_ID, "settlementLayerChainId mismatch");
        assertFalse(stored.isActive, "closed interval should not be active");

        // Batch before migration (batch 5 <= migrateToSL=10) -> on L1
        assertTrue(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 5, block.chainid, 0),
            "Batch before migration should be on L1"
        );
        assertFalse(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 5, SETTLEMENT_LAYER_CHAIN_ID, 150),
            "Batch before migration should NOT be on the SL"
        );

        // Batch during migration (10 < batch 30 <= migrateFromSL=50) -> on the SL with a valid SL batch
        assertTrue(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 30, SETTLEMENT_LAYER_CHAIN_ID, 150),
            "Batch during migration should be on the SL"
        );
        assertFalse(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 30, block.chainid, 0),
            "Batch during migration should NOT be on L1"
        );

        // Batch during migration but SL batch number below lower bound -> invalid
        assertFalse(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 30, SETTLEMENT_LAYER_CHAIN_ID, 50),
            "SL batch below lower bound should be invalid"
        );

        // Batch during migration but SL batch number above upper bound -> invalid
        assertFalse(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 30, SETTLEMENT_LAYER_CHAIN_ID, 300),
            "SL batch above upper bound should be invalid"
        );

        // Batch after return (batch 60 > migrateFromSL=50) -> on L1
        assertTrue(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 60, block.chainid, 0),
            "Batch after return should be on L1"
        );
        assertFalse(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 60, SETTLEMENT_LAYER_CHAIN_ID, 150),
            "Batch after return should NOT be on the SL"
        );

        // Wrong chain ID always returns false
        uint256 wrongChainId = 9999;
        assertFalse(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 5, wrongChainId, 0),
            "Wrong chain ID should be invalid"
        );
    }

    function test_isValidSettlementLayer_whileOnSettlementLayer() public {
        // Clear mocks so real functions are called
        vm.clearMockedCalls();

        // The chain moved to the settlement layer after batch 10 and has not returned, so the interval's
        // upper bounds are not known yet.
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 10,
            migrateFromGWBatchNumber: 0,
            settlementLayerBatchLowerBound: 100,
            settlementLayerBatchUpperBound: 0,
            settlementLayerChainId: SETTLEMENT_LAYER_CHAIN_ID,
            isActive: true
        });
        L1ChainAssetHandlerDev handler = _installDevHandler();
        vm.startPrank(_owner());
        handler.setMigrationIntervalForTesting(eraZKChainId, MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER, interval);
        handler.setMigrationNumberForTesting(eraZKChainId, MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER);
        vm.stopPrank();

        // Batch before migration (batch 5 <= migrateToSL=10) -> on L1
        assertTrue(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 5, block.chainid, 0),
            "Batch before migration should be on L1"
        );

        // Batch after migration -> on the SL, from the SL batch lower bound on
        assertTrue(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 30, SETTLEMENT_LAYER_CHAIN_ID, 150),
            "Batch after migration should be on the SL"
        );
        assertFalse(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 30, SETTLEMENT_LAYER_CHAIN_ID, 50),
            "SL batch below lower bound should be invalid"
        );
        assertFalse(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 30, block.chainid, 0),
            "Batch after migration should NOT be on L1"
        );
    }

    function test_isValidSettlementLayer_ignoresLegacyGatewayIntervals() public {
        // Clear mocks so real functions are called
        vm.clearMockedCalls();

        // The v31 upgrade stored the legacy GW intervals at migration number 0, which is no longer read:
        // the chain's migration number stays 0, so no recorded migration covers the batch.
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 10,
            migrateFromGWBatchNumber: 50,
            settlementLayerBatchLowerBound: 100,
            settlementLayerBatchUpperBound: 200,
            settlementLayerChainId: SETTLEMENT_LAYER_CHAIN_ID,
            isActive: false
        });
        L1ChainAssetHandlerDev handler = _installDevHandler();
        vm.prank(_owner());
        handler.setMigrationIntervalForTesting(eraZKChainId, 0, interval);

        assertFalse(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 30, SETTLEMENT_LAYER_CHAIN_ID, 150),
            "A legacy GW interval should not make the GW a valid settlement layer"
        );
        assertTrue(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 30, block.chainid, 0),
            "Without a recorded migration the batch should count as settled on L1"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    bridgeMint migration numbers on L1
    //////////////////////////////////////////////////////////////*/

    /// @dev Delivers a chain to L1 the way the asset router does when the chain returns from a settlement layer.
    /// The migration numbers are checked before anything else, so the rest of the mint data stays empty.
    function _bridgeMintOnL1(uint256 _incomingMigrationNumber) internal {
        BridgehubMintCTMAssetData memory data;
        data.chainId = eraZKChainId;
        data.migrationNumber = _incomingMigrationNumber;
        vm.prank(address(addresses.sharedBridge));
        IChainAssetHandlerBase(address(_l1ChainAssetHandler())).bridgeMint(eraZKChainId, bytes32(0), abi.encode(data));
    }

    function test_bridgeMint_revertWhen_chainNeverLeftL1() public {
        // Migration number 0: the chain never migrated, so nothing can return it to L1.
        _installDevHandler();

        vm.expectRevert(
            abi.encodeWithSelector(MigrationNumberMismatch.selector, MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER, 0)
        );
        _bridgeMintOnL1(MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER);

        vm.expectRevert(
            abi.encodeWithSelector(MigrationNumberMismatch.selector, MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER, 0)
        );
        _bridgeMintOnL1(MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1);
    }

    function test_bridgeMint_revertWhen_chainAlreadyReturnedToL1() public {
        L1ChainAssetHandlerDev handler = _installDevHandler();
        vm.prank(_owner());
        handler.setMigrationNumberForTesting(eraZKChainId, MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1);

        vm.expectRevert(
            abi.encodeWithSelector(
                MigrationNumberMismatch.selector,
                MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER,
                MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1
            )
        );
        _bridgeMintOnL1(MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1 + 1);
    }

    function test_bridgeMint_revertWhen_unexpectedIncomingMigrationNumber() public {
        // The chain is on the settlement layer, so the only accepted arrival is `MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1`.
        L1ChainAssetHandlerDev handler = _installDevHandler();
        vm.prank(_owner());
        handler.setMigrationNumberForTesting(eraZKChainId, MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER);

        uint256[3] memory incoming = [
            uint256(0),
            MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER,
            MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1 + 1
        ];
        for (uint256 i = 0; i < incoming.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    MigrationNumberMismatch.selector,
                    MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1,
                    incoming[i]
                )
            );
            _bridgeMintOnL1(incoming[i]);
        }
    }
}
