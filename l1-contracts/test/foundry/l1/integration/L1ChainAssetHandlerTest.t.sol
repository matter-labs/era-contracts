// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {IBridgehubBase, L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {Vm} from "forge-std/Vm.sol";

import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {SimpleExecutor} from "contracts/dev-contracts/SimpleExecutor.sol";

import {IMessageRoot, IMessageVerification} from "contracts/core/message-root/IMessageRoot.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {ETH_TOKEN_ADDRESS, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2Message} from "contracts/common/Messaging.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {IChainAssetHandler, MigrationInterval} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {MigrationNumberMismatch, MigrationIntervalNotSet, MigrationIntervalInvalid, HistoricalSettlementLayerMismatch} from "contracts/core/bridgehub/L1BridgehubErrors.sol";
import {NativeTokenVaultBase} from "contracts/bridge/ntv/NativeTokenVaultBase.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ProofData} from "contracts/common/libraries/MessageHashing.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {BridgeHelper} from "contracts/bridge/BridgeHelper.sol";
import {BridgedStandardERC20, NonSequentialVersion} from "contracts/bridge/BridgedStandardERC20.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {IAssetTrackerBase} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";

import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {IL1ChainAssetHandler} from "contracts/core/chain-asset-handler/IL1ChainAssetHandler.sol";
import {IL2ChainAssetHandler} from "contracts/core/chain-asset-handler/IL2ChainAssetHandler.sol";
import {L2ChainAssetHandler} from "contracts/core/chain-asset-handler/L2ChainAssetHandler.sol";

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

interface IPausable {
    function pause() external;
    function unpause() external;
}

