// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";

import {IBridgehub, L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehub.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IMailboxImpl} from "contracts/state-transition/chain-interfaces/IMailboxImpl.sol";
import {IExecutor, ProcessLogsInput} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK, ETH_TOKEN_ADDRESS, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2CanonicalTransaction, L2Message} from "contracts/common/Messaging.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_NATIVE_TOKEN_VAULT_ADDR, L2_NATIVE_TOKEN_VAULT, L2_CHAIN_ASSET_HANDLER_ADDR, L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {AddressesAlreadyGenerated} from "test/foundry/L1TestsErrors.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IncorrectBridgeHubAddress} from "contracts/common/L1ContractErrors.sol";
import {MessageRoot} from "contracts/bridgehub/MessageRoot.sol";
import {IAssetTrackerBase} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {TokenBalanceMigrationData} from "contracts/common/Messaging.sol";
import {FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {L2_BRIDGEHUB, L2_ASSET_TRACKER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IAssetTrackerBase, TOKEN_BALANCE_MIGRATION_DATA_VERSION} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IChainAssetHandler} from "contracts/bridgehub/IChainAssetHandler.sol";
import {L2AssetTracker, IL2AssetTracker} from "contracts/bridge/asset-tracker/L2AssetTracker.sol";
import {L1AssetTracker, IL1AssetTracker} from "contracts/bridge/asset-tracker/L1AssetTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {IMessageVerification} from "contracts/bridgehub/IMessageRoot.sol";

