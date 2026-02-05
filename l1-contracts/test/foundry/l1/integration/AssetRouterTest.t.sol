// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {IBridgehubBase, L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {Vm} from "forge-std/Vm.sol";

import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {SimpleExecutor} from "contracts/dev-contracts/SimpleExecutor.sol";

import {IMessageRootBase, IMessageVerification} from "contracts/core/message-root/IMessageRoot.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {ETH_TOKEN_ADDRESS, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2Message} from "contracts/common/Messaging.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
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

contract AssetRouterIntegrationTest is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
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
        _deployTokens();
        _registerNewTokens(tokens);

        _deployEra();
        _deployZKChain(ETH_TOKEN_ADDRESS);

        simpleExecutor = new SimpleExecutor();

        for (uint256 i = 0; i < zkChainIds.length; i++) {
            address contractAddress = makeAddr(string(abi.encode("contract", i)));
            l2ContractAddresses.push(contractAddress);

            _addL2ChainContract(zkChainIds[i], contractAddress);
        }
    }

    function _setAssetTrackerChainBalance(uint256 _chainId, address _token, uint256 _value) internal {
        bytes32 assetId = DataEncoding.encodeNTVAssetId(eraZKChainId, _token);
        if (address(addresses.l1AssetTracker) != address(0)) {
            stdstore
                .target(address(addresses.l1AssetTracker))
                .sig(IAssetTrackerBase.chainBalance.selector)
                .with_key(_chainId)
                .with_key(assetId)
                .checked_write(_value);
        }
    }

    function setUp() public {
        prepare();
        bytes32 ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(eraZKChainId, ETH_TOKEN_ADDRESS);

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

        _setAssetTrackerChainBalance(eraZKChainId, ETH_TOKEN_ADDRESS, 1e30);
        _setAssetTrackerChainBalance(506, ETH_TOKEN_ADDRESS, 1e30);
        bytes32 ethAssetId = 0x8df3463b1850eb1d8d1847743ea155aef6b16074db8ba81d897dc30554fb2085;
        stdstore
            .target(address(ecosystemAddresses.bridgehub.proxies.assetTracker))
            .sig(IAssetTrackerBase.chainBalance.selector)
            .with_key(eraZKChainId)
            .with_key(ETH_TOKEN_ASSET_ID)
            .checked_write(100);
        vm.prank(Ownable2StepUpgradeable(addresses.l1NativeTokenVault).pendingOwner());
        Ownable2StepUpgradeable(addresses.l1NativeTokenVault).acceptOwnership();
    }

    function depositToL1(address _tokenAddress) public {
        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.messageRoot),
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector),
            abi.encode(506)
        );
        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.messageRoot),
            abi.encodeWithSelector(IMessageRootBase.getProofData.selector),
            abi.encode(
                ProofData({
                    settlementLayerChainId: 506,
                    settlementLayerBatchNumber: 0,
                    settlementLayerBatchRootMask: 0,
                    batchLeafProofLen: 0,
                    batchSettlementRoot: 0,
                    chainIdLeaf: 0,
                    ptr: 0,
                    finalProofNode: false
                })
            )
        );
        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.messageRoot),
            abi.encodeWithSelector(IL1MessageRoot.v31UpgradeChainBatchNumber.selector),
            abi.encode(10)
        );
        uint256 chainId = eraZKChainId;
        l2TokenAssetId = DataEncoding.encodeNTVAssetId(chainId, _tokenAddress);
        bytes memory transferData = DataEncoding.encodeBridgeMintData({
            _originalCaller: ETH_TOKEN_ADDRESS,
            _remoteReceiver: address(this),
            _originToken: ETH_TOKEN_ADDRESS,
            _amount: 100,
            _erc20Metadata: BridgeHelper.getERC20Getters(_tokenAddress, chainId)
        });
        addresses.l1Nullifier.finalizeDeposit(
            FinalizeL1DepositParams({
                chainId: chainId,
                l2BatchNumber: 1,
                l2MessageIndex: 1,
                l2Sender: L2_ASSET_ROUTER_ADDR,
                l2TxNumberInBatch: 1,
                message: abi.encodePacked(
                    AssetRouterBase.finalizeDeposit.selector,
                    chainId,
                    l2TokenAssetId,
                    transferData
                ),
                merkleProof: new bytes32[](0)
            })
        );
        tokenL1Address = addresses.l1NativeTokenVault.tokenAddress(l2TokenAssetId);
    }

    function test_DepositToL1_Success() public {
        depositToL1(ETH_TOKEN_ADDRESS);

        // Verify the token was deposited and registered
        assertTrue(tokenL1Address != address(0), "Token L1 address should be set after deposit");
        assertTrue(l2TokenAssetId != bytes32(0), "L2 token asset ID should be set after deposit");

        // Verify the token address is correctly mapped in NTV
        assertEq(
            addresses.l1NativeTokenVault.tokenAddress(l2TokenAssetId),
            tokenL1Address,
            "Token address should match the registered address"
        );
    }

    function test_BridgeTokenFunctions() public {
        depositToL1(ETH_TOKEN_ADDRESS);
        BridgedStandardERC20 bridgedToken = BridgedStandardERC20(
            addresses.l1NativeTokenVault.tokenAddress(l2TokenAssetId)
        );
        assertEq(bridgedToken.name(), "Ether");
        assertEq(bridgedToken.symbol(), "ETH");
        assertEq(bridgedToken.decimals(), 18);
    }

    function test_reinitBridgedToken_Success() public {
        depositToL1(ETH_TOKEN_ADDRESS);
        BridgedStandardERC20 bridgedToken = BridgedStandardERC20(
            addresses.l1NativeTokenVault.tokenAddress(l2TokenAssetId)
        );

        // Verify initial token properties before reinit
        string memory nameBefore = bridgedToken.name();
        string memory symbolBefore = bridgedToken.symbol();

        address owner = addresses.l1NativeTokenVault.owner();
        vm.broadcast(owner);
        bridgedToken.reinitializeToken(
            BridgedStandardERC20.ERC20Getters({ignoreName: false, ignoreSymbol: false, ignoreDecimals: false}),
            "TestnetERC20Token",
            "TST",
            2
        );

        // Verify the token was reinitialized with new values
        assertEq(bridgedToken.name(), "TestnetERC20Token", "Token name should be updated after reinit");
        assertEq(bridgedToken.symbol(), "TST", "Token symbol should be updated after reinit");
    }

    function test_reinitBridgedToken_WrongVersion() public {
        depositToL1(ETH_TOKEN_ADDRESS);
        BridgedStandardERC20 bridgedToken = BridgedStandardERC20(
            addresses.l1NativeTokenVault.tokenAddress(l2TokenAssetId)
        );
        vm.expectRevert(NonSequentialVersion.selector);
        bridgedToken.reinitializeToken(
            BridgedStandardERC20.ERC20Getters({ignoreName: false, ignoreSymbol: false, ignoreDecimals: false}),
            "TestnetERC20Token",
            "TST",
            3
        );
    }

    /// @dev We should not test this on the L1, but to get coverage we do.
    function test_BridgeTokenBurn() public {
        depositToL1(ETH_TOKEN_ADDRESS);
        BridgedStandardERC20 bridgedToken = BridgedStandardERC20(
            addresses.l1NativeTokenVault.tokenAddress(l2TokenAssetId)
        );
        // setting nativeTokenVault to zero address.
        vm.store(address(bridgedToken), bytes32(uint256(207)), bytes32(0));
        vm.mockCall(
            address(L2_NATIVE_TOKEN_VAULT_ADDR),
            abi.encodeWithSignature("L1_CHAIN_ID()"),
            abi.encode(block.chainid)
        );
        vm.broadcast(L2_NATIVE_TOKEN_VAULT_ADDR); // kl todo call ntv, or even assetRouter/bridgehub
        bridgedToken.bridgeBurn(address(this), 100);
    }

    function test_DepositToL1AndWithdraw() public {
        depositToL1(ETH_TOKEN_ADDRESS);

        // Store balances before withdrawal
        uint256 balanceBefore = IERC20(tokenL1Address).balanceOf(address(this));

        bytes memory secondBridgeCalldata = bytes.concat(
            NEW_ENCODING_VERSION,
            abi.encode(l2TokenAssetId, abi.encode(uint256(100), address(this), tokenL1Address))
        );
        IERC20(tokenL1Address).approve(address(addresses.l1NativeTokenVault), 100);

        vm.recordLogs();
        addresses.bridgehub.requestL2TransactionTwoBridges{value: 250000000000100}(
            L2TransactionRequestTwoBridgesOuter({
                chainId: eraZKChainId,
                mintValue: 250000000000100,
                l2Value: 0,
                l2GasLimit: 1000000,
                l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                refundRecipient: address(0),
                secondBridgeAddress: address(addresses.sharedBridge),
                secondBridgeValue: 0,
                secondBridgeCalldata: secondBridgeCalldata
            })
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Verify transaction was recorded (logs were emitted)
        assertTrue(logs.length > 0, "Transaction should emit logs");

        // Verify balance decreased after withdrawal request
        uint256 balanceAfter = IERC20(tokenL1Address).balanceOf(address(this));
        assertEq(balanceBefore - balanceAfter, 100, "Balance should decrease by withdrawal amount");
    }

    function test_DepositDirect() public {
        depositToL1(ETH_TOKEN_ADDRESS);

        bytes memory secondBridgeCalldata = bytes.concat(
            NEW_ENCODING_VERSION,
            abi.encode(l2TokenAssetId, abi.encode(uint256(100), address(this)))
        );
        IERC20(tokenL1Address).approve(address(addresses.l1NativeTokenVault), 100);

        vm.recordLogs();
        addresses.bridgehub.requestL2TransactionDirect{value: 250000000000100}(
            L2TransactionRequestDirect({
                chainId: eraZKChainId,
                mintValue: 250000000000100,
                l2Contract: address(addresses.sharedBridge),
                l2Value: 0,
                l2Calldata: secondBridgeCalldata,
                l2GasLimit: 1000000,
                l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                factoryDeps: new bytes[](0),
                refundRecipient: address(0)
            })
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Verify transaction was recorded (logs were emitted)
        assertTrue(logs.length > 0, "Direct transaction should emit logs");

        // Direct transactions send calldata to L2 without going through the bridge's token transfer
        // Verify the calldata was properly encoded
        assertTrue(secondBridgeCalldata.length > 0, "Second bridge calldata should not be empty");
    }

    function test_DepositToL1AndWithdraw7702() public {
        uint256 randomCallerPk = uint256(keccak256("RANDOM_CALLER"));
        address payable randomCaller = payable(vm.addr(randomCallerPk));
        vm.deal(randomCaller, 1 ether);
        depositToL1(ETH_TOKEN_ADDRESS);
        vm.prank(address(this));
        IERC20(tokenL1Address).transfer(randomCaller, 100);
        bytes memory secondBridgeCalldata = bytes.concat(
            NEW_ENCODING_VERSION,
            abi.encode(l2TokenAssetId, abi.encode(uint256(100), randomCaller, tokenL1Address))
        );

        vm.prank(randomCaller);
        IERC20(tokenL1Address).approve(address(addresses.l1NativeTokenVault), 100);
        assertEq(IERC20(tokenL1Address).allowance(randomCaller, address(addresses.l1NativeTokenVault)), 100);

        {
            L2TransactionRequestTwoBridgesOuter memory l2TxnReqTwoBridges = L2TransactionRequestTwoBridgesOuter({
                chainId: eraZKChainId,
                mintValue: 250000000000100,
                l2Value: 0,
                l2GasLimit: 1000000,
                l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                refundRecipient: address(0),
                secondBridgeAddress: address(addresses.sharedBridge),
                secondBridgeValue: 0,
                secondBridgeCalldata: secondBridgeCalldata
            });

            bytes memory calldataForExecutor = abi.encodeWithSelector(
                IL1Bridgehub.requestL2TransactionTwoBridges.selector,
                l2TxnReqTwoBridges
            );

            vm.signAndAttachDelegation(address(simpleExecutor), randomCallerPk);

            vm.recordLogs();
            vm.prank(randomCaller);
            SimpleExecutor(randomCaller).execute(address(addresses.bridgehub), 250000000000100, calldataForExecutor);
        }

        Vm.Log[] memory logs = vm.getRecordedLogs();
        NewPriorityRequest memory request = _getNewPriorityQueueFromLogs(logs);

        // Step 1: Strip selector and decode into (uint256, bytes32, bytes)
        bytes memory callData = request.transaction.data;
        bytes32 selector;
        assembly {
            selector := mload(add(callData, 32)) // load first 32 bytes, selector is first 4
        }

        // Verify selector matches finalizeDeposit
        assertEq(selector, AssetRouterBase.finalizeDeposit.selector, "Selector mismatch");
        assertEq(address(uint160(request.transaction.reserved[1])), randomCaller, "Refund recipient mismatch");

        // Allocate new bytes without the 4-byte selector
        bytes memory args = new bytes(callData.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = callData[i + 4];
        }

        // Now decode the first layer
        bytes memory assetData;
        {
            uint256 chainId;
            bytes32 assetId;
            (chainId, assetId, assetData) = abi.decode(args, (uint256, bytes32, bytes));
        }

        // Step 2: Decode assetData into the bridge mint fields
        {
            (
                address originalCaller,
                address remoteReceiver,
                address parsedOriginToken,
                uint256 amount,
                bytes memory erc20Metadata
            ) = abi.decode(assetData, (address, address, address, uint256, bytes));

            // Checking that caller hasn't been aliased
            assertEq(remoteReceiver, randomCaller, "Remote receiver mismatch");
        }
    }

    // add this to be excluded from coverage report
    function test() internal override {}

    // gets event from logs
    function _getNewPriorityQueueFromLogs(Vm.Log[] memory logs) internal returns (NewPriorityRequest memory request) {
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory log = logs[i];

            if (log.topics[0] == NEW_PRIORITY_REQUEST_HASH) {
                (
                    request.txId,
                    request.txHash,
                    request.expirationTimestamp,
                    request.transaction,
                    request.factoryDeps
                ) = abi.decode(log.data, (uint256, bytes32, uint64, L2CanonicalTransaction, bytes[]));
            }
        }
    }
}