contract L1ChainAssetHandlerTest is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    using stdStorage for StdStorage;

    bytes32 constant NEW_PRIORITY_REQUEST_HASH =
        keccak256(
            "NewPriorityRequest(uint256,bytes32,uint64,(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256[4],bytes,bytes,uint256[],bytes,bytes),bytes[])"
        );

    struct NewPriorityRequest {
        uint256 txId;
        bytes32 txHash;
        uint64 expirationTimestamp;
        L2CanonicalTransaction transaction;
        bytes[] factoryDeps;
    }

    uint256 constant TEST_USERS_COUNT = 10;
    address[] public users;
    address[] public l2ContractAddresses;
    bytes32 public l2TokenAssetId;
    address public tokenL1Address;
    SimpleExecutor simpleExecutor;

    IL2ChainAssetHandler public l2ChainAssetHandler;

    // generate MAX_USERS addresses and append it to users array
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
        bytes32 ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(eraZKChainId, ETH_TOKEN_ADDRESS);

        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler),
            abi.encodeWithSelector(IChainAssetHandler.migrationNumber.selector),
            abi.encode(0)
        );
        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.messageRoot),
            abi.encodeWithSelector(IL1MessageRoot.v31UpgradeChainBatchNumber.selector),
            abi.encode(10)
        );

        bytes32 ethAssetId = 0x8df3463b1850eb1d8d1847743ea155aef6b16074db8ba81d897dc30554fb2085;
        stdstore
            .target(address(ecosystemAddresses.bridgehub.proxies.assetTracker))
            .sig(IAssetTrackerBase.chainBalance.selector)
            .with_key(eraZKChainId)
            .with_key(ETH_TOKEN_ASSET_ID)
            .checked_write(100);
        vm.prank(Ownable2StepUpgradeable(addresses.l1NativeTokenVault).pendingOwner());
        Ownable2StepUpgradeable(addresses.l1NativeTokenVault).acceptOwnership();

        l2ChainAssetHandler = IL2ChainAssetHandler(
            address(
                new L2ChainAssetHandler()
                // L1_CHAIN_ID,
                // address(this),
                // ecosystemAddresses.bridgehub.proxies.bridgehub,
                // ecosystemAddresses.bridgehub.assetRouterProxy,
                // ecosystemAddresses.bridgehub.proxies.messageRoot
            )
        );
    }

    function test_pauseMigration_byOwner() public {
        address owner = Ownable2StepUpgradeable(address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler))
            .owner();

        // Verify owner is valid
        assertTrue(owner != address(0), "Owner should be a valid address");

        vm.prank(owner);
        IChainAssetHandler(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).pauseMigration();

        // Verify migration is paused
        assertTrue(
            IChainAssetHandler(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).migrationPaused(),
            "Migration should be paused after calling pauseMigration"
        );
    }

    function test_unpauseMigration_byOwner() public {
        address owner = Ownable2StepUpgradeable(address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler))
            .owner();

        // First pause migration
        vm.prank(owner);
        IChainAssetHandler(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).pauseMigration();

        // Verify migration is paused
        assertTrue(
            IChainAssetHandler(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).migrationPaused(),
            "Migration should be paused before unpause"
        );

        // Now unpause migration
        vm.prank(owner);
        IChainAssetHandler(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).unpauseMigration();

        // Verify migration is no longer paused
        assertFalse(
            IChainAssetHandler(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).migrationPaused(),
            "Migration should not be paused after calling unpauseMigration"
        );
    }

    function test_pause_byOwner() public {
        address owner = Ownable2StepUpgradeable(address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler))
            .owner();

        // Verify owner is valid
        assertTrue(owner != address(0), "Owner should be a valid address");

        // Verify contract is not paused initially
        assertFalse(
            PausableUpgradeable(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).paused(),
            "Contract should not be paused initially"
        );

        // Pause the contract
        vm.prank(owner);
        IPausable(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).pause();

        // Verify contract is now paused
        assertTrue(
            PausableUpgradeable(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).paused(),
            "Contract should be paused after calling pause()"
        );

        // Unpause the contract
        vm.prank(owner);
        IPausable(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).unpause();

        // Verify contract is no longer paused
        assertFalse(
            PausableUpgradeable(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).paused(),
            "Contract should not be paused after calling unpause()"
        );
    }

    function test_bridgeBurn_Failed() public {
        vm.expectRevert();
        IChainAssetHandler(address(l2ChainAssetHandler)).bridgeBurn(eraZKChainId, 0, 0, address(0), "");

        address owner = Ownable2StepUpgradeable(address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler))
            .owner();
        vm.prank(address(0));
        IChainAssetHandler(address(l2ChainAssetHandler)).pauseMigration();

        vm.expectRevert();
        vm.prank(address(0));
        IChainAssetHandler(address(l2ChainAssetHandler)).bridgeBurn(eraZKChainId, 0, 0, address(0), "");
    }

    function test_setSettlementLayerChainId_Success() public {
        address systemContext = L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR;

        // Verify system context address is valid
        assertTrue(systemContext != address(0), "System context address should be valid");

        // Get migration number before the call
        uint256 migrationNumBefore = IChainAssetHandler(address(l2ChainAssetHandler)).migrationNumber(block.chainid);

        // Set the settlement layer chain ID (same chain ID = no migration increment)
        vm.prank(systemContext);
        l2ChainAssetHandler.setSettlementLayerChainId(eraZKChainId, eraZKChainId);

        // When previous and current are the same, migration number should not change
        uint256 migrationNumAfter = IChainAssetHandler(address(l2ChainAssetHandler)).migrationNumber(block.chainid);
        assertEq(
            migrationNumAfter,
            migrationNumBefore,
            "Migration number should remain unchanged when settlement layer doesn't change"
        );
    }

    function test_setSettlementLayerChainId_NotSystemContext() public {
        address notSystemContext = makeAddr("notSystemContext");
        vm.expectRevert();
        vm.prank(notSystemContext);
        l2ChainAssetHandler.setSettlementLayerChainId(eraZKChainId, eraZKChainId);
    }

    /*//////////////////////////////////////////////////////////////
                    setHistoricalMigrationInterval
    //////////////////////////////////////////////////////////////*/

    function _l1ChainAssetHandler() internal view returns (IL1ChainAssetHandler) {
        return IL1ChainAssetHandler(ecosystemAddresses.bridgehub.proxies.chainAssetHandler);
    }

    function _owner() internal view returns (address) {
        return Ownable2StepUpgradeable(address(_l1ChainAssetHandler())).owner();
    }

    function _legacyGwChainId() internal view returns (uint256) {
        return IMessageRoot(ecosystemAddresses.bridgehub.proxies.messageRoot).ERA_GATEWAY_CHAIN_ID();
    }

    function test_setHistoricalMigrationInterval_success() public {
        uint256 gwChainId = _legacyGwChainId();
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 10,
            migrateFromGWBatchNumber: 50,
            settlementLayerBatchLowerBound: 100,
            settlementLayerBatchUpperBound: 200,
            settlementLayerChainId: gwChainId,
            isActive: false
        });

        vm.prank(_owner());
        _l1ChainAssetHandler().setHistoricalMigrationInterval(eraZKChainId, 0, interval);

        // Verify the mapping was populated correctly
        MigrationInterval memory stored = _l1ChainAssetHandler().migrationInterval(eraZKChainId, 0);
        assertEq(stored.migrateToGWBatchNumber, 10, "migrateToGWBatchNumber mismatch");
        assertEq(stored.migrateFromGWBatchNumber, 50, "migrateFromGWBatchNumber mismatch");
        assertEq(stored.settlementLayerChainId, gwChainId, "settlementLayerChainId mismatch");
        assertFalse(stored.isActive, "historical interval should not be active");
    }

    function test_setHistoricalMigrationInterval_revertMigrationNumberNotZero() public {
        uint256 gwChainId = _legacyGwChainId();
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 10,
            migrateFromGWBatchNumber: 50,
            settlementLayerBatchLowerBound: 100,
            settlementLayerBatchUpperBound: 200,
            settlementLayerChainId: gwChainId,
            isActive: false
        });

        vm.prank(_owner());
        vm.expectRevert(abi.encodeWithSelector(MigrationNumberMismatch.selector, 0, 1));
        _l1ChainAssetHandler().setHistoricalMigrationInterval(eraZKChainId, 1, interval);
    }

    function test_setHistoricalMigrationInterval_revertNotSet() public {
        uint256 gwChainId = _legacyGwChainId();
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 10,
            migrateFromGWBatchNumber: 50,
            settlementLayerBatchLowerBound: 100,
            settlementLayerBatchUpperBound: 200,
            settlementLayerChainId: gwChainId,
            isActive: true
        });

        vm.prank(_owner());
        vm.expectRevert(abi.encodeWithSelector(MigrationIntervalNotSet.selector));
        _l1ChainAssetHandler().setHistoricalMigrationInterval(eraZKChainId, 0, interval);
    }

    function test_setHistoricalMigrationInterval_revertWrongSL() public {
        uint256 gwChainId = _legacyGwChainId();
        uint256 wrongSL = 9999;
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 10,
            migrateFromGWBatchNumber: 50,
            settlementLayerBatchLowerBound: 100,
            settlementLayerBatchUpperBound: 200,
            settlementLayerChainId: wrongSL,
            isActive: false
        });

        vm.prank(_owner());
        vm.expectRevert(abi.encodeWithSelector(HistoricalSettlementLayerMismatch.selector, gwChainId, wrongSL));
        _l1ChainAssetHandler().setHistoricalMigrationInterval(eraZKChainId, 0, interval);
    }

    function test_setHistoricalMigrationInterval_revertInvalidBatchNumbers() public {
        uint256 gwChainId = _legacyGwChainId();
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 50,
            migrateFromGWBatchNumber: 30, // invalid: from must be > to
            settlementLayerBatchLowerBound: 100,
            settlementLayerBatchUpperBound: 200,
            settlementLayerChainId: gwChainId,
            isActive: false
        });

        vm.prank(_owner());
        vm.expectRevert(abi.encodeWithSelector(MigrationIntervalInvalid.selector));
        _l1ChainAssetHandler().setHistoricalMigrationInterval(eraZKChainId, 0, interval);
    }

    function test_setHistoricalMigrationInterval_revertmigrateFromGWBatchNumberZero() public {
        uint256 gwChainId = _legacyGwChainId();
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 10,
            migrateFromGWBatchNumber: 0, // invalid: from must be > to
            settlementLayerBatchLowerBound: 100,
            settlementLayerBatchUpperBound: 200,
            settlementLayerChainId: gwChainId,
            isActive: false
        });

        vm.prank(_owner());
        vm.expectRevert(abi.encodeWithSelector(MigrationIntervalInvalid.selector));
        _l1ChainAssetHandler().setHistoricalMigrationInterval(eraZKChainId, 0, interval);
    }

    function test_setHistoricalMigrationInterval_revertNotOwner() public {
        uint256 gwChainId = _legacyGwChainId();
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 10,
            migrateFromGWBatchNumber: 50,
            settlementLayerBatchLowerBound: 100,
            settlementLayerBatchUpperBound: 200,
            settlementLayerChainId: gwChainId,
            isActive: false
        });

        vm.expectRevert();
        vm.prank(makeAddr("notOwner"));
        _l1ChainAssetHandler().setHistoricalMigrationInterval(eraZKChainId, 0, interval);
    }

    function test_setHistoricalMigrationInterval_migrateToGWBatchNumberZero() public {
        uint256 gwChainId = _legacyGwChainId();
        // migrateToGWBatchNumber == 0 is valid: the chain migrated before any batches were committed
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 0,
            migrateFromGWBatchNumber: 50,
            settlementLayerBatchLowerBound: 100,
            settlementLayerBatchUpperBound: 200,
            settlementLayerChainId: gwChainId,
            isActive: false
        });

        vm.prank(_owner());
        _l1ChainAssetHandler().setHistoricalMigrationInterval(eraZKChainId, 0, interval);

        MigrationInterval memory stored = _l1ChainAssetHandler().migrationInterval(eraZKChainId, 0);
        assertEq(stored.migrateToGWBatchNumber, 0);
        assertEq(stored.migrateFromGWBatchNumber, 50);
        assertFalse(stored.isActive);
    }

    function test_setHistoricalMigrationInterval_revertmigrateFromGWBatchNumberEqualTo() public {
        uint256 gwChainId = _legacyGwChainId();
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 50,
            migrateFromGWBatchNumber: 50, // invalid: from == to
            settlementLayerBatchLowerBound: 100,
            settlementLayerBatchUpperBound: 200,
            settlementLayerChainId: gwChainId,
            isActive: false
        });

        vm.prank(_owner());
        vm.expectRevert(abi.encodeWithSelector(MigrationIntervalInvalid.selector));
        _l1ChainAssetHandler().setHistoricalMigrationInterval(eraZKChainId, 0, interval);
    }

    /*//////////////////////////////////////////////////////////////
                        isValidSettlementLayer
    //////////////////////////////////////////////////////////////*/

    function test_isValidSettlementLayer_noMigration() public {
        // Clear the mock so the real function is called
        vm.clearMockedCalls();

        // No migration set for eraZKChainId → all batches should report L1
        bool result = _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 5, block.chainid, 0);
        assertTrue(result, "Batch should be on L1 when no migration is set");

        result = _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 5, 999, 0);
        assertFalse(result, "Claiming wrong SL should return false");
    }

    function test_isValidSettlementLayer_afterHistoricalMigration() public {
        // Clear mocks so real functions are called
        vm.clearMockedCalls();

        // Override ERA_GATEWAY_CHAIN_ID to differ from block.chainid so L1 and GW are distinguishable
        uint256 gwChainId = 506;
        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.messageRoot),
            abi.encodeWithSelector(IMessageRoot.ERA_GATEWAY_CHAIN_ID.selector),
            abi.encode(gwChainId)
        );

        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 10,
            migrateFromGWBatchNumber: 50,
            settlementLayerBatchLowerBound: 100,
            settlementLayerBatchUpperBound: 200,
            settlementLayerChainId: gwChainId,
            isActive: false
        });

        vm.prank(_owner());
        _l1ChainAssetHandler().setHistoricalMigrationInterval(eraZKChainId, 0, interval);

        // Verify the interval was stored correctly
        MigrationInterval memory stored = _l1ChainAssetHandler().migrationInterval(eraZKChainId, 0);
        assertEq(stored.migrateToGWBatchNumber, 10, "migrateToGWBatchNumber mismatch");
        assertEq(stored.migrateFromGWBatchNumber, 50, "migrateFromGWBatchNumber mismatch");
        assertEq(stored.settlementLayerBatchLowerBound, 100, "settlementLayerBatchLowerBound mismatch");
        assertEq(stored.settlementLayerBatchUpperBound, 200, "settlementLayerBatchUpperBound mismatch");
        assertEq(stored.settlementLayerChainId, gwChainId, "settlementLayerChainId mismatch");
        assertFalse(stored.isActive, "historical interval should not be active");

        // Batch before migration (batch 5 <= migrateToSL=10) -> on L1
        assertTrue(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 5, block.chainid, 0),
            "Batch before migration should be on L1"
        );
        assertFalse(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 5, gwChainId, 150),
            "Batch before migration should NOT be on GW"
        );

        // Batch during migration (10 < batch 30 <= migrateFromSL=50) -> on GW with valid SL batch
        assertTrue(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 30, gwChainId, 150),
            "Batch during migration should be on GW"
        );
        assertFalse(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 30, block.chainid, 0),
            "Batch during migration should NOT be on L1"
        );

        // Batch during migration but SL batch number below lower bound -> invalid
        assertFalse(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 30, gwChainId, 50),
            "SL batch below lower bound should be invalid"
        );

        // Batch during migration but SL batch number above upper bound -> invalid
        assertFalse(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 30, gwChainId, 300),
            "SL batch above upper bound should be invalid"
        );

        // Batch after return (batch 60 > migrateFromSL=50) -> on L1
        assertTrue(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 60, block.chainid, 0),
            "Batch after return should be on L1"
        );
        assertFalse(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 60, gwChainId, 150),
            "Batch after return should NOT be on GW"
        );

        // Wrong chain ID always returns false
        uint256 wrongChainId = 9999;
        assertFalse(
            _l1ChainAssetHandler().isValidSettlementLayer(eraZKChainId, 5, wrongChainId, 0),
            "Wrong chain ID should be invalid"
        );
    }
}
