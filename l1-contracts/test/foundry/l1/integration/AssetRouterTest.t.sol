// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2 as console} from "forge-std/console2.sol";

import {IBridgehubBase, L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehubBase.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {SimpleExecutor} from "contracts/dev-contracts/SimpleExecutor.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {ETH_TOKEN_ADDRESS, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2Message} from "contracts/common/Messaging.sol";
import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {NativeTokenVaultBase} from "contracts/bridge/ntv/NativeTokenVaultBase.sol";
import {FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IAssetRouterBase, NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {BridgeHelper} from "contracts/bridge/BridgeHelper.sol";
import {BridgedStandardERC20, NonSequentialVersion} from "contracts/bridge/BridgedStandardERC20.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {ConfigSemaphore} from "./utils/_ConfigSemaphore.sol";

contract AssetRouterIntegrationTest is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker, ConfigSemaphore {
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

        takeConfigLock(); // Prevents race condition with configs

        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);

        _deployEra();

        simpleExecutor = new SimpleExecutor();
        // _deployHyperchain(ETH_TOKEN_ADDRESS);
        // _deployHyperchain(ETH_TOKEN_ADDRESS);
        // _deployHyperchain(tokens[0]);
        // _deployHyperchain(tokens[0]);
        // _deployHyperchain(tokens[1]);
        // _deployHyperchain(tokens[1]);

        releaseConfigLock();

        for (uint256 i = 0; i < zkChainIds.length; i++) {
            address contractAddress = makeAddr(string(abi.encode("contract", i)));
            l2ContractAddresses.push(contractAddress);

            _addL2ChainContract(zkChainIds[i], contractAddress);
        }
    }

    function setUp() public {
        prepare();
    }

    function depositToL1(address _tokenAddress) public {
        vm.mockCall(
            address(addresses.bridgehub),
            abi.encodeWithSelector(IBridgehubBase.proveL2MessageInclusion.selector),
            abi.encode(true)
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
                    IAssetRouterBase.finalizeDeposit.selector,
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
        address owner = addresses.l1NativeTokenVault.owner();
        vm.broadcast(owner);
        bridgedToken.reinitializeToken(
            BridgedStandardERC20.ERC20Getters({ignoreName: false, ignoreSymbol: false, ignoreDecimals: false}),
            "TestnetERC20Token",
            "TST",
            2
        );
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
            abi.encodeWithSelector(NativeTokenVaultBase.L1_CHAIN_ID.selector),
            abi.encode(block.chainid)
        );
        vm.broadcast(L2_NATIVE_TOKEN_VAULT_ADDR); // kl todo call ntv, or even assetRouter/bridgehub
        bridgedToken.bridgeBurn(address(this), 100);
    }

    function test_DepositToL1AndWithdraw() public {
        depositToL1(ETH_TOKEN_ADDRESS);
        bytes memory secondBridgeCalldata = bytes.concat(
            NEW_ENCODING_VERSION,
            abi.encode(l2TokenAssetId, abi.encode(uint256(100), address(this), tokenL1Address))
        );
        IERC20(tokenL1Address).approve(address(addresses.l1NativeTokenVault), 100);
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
                IBridgehub.requestL2TransactionTwoBridges.selector,
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
        assertEq(selector, IAssetRouterBase.finalizeDeposit.selector, "Selector mismatch");
        // Checking refund recipient is correct; commented out before foundry is not updated
        // assert(address(uint160(request.transaction.reserved[1])) == randomCaller);

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
            assert(remoteReceiver == randomCaller);
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
