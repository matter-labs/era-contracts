// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {L2_ASSET_ROUTER_ADDR, L2_ASSET_TRACKER_ADDR, L2_BRIDGEHUB_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {ETH_TOKEN_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER} from "contracts/common/Config.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {BridgehubMintCTMAssetData, IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IAssetTrackerBase} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {IAssetRouterBase, NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {SystemContractsArgs} from "./Utils.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {IERC7786GatewaySource} from "contracts/interop/IERC7786GatewaySource.sol";
import {InteroperableAddress} from "@openzeppelin/contracts-master/utils/draft-InteroperableAddress.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {BUNDLE_IDENTIFIER, BridgehubL2TransactionRequest, InteropBundle, InteropCall, InteropCallStarter, L2CanonicalTransaction, L2Log, L2Message, TxStatus} from "contracts/common/Messaging.sol";
import {GasFields, InteropTrigger, TRIGGER_IDENTIFIER} from "contracts/dev-contracts/test/Utils.sol";

abstract contract L2Erc20TestAbstract is Test, SharedL2ContractDeployer {
    using stdStorage for StdStorage;

    address constant UNBUNDLER_ADDRESS = address(0x1);
    address constant EXECUTION_ADDRESS = address(0x2);

    function performDeposit(address depositor, address receiver, uint256 amount) internal {
        vm.prank(aliasedL1AssetRouter);
        L2AssetRouter(L2_ASSET_ROUTER_ADDR).finalizeDeposit({
            _l1Sender: depositor,
            _l2Receiver: receiver,
            _l1Token: L1_TOKEN_ADDRESS,
            _amount: amount,
            _data: encodeTokenData(TOKEN_DEFAULT_NAME, TOKEN_DEFAULT_SYMBOL, TOKEN_DEFAULT_DECIMALS)
        });
    }

    function initializeTokenByDeposit() internal returns (address l2TokenAddress) {
        performDeposit(makeAddr("someDepositor"), makeAddr("someReceiver"), 1);

        l2TokenAddress = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).l2TokenAddress(L1_TOKEN_ADDRESS);
        if (l2TokenAddress == address(0)) {
            revert("Token not initialized");
        }
        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        BridgedStandardERC20(l2TokenAddress).bridgeMint(address(this), 100000);
    }

    function test_shouldFinalizeERC20Deposit() public {
        address depositor = makeAddr("depositor");
        address receiver = makeAddr("receiver");

        performDeposit(depositor, receiver, 100);

        address l2TokenAddress = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).l2TokenAddress(L1_TOKEN_ADDRESS);

        assertEq(BridgedStandardERC20(l2TokenAddress).balanceOf(receiver), 100);
        assertEq(BridgedStandardERC20(l2TokenAddress).totalSupply(), 100);
        assertEq(BridgedStandardERC20(l2TokenAddress).name(), TOKEN_DEFAULT_NAME);
        assertEq(BridgedStandardERC20(l2TokenAddress).symbol(), TOKEN_DEFAULT_SYMBOL);
        assertEq(BridgedStandardERC20(l2TokenAddress).decimals(), TOKEN_DEFAULT_DECIMALS);
    }

    function test_governanceShouldBeAbleToReinitializeToken() public {
        address l2TokenAddress = initializeTokenByDeposit();

        BridgedStandardERC20.ERC20Getters memory getters = BridgedStandardERC20.ERC20Getters({
            ignoreName: false,
            ignoreSymbol: false,
            ignoreDecimals: false
        });

        vm.prank(ownerWallet);
        BridgedStandardERC20(l2TokenAddress).reinitializeToken(getters, "TestTokenNewName", "TTN", 2);
        assertEq(BridgedStandardERC20(l2TokenAddress).name(), "TestTokenNewName");
        assertEq(BridgedStandardERC20(l2TokenAddress).symbol(), "TTN");
        // The decimals should stay the same
        assertEq(BridgedStandardERC20(l2TokenAddress).decimals(), 18);
    }

    function test_governanceShouldNotBeAbleToSkipInitializerVersions() public {
        address l2TokenAddress = initializeTokenByDeposit();

        BridgedStandardERC20.ERC20Getters memory getters = BridgedStandardERC20.ERC20Getters({
            ignoreName: false,
            ignoreSymbol: false,
            ignoreDecimals: false
        });

        vm.expectRevert();
        vm.prank(ownerWallet);
        BridgedStandardERC20(l2TokenAddress).reinitializeToken(getters, "TestTokenNewName", "TTN", 20);
    }

    function test_withdrawTokenNoRegistration() public {
        TestnetERC20Token l2NativeToken = new TestnetERC20Token("token", "T", 18);

        l2NativeToken.mint(address(this), 100);
        l2NativeToken.approve(L2_NATIVE_TOKEN_VAULT_ADDR, 100);

        // Basically we want all L2->L1 transactions to pass
        vm.mockCall(
            address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR),
            abi.encodeWithSignature("sendToL1(bytes)"),
            abi.encode(bytes32(uint256(1)))
        );

        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, address(l2NativeToken));


        IL2AssetRouter(L2_ASSET_ROUTER_ADDR).withdraw(
            assetId,
            DataEncoding.encodeBridgeBurnData(100, address(1), address(l2NativeToken))
        );
    }

    function test_requestTokenTransferInterop() public {
        address l2TokenAddress = initializeTokenByDeposit();
        bytes32 l2TokenAssetId = l2NativeTokenVault.assetId(l2TokenAddress);
        vm.deal(address(this), 1000 ether);
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.getSettlementLayerChainId.selector),
            abi.encode(block.chainid)
        );

        bytes memory secondBridgeCalldata = bytes.concat(
            NEW_ENCODING_VERSION,
            abi.encode(l2TokenAssetId, abi.encode(uint256(100), address(this), 0))
        );

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        bytes[] memory callAttributes = new bytes[](1);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.indirectCall, (0));

        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(L2_ASSET_ROUTER_ADDR),
            data: secondBridgeCalldata,
            callAttributes: callAttributes
        });

        uint256 destinationChainId = 271;
        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes(""))
        );
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehub.baseTokenAssetId.selector),
            abi.encode(baseTokenAssetId)
        );

        vm.mockCall(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_BASE_TOKEN_SYSTEM_CONTRACT.burnMsgValue.selector),
            abi.encode(bytes(""))
        );

        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(271), calls, bundleAttributes);
    }

    function test_requestSendCall() public {
        address l2TokenAddress = initializeTokenByDeposit();
        bytes32 l2TokenAssetId = l2NativeTokenVault.assetId(l2TokenAddress);
        vm.deal(address(this), 1000 ether);

        bytes memory secondBridgeCalldata = bytes.concat(
            NEW_ENCODING_VERSION,
            abi.encode(l2TokenAssetId, abi.encode(uint256(100), address(this), 0))
        );
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.getSettlementLayerChainId.selector),
            abi.encode(block.chainid)
        );

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        bytes[] memory attributes = new bytes[](3);
        attributes[0] = abi.encodeCall(IERC7786Attributes.indirectCall, (0));
        attributes[1] = abi.encodeCall(
            IERC7786Attributes.executionAddress,
            (InteroperableAddress.formatEvmV1(EXECUTION_ADDRESS))
        );
        attributes[2] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(L2_ASSET_ROUTER_ADDR),
            data: secondBridgeCalldata,
            callAttributes: attributes
        });

        uint256 destinationChainId = 271;
        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes(""))
        );
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehub.baseTokenAssetId.selector),
            abi.encode(baseTokenAssetId)
        );

        vm.mockCall(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_BASE_TOKEN_SYSTEM_CONTRACT.burnMsgValue.selector),
            abi.encode(bytes(""))
        );
        IERC7786GatewaySource(address(l2InteropCenter)).sendMessage(
            calls[0].to,
            calls[0].data,
            calls[0].callAttributes
        );
    }

    function test_supportsAttributes() public {
        assertEq(
            IERC7786GatewaySource(address(l2InteropCenter)).supportsAttribute(IERC7786Attributes.indirectCall.selector),
            true
        );
        assertEq(
            IERC7786GatewaySource(address(l2InteropCenter)).supportsAttribute(
                IERC7786GatewaySource.supportsAttribute.selector
            ),
            false
        );
    }
}