contract AssetTrackerTests is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    using stdStorage for StdStorage;

    uint256 constant TEST_USERS_COUNT = 10;
    address[] public users;
    address[] public l2ContractAddresses;

    IL1AssetTracker assetTracker;
    IL2AssetTracker l2AssetTracker;
    address l1AssetTracker = address(0);

    address tokenAddress;
    bytes32 assetId;
    uint256 originalChainId;
    uint256 gwChainId;
    bytes32 assetMigrationNumberLocation;
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

        _deployEra();
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

        assetTracker = IL1AssetTracker(address(addresses.interopCenter.assetTracker()));
        address l2AssetTrackerAddress = address(new L2AssetTracker());
        vm.etch(L2_ASSET_TRACKER_ADDR, l2AssetTrackerAddress.code);
        l2AssetTracker = IL2AssetTracker(L2_ASSET_TRACKER_ADDR);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2AssetTracker.setAddresses(block.chainid);
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
            tokenOriginChainId: block.chainid,
            amount: amount,
            migrationNumber: migrationNumber,
            originToken: tokenAddress,
            isL1ToGateway: true
        });

        FinalizeL1DepositParams memory finalizeWithdrawalParamsL1ToGateway = FinalizeL1DepositParams({
            chainId: eraZKChainId,
            l2BatchNumber: 0,
            l2MessageIndex: 0,
            l2Sender: L2_ASSET_TRACKER_ADDR,
            l2TxNumberInBatch: 0,
            message: abi.encode(data),
            merkleProof: new bytes32[](0)
        });
        vm.chainId(originalChainId);
        vm.mockCall(
            address(addresses.ecosystemAddresses.bridgehub.messageRootProxy),
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeWithSelector(IBridgehub.settlementLayer.selector),
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

        vm.mockCalls(address(addresses.bridgehub), abi.encodeWithSelector(IBridgehub.getZKChain.selector), mocks2);

        vm.store(
            address(assetTracker),
            getAssetMigrationNumberLocation(assetId, eraZKChainId),
            bytes32(migrationNumber - 1)
        );
        vm.store(
            address(l2AssetTracker),
            getAssetMigrationNumberLocation(assetId, eraZKChainId),
            bytes32(migrationNumber - 1)
        );
        vm.store(address(assetTracker), getChainBalanceLocation(assetId, eraZKChainId), bytes32(amount));
        vm.mockCall(
            address(addresses.ecosystemAddresses.bridgehub.chainAssetHandlerProxy),
            abi.encodeWithSelector(IChainAssetHandler.getMigrationNumber.selector),
            abi.encode(migrationNumber)
        );
        console.log("chainAssetHandler", address(addresses.ecosystemAddresses.bridgehub.chainAssetHandlerProxy));

        IL1AssetTracker(assetTracker).receiveMigrationOnL1(finalizeWithdrawalParamsL1ToGateway);

        vm.prank(AddressAliasHelper.applyL1ToL2Alias(l1AssetTracker));
        l2AssetTracker.confirmMigrationOnL2(data);
        vm.prank(AddressAliasHelper.applyL1ToL2Alias(l1AssetTracker));
        l2AssetTracker.confirmMigrationOnGateway(data);
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
                address(addresses.ecosystemAddresses.bridgehub.chainAssetHandlerProxy),
                abi.encodeWithSelector(IChainAssetHandler.getMigrationNumber.selector),
                abi.encode(migrationNumber)
            );
            vm.mockCall(
                address(L2_CHAIN_ASSET_HANDLER_ADDR),
                abi.encodeWithSelector(IChainAssetHandler.getMigrationNumber.selector),
                abi.encode(migrationNumber)
            );
        }

        l2AssetTracker.initiateGatewayToL1MigrationOnGateway(eraZKChainId, assetId);

        TokenBalanceMigrationData memory data = TokenBalanceMigrationData({
            version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
            chainId: eraZKChainId,
            assetId: assetId,
            tokenOriginChainId: block.chainid,
            amount: amount,
            migrationNumber: migrationNumber,
            originToken: tokenAddress,
            isL1ToGateway: false
        });

        FinalizeL1DepositParams memory finalizeWithdrawalParamsGatewayToL1 = FinalizeL1DepositParams({
            chainId: gwChainId,
            l2BatchNumber: 0,
            l2MessageIndex: 0,
            l2Sender: L2_ASSET_TRACKER_ADDR,
            l2TxNumberInBatch: 0,
            message: abi.encode(data),
            merkleProof: new bytes32[](0)
        });

        vm.chainId(originalChainId);
        vm.mockCall(
            address(addresses.ecosystemAddresses.bridgehub.messageRootProxy),
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        // vm.mockCall(
        //     address(addresses.bridgehub),
        //     abi.encodeWithSelector(IBridgehub.settlementLayer.selector),
        //     abi.encode(originalChainId)
        // );
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeWithSelector(IBridgehub.whitelistedSettlementLayers.selector),
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
            abi.encodeWithSelector(IBridgehub.getZKChain.selector),
            abi.encode(0x0000000000000000000000000000000000000011)
        );
        vm.store(address(assetTracker), getChainBalanceLocation(assetId, gwChainId), bytes32(amount));

        vm.store(
            address(assetTracker),
            getAssetMigrationNumberLocation(assetId, eraZKChainId),
            bytes32(migrationNumber - 1)
        );
        vm.mockCall(
            address(addresses.ecosystemAddresses.bridgehub.chainAssetHandlerProxy),
            abi.encodeWithSelector(IChainAssetHandler.getMigrationNumber.selector),
            abi.encode(migrationNumber)
        );
        console.log("chainAssetHandler", address(addresses.ecosystemAddresses.bridgehub.chainAssetHandlerProxy));

        assetTracker.receiveMigrationOnL1(finalizeWithdrawalParamsGatewayToL1);

        vm.prank(AddressAliasHelper.applyL1ToL2Alias(l1AssetTracker));
        vm.store(address(assetTracker), chainBalanceLocation, bytes32(amount));
        vm.store(address(l2AssetTracker), chainBalanceLocation, bytes32(amount));
        vm.store(address(l2AssetTracker), getChainBalanceLocation(assetId, eraZKChainId), bytes32(amount));

        l2AssetTracker.confirmMigrationOnGateway(data);
    }

    function test_processLogsAndMessages() public {
        IMessageRoot messageRoot = IMessageRoot(addresses.ecosystemAddresses.bridgehub.messageRootProxy);
        vm.prank(addresses.ecosystemAddresses.bridgehub.bridgehubProxy);
        messageRoot.addNewChain(271);
        bytes
            memory data = hex"000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000000000000000000000000000000000000000b60000000000000000000000000000000000000000000000000000000000000010f0000000000000000000000000000000000000000000000000000000000000001e9ba43cd6a6115fbed8e19ffb4861c51d6dc6e8892697aaf300a7bf9a964a8e8e4ed1ec13a28c40715db6399f6f99ce04e5f19d60ad3ff6831f098cb6cf75944000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000080015c8afd5f049ae313fb4f1184d70daa0bcc1e6a9e9e278e8dd32e6bb75550e8cb00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000008001e032bb1e340662f2985791e59e9ce6a0ce09c2fb77a4783f45ba48f64388a78d00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000008001d939e3209ee0a5f11aba277aa76311368837ead3a3fc514e664a3c909b839df80000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000800197c10b1bd5e6747daf6b1be415f9ba3feac194937e0e6a9eba91f082fb806b2000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000008001635baa5d828aadaa9c5271db99472231fc1ea64a1f8b42a1f3702c0d74e71f9a0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000005000000000000000000000000000000000000000000000000000000000000800109fd3cfe5295f2e787ea7bd32be8486802c3ae1d6aa903b684c37c7f026cb9dd00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000008001aef614ef44a98811ba94aa46578c0631031aafabe4e0b0f419452b00726cc64900000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000070000000000000000000000000000000000000000000000000000000000008001cd771143dd5b0623f8c92844c947f232afaa13082edc8aa89db120df2bbc450200000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000008001cc3ff6a4964b2e2a8abcd01411eaad26b40437b5bc9e3f493f6c7d1e89243ada000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000900000000000000000000000000000000000000000000000000000000000080012bea97e4ee7487bf517216cd5344ccde2730fd019403faba227f1b4a3e9c9c02000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000008001b3897009d582700ffe75d62fd0d2f02f5aadd619855349fdc84501063142bf29000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000b00000000000000000000000000000000000000000000000000000000000080016fb5ccda2c70de0b29909b15cd9e86c99f40fbc9a26c8e470bcca93f1c76e794000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000000000000000000000000000000000000080015ded28cb19b8e38ec8a7714ab99588d8e731b833e2dd59357df07719d48a4fa8000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000d000000000000000000000000000000000000000000000000000000000000800154575102c303596fe83fcad17c07796f042c16e14ea2d95e0f8ac24e5b2ad4e200000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000";
        // ProcessLogsInput memory input = abi.decode(data,(ProcessLogsInput));
        // Note: get this from real local txs
        stdstore
            .target(address(addresses.ecosystemAddresses.bridgehub.messageRootProxy))
            .sig("assetTracker()")
            .checked_write(address(L2_ASSET_TRACKER_ADDR));
        address(l2AssetTracker).call(bytes.concat(hex"e7ca8589", data));
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
