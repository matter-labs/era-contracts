// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {StdStorage, Test, console, stdStorage} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {
    GW_ASSET_TRACKER,
    GW_ASSET_TRACKER_ADDR,
    L2_ASSET_TRACKER,
    L2_ASSET_TRACKER_ADDR,
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_CHAIN_ASSET_HANDLER,
    L2_BOOTLOADER_ADDRESS,
    L2_BRIDGEHUB,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_MESSAGE_ROOT,
    L2_MESSAGE_ROOT_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {ProcessLogsInput} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {MAX_TOKEN_BALANCE} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {L2AssetTracker} from "contracts/bridge/asset-tracker/L2AssetTracker.sol";
import {IL2AssetTracker} from "contracts/bridge/asset-tracker/IL2AssetTracker.sol";
import {AssetAlreadyRegistered, AssetIdNotRegistered} from "contracts/bridge/asset-tracker/AssetTrackerErrors.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {L2AssetTrackerData} from "./L2AssetTrackerData.sol";
import {L2UtilsBase} from "../l2-tests-in-l1-context/L2UtilsBase.sol";

import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

import {LogFinder} from "../utils/LogFinder.sol";

abstract contract L2AssetTrackerTest is Test, SharedL2ContractDeployer {
    using stdStorage for StdStorage;
    using LogFinder for Vm.Log[];

    function test_processLogsAndMessages() public {
        finalizeDepositWithChainId(271);
        finalizeDepositWithChainId(260);

        vm.chainId(GATEWAY_CHAIN_ID);

        // Set up token balances for chain operators to pay settlement fees
        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = 271;
        chainIds[1] = 260;
        L2UtilsBase.setupTokenBalancesForChainOperators(chainIds);

        ProcessLogsInput[] memory testData = L2AssetTrackerData.getData();

        // Add the required previous batch roots for batches 1-4
        // The test is trying to add batch 5, so we need batches 1-4 to exist first
        bytes32 dummyBatchRoot = keccak256("dummy_batch_root");
        for (uint256 i = 1; i <= 4; i++) {
            stdstore
                .target(address(L2_MESSAGE_ROOT_ADDR))
                .sig("chainBatchRoots(uint256,uint256)")
                .with_key(271)
                .with_key(i)
                .checked_write(bytes32(uint256(dummyBatchRoot) + i));
        }

        // Snapshot fee-token balance before the loop to verify cross-iteration fee accounting.
        IERC20 zkToken = GW_ASSET_TRACKER.wrappedZKToken();
        uint256 feeBalanceBefore = zkToken.balanceOf(GW_ASSET_TRACKER_ADDR);
        uint256 expectedFeeTotal;

        for (uint256 i = 0; i < testData.length; i++) {
            // Set the current batch number to 4 so that batch 5 can be added next
            if (testData[i].batchNumber > 0) {
                stdstore
                    .target(address(L2_MESSAGE_ROOT_ADDR))
                    .sig("currentChainBatchNumber(uint256)")
                    .with_key(testData[i].chainId)
                    .checked_write(testData[i].batchNumber - 1);
            }

            storeChainBalance(
                testData[i].chainId,
                0x444c07697a6b15219c574dcc0ee09b479f6171009a6afd65b93e6f028cfa031b,
                100
            );
            storeChainBalance(
                testData[i].chainId,
                0xa6203e30497f83b9f5f056745b6ff94f7e22d88bacea03d4dd4393d66217a86f,
                100
            );
            storeChainBalance(
                testData[i].chainId,
                0x8592bf3100a24d737aba8ba9895f6801b9ec30200dc016dd8369f3171cbd1921,
                100
            );
            storeChainBalance(
                testData[i].chainId,
                0xb615cd4917043452e354e4797dc23e4d6106663f7a37249d54f5996dd2347710,
                100
            );
            storeChainBalance(
                testData[i].chainId,
                0xb1f317b7effffcd4e3cf53784ae442ecc4e835c532aaf0e60a046fa8efb96e85,
                100
            );
            storeChainBalance(
                testData[i].chainId,
                0xb5eab7cc8c9114c3115a034b49b3d87b0b352aa88c2a9d5ff7339cde105aa44c,
                100
            );

            stdstore
                .target(address(L2_CHAIN_ASSET_HANDLER))
                .sig("migrationNumber(uint256)")
                .with_key(271)
                .checked_write(uint256(1));

            bytes32[] memory txHashes = getTxHashes(testData[i]);

            // Loop over l1TxHashes in testData[i] and for each mark balanceChange version number as 1
            // Note: balanceChange is internal, so we calculate storage slot manually
            // balanceChange is at slot 155 in GWAssetTracker
            for (uint256 j = 0; j < txHashes.length; j++) {
                // Calculate storage slot: keccak256(txHash, keccak256(chainId, 155))
                bytes32 innerSlot = keccak256(abi.encode(testData[i].chainId, uint256(155)));
                bytes32 structSlot = keccak256(abi.encode(txHashes[j], innerSlot));
                // Write 1 to the version field (first byte of the struct)
                vm.store(address(GW_ASSET_TRACKER), structSlot, bytes32(uint256(1)));
            }

            // Get the ZKChain address for this chain - this will be the caller and the settlement fee payer
            address zkChainAddr = L2_BRIDGEHUB.getZKChain(testData[i].chainId);

            // Update settlementFeePayer to be the ZKChain address (which has tokens and approval)
            testData[i].settlementFeePayer = zkChainAddr;

            // Re-arm log capture so event assertions are scoped to this iteration's call.
            vm.recordLogs();

            vm.prank(zkChainAddr);
            (bool success, bytes memory data) = GW_ASSET_TRACKER_ADDR.call(
                abi.encodeCall(GW_ASSET_TRACKER.processLogsAndMessages, testData[i])
            );

            if (!success) {
                assembly {
                    revert(add(data, 0x20), mload(data))
                }
            }
            assertTrue(success, string.concat("processLogsAndMessages should succeed for iteration ", vm.toString(i)));

            // ---- Outcome assertions ----
            Vm.Log[] memory iterLogs = vm.getRecordedLogs();

            // Persistence: the chain batch root for this batch must now be stored.
            assertEq(
                L2_MESSAGE_ROOT.chainBatchRoots(testData[i].chainId, testData[i].batchNumber),
                testData[i].chainBatchRoot,
                "chainBatchRoot not persisted"
            );

            // Settlement-fee event: when emitted for this chain, decode and check internal
            // consistency (amount == fee * callCount) and accumulate the expected total
            // for the cross-iteration balance check below.
            Vm.Log[] memory feeLogs = iterLogs.findAllFrom(
                "GatewaySettlementFeesCollected(uint256,address,uint256,uint256)",
                GW_ASSET_TRACKER_ADDR
            );
            for (uint256 k = 0; k < feeLogs.length; k++) {
                if (uint256(feeLogs[k].topics[1]) != testData[i].chainId) continue;
                assertEq(
                    address(uint160(uint256(feeLogs[k].topics[2]))),
                    zkChainAddr,
                    "fee event payer mismatch"
                );
                (uint256 amount, uint256 callCount) = abi.decode(feeLogs[k].data, (uint256, uint256));
                assertEq(
                    amount,
                    GW_ASSET_TRACKER.gatewaySettlementFee() * callCount,
                    "fee amount != fee * callCount"
                );
                expectedFeeTotal += amount;
            }
        }

        // Cross-iteration invariant: wrappedZKToken held by the asset tracker must have grown
        // by exactly the sum of fees reported in GatewaySettlementFeesCollected events.
        assertEq(
            zkToken.balanceOf(GW_ASSET_TRACKER_ADDR) - feeBalanceBefore,
            expectedFeeTotal,
            "wrappedZKToken delta != sum of fee events"
        );
    }

    function getTxHashes(ProcessLogsInput memory input) public returns (bytes32[] memory) {
        bytes32[] memory txHashes = new bytes32[](input.logs.length);
        uint256 length = 0;
        for (uint256 i = 0; i < input.logs.length; i++) {
            if (input.logs[i].sender == L2_BOOTLOADER_ADDRESS) {
                length++;
            }
        }
        uint256 j;
        for (uint256 i = 0; i < input.logs.length; i++) {
            if (input.logs[i].sender == L2_BOOTLOADER_ADDRESS) {
                txHashes[j++] = input.logs[i].key;
            }
        }
        return txHashes;
    }

    function storeChainBalance(uint256 chainId, bytes32 assetId, uint256 balance) public {
        stdstore
            .target(address(GW_ASSET_TRACKER))
            .sig("chainBalance(uint256,bytes32)")
            .with_key(chainId)
            .with_key(assetId)
            .checked_write(balance);
    }


    function test_registerLegacyToken_nativeToken() public {
        bytes32 assetId = keccak256("test_asset_id");

        // Mock the asset as being native to the current chain
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig("originChainId(bytes32)")
            .with_key(assetId)
            .checked_write(block.chainid);

        // Mock token address
        address mockTokenAddress = address(0x1234);
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig("tokenAddress(bytes32)")
            .with_key(assetId)
            .checked_write(uint256(uint160(mockTokenAddress)));

        // Mock NTV balance (tokens locked from previous bridge operations)
        uint256 ntvBalance = 300;
        vm.mockCall(
            mockTokenAddress,
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(L2_NATIVE_TOKEN_VAULT_ADDR)),
            abi.encode(ntvBalance)
        );

        // Pre-state: registerLegacyToken early-returns if the asset is already registered (see
        // L2AssetTracker.registerLegacyToken). Lock that the fixture is fresh and the native-branch
        // invariant chainBalance == 0 (see L2AssetTracker._registerLegacyToken) holds.
        L2AssetTracker tracker = L2AssetTracker(L2_ASSET_TRACKER_ADDR);
        assertFalse(tracker.isAssetRegistered(assetId), "Asset should not be registered before call");
        assertEq(tracker.chainBalance(block.chainid, assetId), 0, "Origin-chain balance must be 0 pre-migration");

        // Call the migration function
        L2_ASSET_TRACKER.registerLegacyToken(assetId);

        // ---- Outcome assertions ----

        // chainBalance: native branch sets it to MAX_TOKEN_BALANCE - ntvBalance.
        uint256 expectedBalance = MAX_TOKEN_BALANCE - ntvBalance;
        assertEq(tracker.chainBalance(block.chainid, assetId), expectedBalance, "Chain balance should be correctly migrated");

        // isAssetRegistered: flipped to true at the end of _registerLegacyToken.
        assertTrue(tracker.isAssetRegistered(assetId), "Asset should be registered after call");

        // totalPreV31TotalSupply: native branch saves {isSaved: true, amount: chainTotalSupply}
        // where chainTotalSupply equals the freshly written chainBalance.
        (bool isSaved, uint256 amount) = tracker.totalPreV31TotalSupply(assetId);
        assertTrue(isSaved, "totalPreV31TotalSupply.isSaved should be true");
        assertEq(amount, expectedBalance, "totalPreV31TotalSupply.amount should equal chainTotalSupply");
    }

    function test_handleInitiateBridgingOnL2_requiresTokenRegistration() public {
        TestnetERC20Token token = new TestnetERC20Token("NativeToken", "NTV", 18);
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
        uint256 amount = 7;

        vm.expectRevert(abi.encodeWithSelector(AssetIdNotRegistered.selector, assetId));
        vm.prank(address(L2_NATIVE_TOKEN_VAULT_ADDR));
        L2_ASSET_TRACKER.handleInitiateBridgingOnL2(L1_CHAIN_ID, assetId, amount, block.chainid);

        INativeTokenVaultBase(L2_NATIVE_TOKEN_VAULT_ADDR).registerToken(address(token));
        uint256 balanceBefore = L2AssetTracker(L2_ASSET_TRACKER_ADDR).chainBalance(block.chainid, assetId);
        assertEq(balanceBefore, MAX_TOKEN_BALANCE, "Native token should be initialized on registration");

        vm.prank(address(L2_NATIVE_TOKEN_VAULT_ADDR));
        L2_ASSET_TRACKER.handleInitiateBridgingOnL2(L1_CHAIN_ID, assetId, amount, block.chainid);

        uint256 balanceAfter = L2AssetTracker(L2_ASSET_TRACKER_ADDR).chainBalance(block.chainid, assetId);
        assertEq(balanceAfter, balanceBefore - amount, "Native token chain balance should decrease after withdrawal");
    }

    function test_handleFinalizeBridgingOnL2_requiresTokenRegistration() public {
        TestnetERC20Token token = new TestnetERC20Token("LegacyToken", "LGC", 18);
        address l1Token = makeAddr("legacy_l1_token");
        bytes32 assetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1Token);
        uint256 amount = 11;

        vm.expectRevert(abi.encodeWithSelector(AssetIdNotRegistered.selector, assetId));
        vm.prank(address(L2_NATIVE_TOKEN_VAULT_ADDR));
        L2_ASSET_TRACKER.handleFinalizeBridgingOnL2(L1_CHAIN_ID, assetId, amount, L1_CHAIN_ID, address(token));

        stdstore.target(sharedBridgeLegacy).sig("l1TokenAddress(address)").with_key(address(token)).checked_write(
            l1Token
        );
        L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).setLegacyTokenAssetId(address(token));

        vm.prank(address(L2_NATIVE_TOKEN_VAULT_ADDR));
        L2_ASSET_TRACKER.handleFinalizeBridgingOnL2(L1_CHAIN_ID, assetId, amount, L1_CHAIN_ID, address(token));

        uint256 chainBalance = L2AssetTracker(L2_ASSET_TRACKER_ADDR).chainBalance(block.chainid, assetId);
        assertEq(chainBalance, 0, "Foreign token chain balance should remain zero");
    }

    function test_handleFinalizeBaseTokenBridgingOnL2() public {
        // Test handling base token bridging into L2
        bytes32 baseTokenAssetId = keccak256("base_token_asset_id");
        uint256 amount = 300;
        uint256 l1ChainId = 1;
        uint256 mockedTotalSupply = 1000;

        // Mock base token asset ID
        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("BASE_TOKEN_ASSET_ID()").checked_write(uint256(baseTokenAssetId));

        // Mock L1 chain ID
        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("L1_CHAIN_ID()").checked_write(l1ChainId);

        // Set initial chain balance (should be 0 for incoming tokens)
        stdstore
            .target(L2_ASSET_TRACKER_ADDR)
            .sig("chainBalance(uint256,bytes32)")
            .with_key(block.chainid)
            .with_key(baseTokenAssetId)
            .checked_write(uint256(0));

        // Mock origin chain ID for base token (L1)
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig("originChainId(bytes32)")
            .with_key(baseTokenAssetId)
            .checked_write(l1ChainId);

        // Mock totalSupply on L2_BASE_TOKEN_SYSTEM_CONTRACT (needed for foreign token total supply calculation)
        vm.mockCall(
            address(L2_BASE_TOKEN_SYSTEM_CONTRACT),
            abi.encodeWithSelector(IERC20.totalSupply.selector),
            abi.encode(mockedTotalSupply)
        );

        // Mock currentSettlementLayerChainId to return L1 (not in gateway mode)
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId.selector),
            abi.encode(l1ChainId)
        );

        L2AssetTracker tracker = L2AssetTracker(L2_ASSET_TRACKER_ADDR);
        uint256 depositsBefore = _readTotalSuccessfulDepositsFromL1(baseTokenAssetId);
        assertFalse(tracker.isAssetRegistered(baseTokenAssetId), "Asset should not be registered before call");

        // Call as BaseTokenHolder (onlyBaseTokenHolderOrL2BaseToken modifier)
        vm.prank(L2_BASE_TOKEN_HOLDER_ADDR);
        L2_ASSET_TRACKER.handleFinalizeBaseTokenBridgingOnL2(l1ChainId, amount);

        // ---- Outcome assertions ----

        // chainBalance: base token's origin is L1, so the block.chainid branch is not taken; balance stays 0.
        assertEq(
            tracker.chainBalance(block.chainid, baseTokenAssetId),
            0,
            "Chain balance should remain 0 for foreign tokens"
        );

        // totalSuccessfulDepositsFromL1: incremented by amount (fromChainId == L1, settlement layer == L1).
        uint256 depositsAfter = _readTotalSuccessfulDepositsFromL1(baseTokenAssetId);
        assertEq(depositsAfter - depositsBefore, amount, "totalSuccessfulDepositsFromL1 should increase by amount");

        // _registerLegacyTokenIfNeeded was triggered on first contact: registration + supply snapshot set.
        assertTrue(tracker.isAssetRegistered(baseTokenAssetId), "Asset should be registered after call");
        (bool isSaved, uint256 savedAmount) = tracker.totalPreV31TotalSupply(baseTokenAssetId);
        assertTrue(isSaved, "totalPreV31TotalSupply.isSaved should be true");
        assertEq(savedAmount, mockedTotalSupply, "totalPreV31TotalSupply.amount should equal mocked totalSupply");
    }

    /// @notice On Era, L2BaseTokenEra.mint() calls handleFinalizeBaseTokenBridgingOnL2 directly
    /// (msg.sender = L2_BASE_TOKEN_SYSTEM_CONTRACT). This must be allowed by access control.
    function test_handleFinalizeBaseTokenBridgingOnL2_calledByL2BaseToken() public {
        bytes32 baseTokenAssetId = keccak256("base_token_asset_id");
        uint256 amount = 300;
        uint256 l1ChainId = 1;

        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("BASE_TOKEN_ASSET_ID()").checked_write(uint256(baseTokenAssetId));
        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("L1_CHAIN_ID()").checked_write(l1ChainId);
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig("originChainId(bytes32)")
            .with_key(baseTokenAssetId)
            .checked_write(l1ChainId);

        vm.mockCall(
            address(L2_BASE_TOKEN_SYSTEM_CONTRACT),
            abi.encodeWithSelector(IERC20.totalSupply.selector),
            abi.encode(1000)
        );

        // Mock currentSettlementLayerChainId to return L1 (not in gateway mode)
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId.selector),
            abi.encode(l1ChainId)
        );

        uint256 depositsBefore = _readTotalSuccessfulDepositsFromL1(baseTokenAssetId);

        // Call as L2BaseToken (the Era flow: L2BaseTokenEra.mint() → asset tracker)
        vm.prank(address(L2_BASE_TOKEN_SYSTEM_CONTRACT));
        L2_ASSET_TRACKER.handleFinalizeBaseTokenBridgingOnL2(l1ChainId, amount);

        // Verify totalSuccessfulDepositsFromL1 increased by amount
        uint256 depositsAfter = _readTotalSuccessfulDepositsFromL1(baseTokenAssetId);
        assertEq(depositsAfter - depositsBefore, amount, "totalSuccessfulDepositsFromL1 should increase by amount");
    }

    /// @notice A random address must not be able to call handleFinalizeBaseTokenBridgingOnL2.
    function test_handleFinalizeBaseTokenBridgingOnL2_revertUnauthorized() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(0xDEAD)));
        L2_ASSET_TRACKER.handleFinalizeBaseTokenBridgingOnL2(1, 100);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  registerBaseTokenDuringUpgrade
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Verifies that registerBaseTokenDuringUpgrade registers the base token correctly.
    function test_registerBaseTokenDuringUpgrade_registersBaseToken() public {
        bytes32 baseTokenAssetId = keccak256("base_token_asset_id");

        // Set BASE_TOKEN_ASSET_ID (the function reads it internally)
        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("BASE_TOKEN_ASSET_ID()").checked_write(uint256(baseTokenAssetId));

        // Verify not registered yet
        assertFalse(
            L2AssetTracker(L2_ASSET_TRACKER_ADDR).isAssetRegistered(baseTokenAssetId),
            "Should not be registered before call"
        );

        // Expect BaseTokenRegisteredDuringUpgrade event
        vm.expectEmit(true, false, false, false, L2_ASSET_TRACKER_ADDR);
        emit IL2AssetTracker.BaseTokenRegisteredDuringUpgrade(baseTokenAssetId);

        // Call as ComplexUpgrader (onlyUpgrader)
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2_ASSET_TRACKER.registerBaseTokenDuringUpgrade();

        // Verify registered
        assertTrue(
            L2AssetTracker(L2_ASSET_TRACKER_ADDR).isAssetRegistered(baseTokenAssetId),
            "Should be registered after call"
        );

        // Verify totalPreV31TotalSupply was set to {isSaved: true, amount: 0}
        (bool isSaved, uint256 amount) = L2AssetTracker(L2_ASSET_TRACKER_ADDR).totalPreV31TotalSupply(baseTokenAssetId);
        assertTrue(isSaved, "totalPreV31TotalSupply.isSaved should be true");
        assertEq(amount, 0, "totalPreV31TotalSupply.amount should be 0");
    }

    /// @notice Verifies that registerBaseTokenDuringUpgrade reverts if already registered.
    function test_registerBaseTokenDuringUpgrade_revertIfAlreadyRegistered() public {
        bytes32 baseTokenAssetId = keccak256("base_token_asset_id");

        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("BASE_TOKEN_ASSET_ID()").checked_write(uint256(baseTokenAssetId));

        // Pre-register the asset
        stdstore
            .target(L2_ASSET_TRACKER_ADDR)
            .sig("isAssetRegistered(bytes32)")
            .with_key(baseTokenAssetId)
            .checked_write(true);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(AssetAlreadyRegistered.selector, baseTokenAssetId));
        L2_ASSET_TRACKER.registerBaseTokenDuringUpgrade();
    }

    /// @notice Verifies that only the ComplexUpgrader can call registerBaseTokenDuringUpgrade.
    function test_registerBaseTokenDuringUpgrade_revertUnauthorized() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(0xDEAD)));
        L2_ASSET_TRACKER.registerBaseTokenDuringUpgrade();
    }

    function test_initiateL1ToGatewayMigrationOnL2() public {
        // Test initiating L1 to Gateway migration on L2
        bytes32 assetId = keccak256("migration_asset_id");
        uint256 originChainId = 1;
        address tokenAddress = address(0x5678);
        address originalToken = address(0x9ABC);
        uint256 totalSupply = 10000;

        // Mock settlement layer chain ID (not L1)
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(bytes4(keccak256("currentSettlementLayerChainId()"))),
            abi.encode(270) // Gateway chain ID
        );

        // Mock token address
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig("tokenAddress(bytes32)")
            .with_key(assetId)
            .checked_write(uint256(uint160(tokenAddress)));

        // Mock origin chain ID
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig("originChainId(bytes32)")
            .with_key(assetId)
            .checked_write(originChainId);

        // Mock origin token (using mockCall since originToken is a function with logic)
        vm.mockCall(
            address(L2_NATIVE_TOKEN_VAULT_ADDR),
            abi.encodeWithSignature("originToken(bytes32)", assetId),
            abi.encode(originalToken)
        );

        // Mock chain migration number
        stdstore
            .target(address(L2_CHAIN_ASSET_HANDLER))
            .sig("migrationNumber(uint256)")
            .with_key(block.chainid)
            .checked_write(uint256(2));

        // Set asset migration number to 0 (not yet migrated). chainMigrationNumber (2) !=
        // savedAssetMigrationNumber (0), so the early-return in L2AssetTracker.initiateL1ToGatewayMigrationOnL2
        // does not fire and the event will be emitted.
        stdstore
            .target(L2_ASSET_TRACKER_ADDR)
            .sig("assetMigrationNumber(uint256,bytes32)")
            .with_key(block.chainid)
            .with_key(assetId)
            .checked_write(uint256(0));

        // Mock total supply
        vm.mockCall(tokenAddress, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(totalSupply));

        // Mock sendMessageToL1 to avoid revert
        vm.mockCall(address(L2_BRIDGEHUB), abi.encodeWithSignature("sendMessageToL1(bytes)"), abi.encode(bytes32(0)));

        // Snapshot pre-call state
        uint256 assetMigrationNumBefore = L2AssetTracker(L2_ASSET_TRACKER_ADDR).assetMigrationNumber(
            block.chainid,
            assetId
        );
        assertEq(assetMigrationNumBefore, 0, "Asset migration number should be 0 before migration");

        // Record logs to capture the event
        vm.recordLogs();

        // Call the migration function
        L2_ASSET_TRACKER.initiateL1ToGatewayMigrationOnL2(assetId);

        // ---- Outcome assertions ----

        // L1ToGatewayMigrationInitiated: only assetId is indexed; chainId is in data.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory migrationLog = logs.requireOneFrom(
            "L1ToGatewayMigrationInitiated(bytes32,uint256)",
            L2_ASSET_TRACKER_ADDR
        );
        assertEq(migrationLog.topics[1], assetId, "Event assetId mismatch");
        assertEq(
            abi.decode(migrationLog.data, (uint256)),
            block.chainid,
            "Event chainId mismatch"
        );

        // initiateL1ToGatewayMigrationOnL2 does NOT itself update assetMigrationNumber
        // (that happens later via confirmMigrationOnL2 from L1). Verify it stays at the pre-call value.
        assertEq(
            L2AssetTracker(L2_ASSET_TRACKER_ADDR).assetMigrationNumber(block.chainid, assetId),
            assetMigrationNumBefore,
            "assetMigrationNumber must not change on L2-initiation"
        );

        // _registerLegacyTokenIfNeeded was triggered: isAssetRegistered + totalPreV31TotalSupply set.
        assertTrue(
            L2AssetTracker(L2_ASSET_TRACKER_ADDR).isAssetRegistered(assetId),
            "Asset should be registered after migration init"
        );
        (bool isSaved, uint256 amount) = L2AssetTracker(L2_ASSET_TRACKER_ADDR).totalPreV31TotalSupply(assetId);
        assertTrue(isSaved, "totalPreV31TotalSupply.isSaved should be true");
        assertEq(amount, totalSupply, "totalPreV31TotalSupply.amount should match token totalSupply");
    }
}

