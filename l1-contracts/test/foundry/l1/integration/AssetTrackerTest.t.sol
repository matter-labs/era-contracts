// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IMailboxImpl} from "contracts/state-transition/chain-interfaces/IMailboxImpl.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {ETH_TOKEN_ADDRESS, SERVICE_TRANSACTION_SENDER} from "contracts/common/Config.sol";
import {L2Message, TokenBalanceMigrationData} from "contracts/common/Messaging.sol";
import {GW_ASSET_TRACKER, GW_ASSET_TRACKER_ADDR, L2_ASSET_ROUTER_ADDR, L2_ASSET_ROUTER, L2_ASSET_TRACKER_ADDR, L2_BRIDGEHUB, L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_NATIVE_TOKEN_VAULT, L2_NATIVE_TOKEN_VAULT_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {AddressesAlreadyGenerated} from "test/foundry/L1TestsErrors.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {TOKEN_BALANCE_MIGRATION_DATA_VERSION} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IChainAssetHandler} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IL2AssetTracker, L2AssetTracker} from "contracts/bridge/asset-tracker/L2AssetTracker.sol";
import {IL1AssetTracker, L1AssetTracker} from "contracts/bridge/asset-tracker/L1AssetTracker.sol";
import {GWAssetTracker} from "contracts/bridge/asset-tracker/GWAssetTracker.sol";
import {IMessageVerification} from "contracts/core/message-root/IMessageRoot.sol";

import {IAssetTrackerDataEncoding} from "contracts/bridge/asset-tracker/IAssetTrackerDataEncoding.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {IAssetTrackerBase} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {InvalidChainId} from "contracts/common/L1ContractErrors.sol";
import {GWAssetTrackerTestHelper} from "../unit/concrete/Bridge/AssetTracker/GWAssetTracker.t.sol";

contract AssetTrackerTests is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    using stdStorage for StdStorage;

    uint256 constant TEST_USERS_COUNT = 10;
    address[] public users;
    address[] public l2ContractAddresses;

    IBridgehubBase l2Bridgehub;
    IL1AssetTracker assetTracker;
    IL2AssetTracker l2AssetTracker;
    GWAssetTrackerTestHelper gwAssetTracker;
    address l1AssetTracker = address(0);

    address tokenAddress;
    bytes32 assetId;
    uint256 originalChainId;
    uint256 gwChainId;
    bytes32 assetMigrationNumberLocation;
    bytes32 totalSupplyAcrossAllChainsLocation;
    uint256 migrationNumber = 20;
    bytes32 chainBalanceLocation;
    uint256 amount = 1000000000000000000;

    // generate MAX_USERS addresses and append it to users array
    function _generateUserAddresses() internal {
        if (users.length != 0) {
            revert AddressesAlreadyGenerated();
        }

        for (uint256 i = 0; i < TEST_USERS_COUNT; i++) {
            address newAddress = makeAddr(string(abi.encode("account", i)));
            users.push(newAddress);
        }
    }

    function prepare() public {
        _generateUserAddresses();

        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);

        // _deployEra();
        // _deployZKChain(ETH_TOKEN_ADDRESS);
        // _deployZKChain(ETH_TOKEN_ADDRESS);
        // _deployZKChain(tokens[0]);
        // _deployZKChain(tokens[0]);
        // _deployZKChain(tokens[1]);
        // _deployZKChain(tokens[1]);

        for (uint256 i = 0; i < zkChainIds.length; i++) {
            address contractAddress = makeAddr(string(abi.encode("contract", i)));
            l2ContractAddresses.push(contractAddress);

            _addL2ChainContract(zkChainIds[i], contractAddress);
        }

        assetTracker = IL1AssetTracker(
            address(IL1NativeTokenVault(ecosystemAddresses.bridges.proxies.l1NativeTokenVault).l1AssetTracker())
        );
        address l2AssetTrackerAddress = address(new L2AssetTracker());
        vm.etch(L2_ASSET_TRACKER_ADDR, l2AssetTrackerAddress.code);
        l2AssetTracker = IL2AssetTracker(L2_ASSET_TRACKER_ADDR);
        // Mock Native Token Vault's WETH_TOKEN function
        address mockWrappedZKToken = makeAddr("mockWrappedZKToken");
        vm.mockCall(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            abi.encodeWithSelector(IL2NativeTokenVault.WETH_TOKEN.selector),
            abi.encode(mockWrappedZKToken)
        );

        address gwAssetTrackerAddress = address(new GWAssetTrackerTestHelper());
        vm.etch(GW_ASSET_TRACKER_ADDR, gwAssetTrackerAddress.code);
        gwAssetTracker = GWAssetTrackerTestHelper(GW_ASSET_TRACKER_ADDR);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2AssetTracker.setAddresses(block.chainid, bytes32(0));
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        gwAssetTracker.setAddresses(block.chainid);

        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector),
            abi.encode(block.chainid)
        );
    }

    function setUp() public {
        originalChainId = block.chainid;
        gwChainId = 1;
        prepare();
        tokenAddress = tokens[1];
        assetId = DataEncoding.encodeNTVAssetId(block.chainid, tokenAddress);

        // 0x13b704bded2382d6e555a218f4d57330c8d624337c03a7aa1779d78f557b4126;
        // the below does not work for some reason:
    }

    function getChainBalanceLocation(bytes32 _assetId, uint256 _chainId) internal pure returns (bytes32) {
        return computeNestedMappingSlot(uint256(_assetId), _chainId, 0 + 151);
    }

    function getAssetMigrationNumberLocation(bytes32 _assetId, uint256 _chainId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_assetId, keccak256(abi.encodePacked(_chainId, uint256(1 + 151)))));
    }

    function getTotalSupplyAcrossAllChainsLocation(bytes32 _assetId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_assetId, uint256(2 + 151)));
    }

    function computeNestedMappingSlot(
        uint256 outerKey,
        uint256 innerKey,
        uint256 baseSlot
    ) internal pure returns (bytes32) {
        // Computes keccak256(abi.encode(outerKey, keccak256(abi.encode(innerKey, baseSlot))))
        bytes32 innerHash = keccak256(abi.encodePacked(innerKey, baseSlot));
        return keccak256(abi.encode(outerKey, innerHash));
    }

    function test_migrationL1ToGateway() public {
        // vm.chainId(eraZKChainId);
        // vm.mockCall(
        //     L2_NATIVE_TOKEN_VAULT_ADDR,
        //     abi.encodeWithSelector(L2_NATIVE_TOKEN_VAULT.tokenAddress.selector),
        //     abi.encode(tokenAddress)
        // );
        // vm.mockCall(
        //     L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
        //     abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
        //     abi.encode(bytes32(0))
        // );
        // assetTracker.initiateL1ToGatewayMigrationOnL2(assetId);
        TokenBalanceMigrationData memory data = TokenBalanceMigrationData({
            version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
            chainId: eraZKChainId,
            assetId: assetId,
            tokenOriginChainId: originalChainId,
            amount: amount,
            chainMigrationNumber: migrationNumber,
            assetMigrationNumber: migrationNumber - 1,
            originToken: tokenAddress,
            isL1ToGateway: true
        });
        TokenBalanceMigrationData memory confirmData = TokenBalanceMigrationData({
            version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
            isL1ToGateway: true,
            chainId: eraZKChainId,
            assetId: assetId,
            originToken: tokenAddress,
            tokenOriginChainId: originalChainId,
            chainMigrationNumber: 0,
            assetMigrationNumber: migrationNumber,
            amount: amount
        });
        bytes memory encodedData = abi.encodeCall(IAssetTrackerDataEncoding.receiveMigrationOnL1, data);

        FinalizeL1DepositParams memory finalizeWithdrawalParamsL1ToGateway = FinalizeL1DepositParams({
            chainId: eraZKChainId,
            l2BatchNumber: 0,
            l2MessageIndex: 0,
            l2Sender: L2_ASSET_TRACKER_ADDR,
            l2TxNumberInBatch: 0,
            message: encodedData,
            merkleProof: new bytes32[](0)
        });
        vm.chainId(originalChainId);
        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.messageRoot),
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector),
            abi.encode(gwChainId)
        );
        bytes[] memory mocks1 = new bytes[](2);
        bytes32 randomHash = keccak256(abi.encode(assetId));
        mocks1[0] = abi.encode(randomHash);
        mocks1[1] = abi.encode(randomHash);
        vm.mockCalls(
            address(0x0000000000000000000000000000000000000011),
            abi.encodeWithSelector(IMailboxImpl.requestL2ServiceTransaction.selector),
            mocks1
        );
        bytes[] memory mocks2 = new bytes[](2);
        mocks2[0] = abi.encode(0x0000000000000000000000000000000000000011);
        mocks2[1] = abi.encode(0x0000000000000000000000000000000000000011);

        vm.mockCalls(address(addresses.bridgehub), abi.encodeWithSelector(IBridgehubBase.getZKChain.selector), mocks2);

        vm.store(
            address(assetTracker),
            getAssetMigrationNumberLocation(assetId, eraZKChainId),
            bytes32(migrationNumber - 2)
        );
        vm.store(
            address(l2AssetTracker),
            getAssetMigrationNumberLocation(assetId, eraZKChainId),
            bytes32(migrationNumber - 2)
        );
        vm.store(address(assetTracker), getChainBalanceLocation(assetId, eraZKChainId), bytes32(amount));
        vm.store(address(assetTracker), getTotalSupplyAcrossAllChainsLocation(assetId), bytes32(amount));

        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler),
            abi.encodeWithSelector(IChainAssetHandler.migrationNumber.selector),
            abi.encode(migrationNumber)
        );
        vm.mockCall(
            address(L2_CHAIN_ASSET_HANDLER_ADDR),
            abi.encodeWithSelector(IChainAssetHandler.migrationNumber.selector),
            abi.encode(migrationNumber)
        );
        console.log("chainAssetHandler", address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler));
        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler),
            abi.encodeWithSelector(IChainAssetHandler.migrationNumber.selector),
            abi.encode(migrationNumber)
        );
        // Capture balances before migration
        uint256 chainBalanceBefore = L1AssetTracker(address(assetTracker)).chainBalance(eraZKChainId, assetId);

        IL1AssetTracker(assetTracker).receiveMigrationOnL1(finalizeWithdrawalParamsL1ToGateway);

        // Verify L1 migration was processed - chain balance should be updated
        uint256 chainBalanceAfterL1 = L1AssetTracker(address(assetTracker)).chainBalance(eraZKChainId, assetId);
        assertTrue(chainBalanceAfterL1 != chainBalanceBefore, "Chain balance should change after L1 migration");

        vm.prank(SERVICE_TRANSACTION_SENDER);
        l2AssetTracker.confirmMigrationOnL2(confirmData);

        // Verify L2 confirmation was processed - check that the migration number is updated
        // Note: The final migration number depends on the mock setup
        uint256 assetMigrationNumL2 = L2AssetTracker(address(l2AssetTracker)).assetMigrationNumber(
            eraZKChainId,
            assetId
        );
        // The migration number is updated based on confirmData.migrationNumber
        assertTrue(assetMigrationNumL2 > 0, "Asset migration number should be updated on L2");

        vm.prank(SERVICE_TRANSACTION_SENDER);
        gwAssetTracker.confirmMigrationOnGateway(confirmData);

        // Verify Gateway confirmation updated asset migration number
        uint256 assetMigrationNumGW = GWAssetTracker(address(gwAssetTracker)).assetMigrationNumber(
            eraZKChainId,
            assetId
        );
        assertEq(assetMigrationNumGW, migrationNumber, "Asset migration number should be updated on Gateway");
        assertEq(gwAssetTracker.getOriginToken(assetId), tokenAddress);
        assertEq(gwAssetTracker.getTokenOriginChainId(assetId), originalChainId);
    }

    function test_migrationGatewayToL1() public {
        vm.chainId(gwChainId);
        {
            vm.mockCall(
                address(L2_BRIDGEHUB),
                abi.encodeWithSelector(L2_BRIDGEHUB.getZKChain.selector),
                abi.encode(tokenAddress)
            );
            vm.mockCall(
                address(L2_BRIDGEHUB),
                abi.encodeWithSelector(L2_BRIDGEHUB.settlementLayer.selector),
                abi.encode(originalChainId)
            );
            vm.mockCall(
                L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
                abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
                abi.encode(bytes32(0))
            );
            vm.mockCall(
                address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler),
                abi.encodeWithSelector(IChainAssetHandler.migrationNumber.selector),
                abi.encode(migrationNumber)
            );
            vm.mockCall(
                address(L2_CHAIN_ASSET_HANDLER_ADDR),
                abi.encodeWithSelector(IChainAssetHandler.migrationNumber.selector),
                abi.encode(migrationNumber)
            );
        }

        gwAssetTracker.initiateGatewayToL1MigrationOnGateway(eraZKChainId, assetId);

        TokenBalanceMigrationData memory data = TokenBalanceMigrationData({
            version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
            chainId: eraZKChainId,
            assetId: assetId,
            tokenOriginChainId: originalChainId,
            amount: amount,
            chainMigrationNumber: migrationNumber,
            assetMigrationNumber: migrationNumber - 1,
            originToken: tokenAddress,
            isL1ToGateway: false
        });
        TokenBalanceMigrationData memory confirmData = TokenBalanceMigrationData({
            version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
            isL1ToGateway: false,
            chainId: eraZKChainId,
            assetId: assetId,
            originToken: tokenAddress,
            tokenOriginChainId: originalChainId,
            chainMigrationNumber: 0,
            assetMigrationNumber: migrationNumber,
            amount: amount
        });
        bytes memory encodedData = abi.encodeCall(IAssetTrackerDataEncoding.receiveMigrationOnL1, data);

        FinalizeL1DepositParams memory finalizeWithdrawalParamsGatewayToL1 = FinalizeL1DepositParams({
            chainId: gwChainId,
            l2BatchNumber: 0,
            l2MessageIndex: 0,
            l2Sender: L2_ASSET_TRACKER_ADDR,
            l2TxNumberInBatch: 0,
            message: encodedData,
            merkleProof: new bytes32[](0)
        });

        vm.chainId(originalChainId);
        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.messageRoot),
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        // vm.mockCall(
        //     address(addresses.bridgehub),
        //     abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector),
        //     abi.encode(originalChainId)
        // );
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeWithSelector(IBridgehubBase.whitelistedSettlementLayers.selector),
            abi.encode(true)
        );

        bytes32 randomHash = keccak256(abi.encode(assetId));

        vm.mockCall(
            address(0x0000000000000000000000000000000000000011),
            abi.encodeWithSelector(IMailboxImpl.requestL2ServiceTransaction.selector),
            abi.encode(randomHash)
        );

        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector),
            abi.encode(0x0000000000000000000000000000000000000011)
        );
        vm.store(address(assetTracker), getChainBalanceLocation(assetId, gwChainId), bytes32(amount));
        vm.store(address(gwAssetTracker), getChainBalanceLocation(assetId, gwChainId), bytes32(amount));
        vm.store(address(gwAssetTracker), getTotalSupplyAcrossAllChainsLocation(assetId), bytes32(amount));

        vm.store(
            address(assetTracker),
            getAssetMigrationNumberLocation(assetId, eraZKChainId),
            bytes32(migrationNumber - 1)
        );
        vm.store(
            address(gwAssetTracker),
            getAssetMigrationNumberLocation(assetId, eraZKChainId),
            bytes32(migrationNumber - 1)
        );
        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler),
            abi.encodeWithSelector(IChainAssetHandler.migrationNumber.selector),
            abi.encode(migrationNumber)
        );
        console.log("chainAssetHandler", address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler));

        // Capture balance before migration
        uint256 gwChainBalanceBefore = L1AssetTracker(address(assetTracker)).chainBalance(gwChainId, assetId);

        assetTracker.receiveMigrationOnL1(finalizeWithdrawalParamsGatewayToL1);

        // Verify L1 processed the migration from Gateway
        uint256 gwChainBalanceAfter = L1AssetTracker(address(assetTracker)).chainBalance(gwChainId, assetId);
        assertTrue(gwChainBalanceAfter != gwChainBalanceBefore, "Gateway chain balance should change after migration");

        // vm.prank(AddressAliasHelper.applyL1ToL2Alias(l1AssetTracker));
        vm.store(address(assetTracker), chainBalanceLocation, bytes32(amount));
        vm.store(address(l2AssetTracker), chainBalanceLocation, bytes32(amount));
        vm.store(address(l2AssetTracker), getChainBalanceLocation(assetId, eraZKChainId), bytes32(amount));
        vm.store(address(gwAssetTracker), chainBalanceLocation, bytes32(amount));
        vm.store(address(gwAssetTracker), getChainBalanceLocation(assetId, eraZKChainId), bytes32(amount));

        vm.prank(SERVICE_TRANSACTION_SENDER);
        gwAssetTracker.confirmMigrationOnGateway(confirmData);

        // Verify Gateway confirmation was processed
        uint256 assetMigrationNumGW = GWAssetTracker(address(gwAssetTracker)).assetMigrationNumber(
            eraZKChainId,
            assetId
        );
        assertEq(
            assetMigrationNumGW,
            migrationNumber,
            "Asset migration number should be updated on Gateway after confirmation"
        );
        assertEq(gwAssetTracker.getOriginToken(assetId), tokenAddress);
        assertEq(gwAssetTracker.getTokenOriginChainId(assetId), originalChainId);
    }

    function test_migrateTokenBalanceFromNTVV31_L2Chain() public {
        // Test migrating token balance from NTV for an L2 chain
        uint256 testChainId = eraZKChainId;
        uint256 migratedBalance = 5000;

        // Set origin chain ID (different from test chain)
        vm.mockCall(
            address(ecosystemAddresses.bridges.proxies.l1NativeTokenVault),
            abi.encodeWithSelector(INativeTokenVaultBase.originChainId.selector, assetId),
            abi.encode(originalChainId)
        );

        // Mock the migrateTokenBalanceToAssetTracker call
        vm.mockCall(
            address(ecosystemAddresses.bridges.proxies.l1NativeTokenVault),
            abi.encodeWithSelector(
                IL1NativeTokenVault.migrateTokenBalanceToAssetTracker.selector,
                testChainId,
                assetId
            ),
            abi.encode(migratedBalance)
        );

        // Set initial origin chain balance to MAX_TOKEN_BALANCE
        bytes32 maxTokenBalance = bytes32(type(uint256).max);
        vm.store(address(assetTracker), getChainBalanceLocation(assetId, originalChainId), maxTokenBalance);

        // Call the migration function
        assetTracker.migrateTokenBalanceFromNTVV31(testChainId, assetId);

        // Verify balances updated correctly
        uint256 originBalance = uint256(
            vm.load(address(assetTracker), getChainBalanceLocation(assetId, originalChainId))
        );
        uint256 testChainBalance = uint256(
            vm.load(address(assetTracker), getChainBalanceLocation(assetId, testChainId))
        );

        assertEq(originBalance, type(uint256).max - migratedBalance, "Origin chain balance should decrease");
        assertEq(testChainBalance, migratedBalance, "Test chain balance should increase");
    }

    function test_migrateTokenBalanceFromNTVV31_L1Chain() public {
        // Test migrating token balance for L1 chain (current chain)
        // Note: _chainId must be != originChainId, so we use a different origin chain
        uint256 totalSupply = 8000;
        uint256 differentOriginChain = 999; // Different from originalChainId

        // Set origin chain ID to a different chain
        vm.mockCall(
            address(ecosystemAddresses.bridges.proxies.l1NativeTokenVault),
            abi.encodeWithSelector(INativeTokenVaultBase.originChainId.selector, assetId),
            abi.encode(differentOriginChain)
        );

        // Mock token address
        vm.mockCall(
            address(ecosystemAddresses.bridges.proxies.l1NativeTokenVault),
            abi.encodeWithSelector(INativeTokenVaultBase.tokenAddress.selector, assetId),
            abi.encode(tokenAddress)
        );

        // Mock total supply
        vm.mockCall(tokenAddress, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(totalSupply));

        // Set initial origin chain balance to MAX_TOKEN_BALANCE
        bytes32 maxTokenBalance = bytes32(type(uint256).max);
        vm.store(address(assetTracker), getChainBalanceLocation(assetId, differentOriginChain), maxTokenBalance);

        // Call the migration function for L1 (current chain)
        assetTracker.migrateTokenBalanceFromNTVV31(originalChainId, assetId);

        // Verify balances updated correctly
        uint256 originBalance = uint256(
            vm.load(address(assetTracker), getChainBalanceLocation(assetId, differentOriginChain))
        );
        uint256 l1Balance = uint256(vm.load(address(assetTracker), getChainBalanceLocation(assetId, originalChainId)));

        assertEq(originBalance, type(uint256).max - totalSupply, "Origin chain balance should decrease by totalSupply");
        assertEq(l1Balance, totalSupply, "L1 balance should equal totalSupply");
    }

    function test_consumeBalanceChange() public {
        // Test consuming balance change for a deposit via Gateway
        uint256 callerChainId = gwChainId;
        uint256 targetChainId = eraZKChainId;
        bytes32 testAssetId = keccak256("test_asset");
        uint256 testAmount = 2500;

        // Mock caller as whitelisted settlement layer
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeWithSelector(IBridgehubBase.whitelistedSettlementLayers.selector, callerChainId),
            abi.encode(true)
        );

        // Mock getZKChain to return msg.sender (simulating the chain calling)
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, callerChainId),
            abi.encode(address(this))
        );

        // First, we need to set up a transient balance change by calling handleChainBalanceIncreaseOnL1
        // Mock settlement layer for target chain
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, targetChainId),
            abi.encode(callerChainId)
        );

        // Mock base token asset ID (different from test asset)
        bytes32 baseTokenAssetId = keccak256("base_token");
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, targetChainId),
            abi.encode(baseTokenAssetId)
        );

        // Set up initial balances
        vm.store(address(assetTracker), getChainBalanceLocation(testAssetId, originalChainId), bytes32(uint256(10000)));

        // Mock origin chain ID
        vm.mockCall(
            address(ecosystemAddresses.bridges.proxies.l1NativeTokenVault),
            abi.encodeWithSelector(INativeTokenVaultBase.originChainId.selector, testAssetId),
            abi.encode(originalChainId)
        );

        // Set asset migration number
        vm.store(
            address(assetTracker),
            getAssetMigrationNumberLocation(testAssetId, targetChainId),
            bytes32(migrationNumber)
        );

        // Mock chain migration number
        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler),
            abi.encodeWithSelector(IChainAssetHandler.migrationNumber.selector, targetChainId),
            abi.encode(migrationNumber)
        );

        // Call handleChainBalanceIncreaseOnL1 as NativeTokenVault to set transient balance
        vm.prank(address(ecosystemAddresses.bridges.proxies.l1NativeTokenVault));
        assetTracker.handleChainBalanceIncreaseOnL1(targetChainId, testAssetId, testAmount, originalChainId);

        // Now consume the balance change
        (bytes32 returnedAssetId, uint256 returnedAmount) = assetTracker.consumeBalanceChange(
            callerChainId,
            targetChainId
        );

        // Verify the returned values
        assertEq(returnedAssetId, testAssetId, "Returned asset ID should match");
        assertEq(returnedAmount, testAmount, "Returned amount should match");

        // Verify transient storage is cleared (calling again should return 0)
        (bytes32 clearedAssetId, uint256 clearedAmount) = assetTracker.consumeBalanceChange(
            callerChainId,
            targetChainId
        );
        assertEq(clearedAssetId, bytes32(0), "Asset ID should be cleared");
        assertEq(clearedAmount, 0, "Amount should be cleared");
    }

    function test_requestPauseDepositsForChainOnGateway() public {
        // Test requesting pause of deposits on Gateway for a chain migrating back to L1
        uint256 targetChainId = eraZKChainId;

        // Mock settlement layer for the chain (should be Gateway)
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, targetChainId),
            abi.encode(gwChainId)
        );

        // Mock getZKChain to return the caller address
        address zkChainAddress = address(0x1111111111111111111111111111111111111111);
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, targetChainId),
            abi.encode(zkChainAddress)
        );

        // Mock getZKChain for gateway
        address gwChainAddress = address(0x2222222222222222222222222222222222222222);
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, gwChainId),
            abi.encode(gwChainAddress)
        );

        // Mock the mailbox requestL2ServiceTransaction call
        vm.mockCall(
            gwChainAddress,
            abi.encodeWithSelector(IMailboxImpl.requestL2ServiceTransaction.selector),
            abi.encode(bytes32(uint256(1)))
        );

        // Call as the chain itself and verify event is emitted
        vm.prank(zkChainAddress);
        vm.recordLogs();
        assetTracker.requestPauseDepositsForChainOnGateway(targetChainId);

        // Verify the PauseDepositsForChainRequested event was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundEvent = false;
        bytes32 eventSignature = IL1AssetTracker.PauseDepositsForChainRequested.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSignature) {
                assertEq(logs[i].topics[1], bytes32(targetChainId), "Chain ID should match");
                assertEq(logs[i].topics[2], bytes32(gwChainId), "Settlement layer should match");
                foundEvent = true;
                break;
            }
        }
        assertTrue(foundEvent, "PauseDepositsForChainRequested event should be emitted");
    }

    function test_tokenMigratedThisChain() public view {
        // tokenMigratedThisChain returns true when assetMigrationNumber == chainMigrationNumber
        // For a fresh chain (migration number 0), assets with migration number 0 are considered "migrated"
        assertTrue(
            IAssetTrackerBase(address(assetTracker)).tokenMigratedThisChain(bytes32(0)),
            "Zero asset should be considered migrated on fresh chain"
        );
        assertTrue(
            IAssetTrackerBase(address(assetTracker)).tokenMigratedThisChain(keccak256("random_asset")),
            "Random asset should be considered migrated on fresh chain"
        );
        assertTrue(
            IAssetTrackerBase(address(assetTracker)).tokenMigratedThisChain(assetId),
            "Configured asset should be considered migrated on fresh chain"
        );
    }

    function test_regression_migrateTokenBalanceFromNTVV31_revertsForUnknownAsset() public {
        // Create a predictable future assetId that is NOT registered in NTV
        bytes32 unknownAssetId = keccak256("unknown-asset-never-registered");
        uint256 testChainId = 999; // Some chain that's not the origin (since _chainId != originChainId is required)

        // Mock the NTV to return 0 for originChainId (simulating unknown asset)
        vm.mockCall(
            address(ecosystemAddresses.bridges.proxies.l1NativeTokenVault),
            abi.encodeWithSelector(INativeTokenVaultBase.originChainId.selector, unknownAssetId),
            abi.encode(0) // Unknown asset returns 0
        );

        // Verify initial state: chainBalance[0][unknownAssetId] should be 0
        bytes32 chainBalanceSlot0 = getChainBalanceLocation(unknownAssetId, 0);
        uint256 initialChainBalance0 = uint256(vm.load(address(assetTracker), chainBalanceSlot0));
        assertEq(initialChainBalance0, 0, "Initial chainBalance[0] should be 0");

        // Attempt to migrate the unknown asset - should revert with InvalidChainId
        // Before the fix, this would succeed and poison state
        vm.expectRevert(InvalidChainId.selector);
        assetTracker.migrateTokenBalanceFromNTVV31(testChainId, unknownAssetId);

        // Verify state was NOT poisoned (chainBalance[0][unknownAssetId] should still be 0)
        uint256 finalChainBalance0 = uint256(vm.load(address(assetTracker), chainBalanceSlot0));
        assertEq(finalChainBalance0, 0, "chainBalance[0] should not have been set to MAX_TOKEN_BALANCE");
    }

    function test_regression_migrateTokenBalanceFromNTVV31_preventsStatePoisoning() public {
        // Attacker picks a predictable future assetId (unknown to NTV: originChainId(assetId) == 0)
        bytes32 futureAssetId = keccak256(abi.encodePacked("future-token-", block.timestamp));
        uint256 attackerChainId = 12345;

        // Mock NTV to return 0 for this "future" asset
        vm.mockCall(
            address(ecosystemAddresses.bridges.proxies.l1NativeTokenVault),
            abi.encodeWithSelector(INativeTokenVaultBase.originChainId.selector, futureAssetId),
            abi.encode(0)
        );

        // Before the fix, this attack would succeed:
        // 1. Call migrateTokenBalanceFromNTVV31(attackerChainId, futureAssetId)
        // 2. originChainId = 0 (for unknown asset)
        // 3. Since attackerChainId != 0, the require(_chainId != originChainId) passes
        // 4. migrateTokenBalanceToAssetTracker returns 0 (no balance)
        // 5. _assignMaxChainBalanceIfNeeded(0, futureAssetId) sets chainBalance[0][futureAssetId] = MAX
        // 6. State is now poisoned - maxChainBalanceAssigned[futureAssetId] = true

        // After the fix, this should revert immediately
        vm.expectRevert(InvalidChainId.selector);
        assetTracker.migrateTokenBalanceFromNTVV31(attackerChainId, futureAssetId);
    }

    /// @notice Test that registered assets can still be migrated correctly
    /// @dev Ensures the fix doesn't break legitimate migration operations
    function test_regression_migrateTokenBalanceFromNTVV31_worksForRegisteredAsset() public {
        // Use an already registered asset
        uint256 testChainId = eraZKChainId;
        uint256 migratedBalance = 5000;

        // Mock origin chain to be different from testChainId and non-zero
        uint256 registeredOriginChain = originalChainId;
        vm.mockCall(
            address(ecosystemAddresses.bridges.proxies.l1NativeTokenVault),
            abi.encodeWithSelector(INativeTokenVaultBase.originChainId.selector, assetId),
            abi.encode(registeredOriginChain)
        );

        // Mock the migration to return a balance
        vm.mockCall(
            address(ecosystemAddresses.bridges.proxies.l1NativeTokenVault),
            abi.encodeWithSelector(
                IL1NativeTokenVault.migrateTokenBalanceToAssetTracker.selector,
                testChainId,
                assetId
            ),
            abi.encode(migratedBalance)
        );

        // Set initial origin chain balance
        vm.store(
            address(assetTracker),
            getChainBalanceLocation(assetId, registeredOriginChain),
            bytes32(type(uint256).max)
        );

        // This should succeed for a registered asset (originChainId != 0)
        assetTracker.migrateTokenBalanceFromNTVV31(testChainId, assetId);

        // Verify balance was migrated correctly
        uint256 testChainBalance = uint256(
            vm.load(address(assetTracker), getChainBalanceLocation(assetId, testChainId))
        );
        assertEq(testChainBalance, migratedBalance, "Test chain should have migrated balance");
    }

    /// @notice Fuzz test for unknown assetId rejection
    /// @dev Ensures any random assetId that returns originChainId=0 is rejected
    function testFuzz_regression_migrateTokenBalanceFromNTVV31_revertsForAnyUnknownAsset(
        bytes32 randomAssetId,
        uint256 randomChainId
    ) public {
        // Ensure chain ID is not 0 (would fail the != originChainId check anyway)
        vm.assume(randomChainId != 0);
        vm.assume(randomChainId != block.chainid); // Skip L1 chain case

        // Mock NTV to return 0 for this random asset (simulating unknown)
        vm.mockCall(
            address(ecosystemAddresses.bridges.proxies.l1NativeTokenVault),
            abi.encodeWithSelector(INativeTokenVaultBase.originChainId.selector, randomAssetId),
            abi.encode(0)
        );

        // Should always revert for unknown assets
        vm.expectRevert(InvalidChainId.selector);
        assetTracker.migrateTokenBalanceFromNTVV31(randomChainId, randomAssetId);
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
