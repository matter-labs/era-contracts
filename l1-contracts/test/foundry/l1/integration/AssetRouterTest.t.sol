// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {console2 as console} from "forge-std/console2.sol";

import {IBridgehubBase, L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehubBase.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {ETH_TOKEN_ADDRESS, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2Message} from "contracts/common/Messaging.sol";
import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {NativeTokenVaultBase} from "contracts/bridge/ntv/NativeTokenVaultBase.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IAssetRouterBase, NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {BridgeHelper} from "contracts/bridge/BridgeHelper.sol";
import {BridgedStandardERC20, NonSequentialVersion} from "contracts/bridge/BridgedStandardERC20.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {ConfigSemaphore} from "./utils/_ConfigSemaphore.sol";

contract AssetRouterIntegrationTest is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker, ConfigSemaphore {
    uint256 constant TEST_USERS_COUNT = 10;
    address[] public users;
    address[] public l2ContractAddresses;
    bytes32 public l2TokenAssetId;
    address public tokenL1Address;
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
            abi.encodeWithSignature("L1_CHAIN_ID()"),
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

    // add this to be excluded from coverage report
    function test() internal override {}
}