/* Additional cases suggested
  Happy-path

  1. test_registerLegacyToken_foreignToken — direct sibling to the existing native-token test, exercises the originChainId != block.chainid branch
  of _registerLegacyToken (L2AssetTracker.sol:349–355). Asserts totalPreV31TotalSupply.amount == IERC20.totalSupply() (not the MAX_TOKEN_BALANCE -
  ntvBalance formula) and chainBalance left untouched. Currently this branch is only exercised indirectly through
  test_handleFinalizeBridgingOnL2_requiresTokenRegistration.
  2. test_initiateL1ToGatewayMigrationOnL2_earlyReturnWhenAlreadyMigrated — set chainMigrationNumber == savedAssetMigrationNumber so the function
  returns at L2AssetTracker.sol:426–428. Assert: no L1ToGatewayMigrationInitiated event emitted (vm.recordLogs + LogFinder.findAllFrom(...).length
  == 0), assetMigrationNumber unchanged, and crucially that _sendL1ToGatewayMigrationDataToL1 was not invoked. Locks the early-return invariant.
  3. test_confirmMigrationOnL2_setsAssetMigrationNumber — the L2 side of the migration completion is currently never directly tested in this file;
  only its precondition. Prank as the service-transaction sender, call confirmMigrationOnL2, assert assetMigrationNumber[block.chainid][assetId]
  flips to the supplied value.

  Unhappy-path

  4. test_initiateL1ToGatewayMigrationOnL2_revertWhen_settlementLayerIsL1 — mock currentSettlementLayerChainId() == L1_CHAIN_ID, expect
  OnlyGatewaySettlementLayer.selector. Pins L2AssetTracker.sol:408–411.
  5. test_initiateL1ToGatewayMigrationOnL2_revertWhen_baseTokenBackfillRequired — set needBaseTokenTotalSupplyBackfill = true, expect
  BaseTokenTotalSupplyBackfillRequired.selector. Pins L2AssetTracker.sol:417–419.
  6. test_handleFinalizeBaseTokenBridgingOnL2_revertWhen_baseTokenAssetIdZero — leave BASE_TOKEN_ASSET_ID = bytes32(0) (pre-genesis state), call
  with amount > 0, expect MissingBaseTokenAssetId.selector. Pins L2AssetTracker.sol:384–388.
  7. test_confirmMigrationOnL2_revertWhen_callerNotServiceTx — prank from a random address, expect the onlyServiceTransactionSender revert.
  Currently no negative test for this entry point.

  Edge cases

  8. test_handleFinalizeBaseTokenBridgingOnL2_zeroAmountIsNoop — call with amount = 0, assert no state change (chainBalance,
  totalSuccessfulDepositsFromL1, isAssetRegistered all unchanged) and no event. Pins the if (_amount == 0) return; shortcut at
  L2AssetTracker.sol:381–383.
  9. test_registerLegacyToken_idempotent — call registerLegacyToken(assetId) twice; second call must early-return at L2AssetTracker.sol:194–196.
  Snapshot all storage between the two calls and assert byte-for-byte identical.

  Adversarial

  10. test_initiateL1ToGatewayMigrationOnL2_replay — call twice in succession. The second call should not emit a second
  L1ToGatewayMigrationInitiated (because state is now consistent with chainMigrationNumber). Bound the protocol's "replay produces silent no-op"
  invariant.
  11. test_processLogsAndMessages_revertWhen_callerIsNotZKChain — heavy fixture is shared across the existing happy-path test, but none of the
  negative paths for processLogsAndMessages are tested. Prank as a non-ZKChain caller, expect the appropriate access-control revert (verify the
  exact selector against GWAssetTracker.processLogsAndMessages's caller check).
*/