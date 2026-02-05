// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CTMDeploymentTracker, CTM_DEPLOYMENT_TRACKER_ENCODING_VERSION} from "contracts/core/ctm-deployment/CTMDeploymentTracker.sol";
import {IBridgehubBase, L2TransactionRequestTwoBridgesInner} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {L2_CHAIN_ASSET_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {NoEthAllowed, NotOwner, NotOwnerViaRouter, OnlyBridgehub, WrongCounterPart} from "contracts/core/bridgehub/L1BridgehubErrors.sol";
import {CTMNotRegistered, UnsupportedEncodingVersion} from "contracts/common/L1ContractErrors.sol";

/// @title Extended tests for CTMDeploymentTracker to increase coverage
contract CTMDeploymentTrackerExtendedTest is Test {
    CTMDeploymentTracker public ctmDeploymentTracker;

    address public owner;
    address public proxyAdmin;
    address public bridgehub;
    address public assetRouter;
    address public chainAssetHandler;

    function setUp() public {
        owner = makeAddr("owner");
        proxyAdmin = makeAddr("proxyAdmin");
        bridgehub = makeAddr("bridgehub");
        assetRouter = makeAddr("assetRouter");
        chainAssetHandler = makeAddr("chainAssetHandler");

        CTMDeploymentTracker impl = new CTMDeploymentTracker(IBridgehubBase(bridgehub), IAssetRouterBase(assetRouter));

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            proxyAdmin,
            abi.encodeWithSelector(CTMDeploymentTracker.initialize.selector, owner)
        );

        ctmDeploymentTracker = CTMDeploymentTracker(address(proxy));
    }

    function test_Initialize_SetsOwner() public view {
        assertEq(ctmDeploymentTracker.owner(), owner);
    }

    function test_BRIDGE_HUB() public view {
        assertEq(address(ctmDeploymentTracker.BRIDGE_HUB()), bridgehub);
    }

    function test_L1_ASSET_ROUTER() public view {
        assertEq(address(ctmDeploymentTracker.L1_ASSET_ROUTER()), assetRouter);
    }

    function test_OnlyBridgehub_RevertWhen_NotBridgehub() public {
        address notBridgehub = makeAddr("notBridgehub");
        uint256 chainId = 123;
        bytes memory data = abi.encodePacked(
            CTM_DEPLOYMENT_TRACKER_ENCODING_VERSION,
            abi.encode(address(0), address(0))
        );

        vm.prank(notBridgehub);
        vm.expectRevert(abi.encodeWithSelector(OnlyBridgehub.selector, notBridgehub, bridgehub));
        ctmDeploymentTracker.bridgehubDeposit(chainId, owner, 0, data);
    }

    function test_BridgehubDeposit_RevertWhen_EthSent() public {
        uint256 chainId = 123;
        bytes memory data = abi.encodePacked(
            CTM_DEPLOYMENT_TRACKER_ENCODING_VERSION,
            abi.encode(address(0), address(0))
        );

        vm.deal(bridgehub, 1 ether);
        vm.prank(bridgehub);
        vm.expectRevert(NoEthAllowed.selector);
        ctmDeploymentTracker.bridgehubDeposit{value: 1 ether}(chainId, owner, 0, data);
    }

    function test_BridgehubDeposit_RevertWhen_NotOwner() public {
        address notOwner = makeAddr("notOwner");
        uint256 chainId = 123;
        bytes memory data = abi.encodePacked(
            CTM_DEPLOYMENT_TRACKER_ENCODING_VERSION,
            abi.encode(address(0), address(0))
        );

        vm.prank(bridgehub);
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector, notOwner, owner));
        ctmDeploymentTracker.bridgehubDeposit(chainId, notOwner, 0, data);
    }

    function test_BridgehubDeposit_RevertWhen_UnsupportedEncodingVersion() public {
        uint256 chainId = 123;
        bytes memory data = abi.encodePacked(bytes1(0xFF), abi.encode(address(0), address(0)));

        vm.prank(bridgehub);
        vm.expectRevert(UnsupportedEncodingVersion.selector);
        ctmDeploymentTracker.bridgehubDeposit(chainId, owner, 0, data);
    }

    function test_BridgehubDeposit_Success() public {
        uint256 chainId = 123;
        address ctmL1Address = makeAddr("ctmL1Address");
        address ctmL2Address = makeAddr("ctmL2Address");
        bytes memory data = abi.encodePacked(
            CTM_DEPLOYMENT_TRACKER_ENCODING_VERSION,
            abi.encode(ctmL1Address, ctmL2Address)
        );

        vm.prank(bridgehub);
        L2TransactionRequestTwoBridgesInner memory request = ctmDeploymentTracker.bridgehubDeposit(
            chainId,
            owner,
            0,
            data
        );

        // Verify the request
        assertTrue(request.magicValue != bytes32(0));
    }

    function test_BridgehubConfirmL2Transaction_Success() public {
        uint256 chainId = 123;
        bytes32 txDataHash = keccak256("txDataHash");
        bytes32 txHash = keccak256("txHash");

        // This function is a no-op but should not revert
        vm.prank(bridgehub);
        ctmDeploymentTracker.bridgehubConfirmL2Transaction(chainId, txDataHash, txHash);
    }

    function test_BridgehubConfirmL2Transaction_RevertWhen_NotBridgehub() public {
        address notBridgehub = makeAddr("notBridgehub");
        uint256 chainId = 123;
        bytes32 txDataHash = keccak256("txDataHash");
        bytes32 txHash = keccak256("txHash");

        vm.prank(notBridgehub);
        vm.expectRevert(abi.encodeWithSelector(OnlyBridgehub.selector, notBridgehub, bridgehub));
        ctmDeploymentTracker.bridgehubConfirmL2Transaction(chainId, txDataHash, txHash);
    }

    function test_BridgeCheckCounterpartAddress_RevertWhen_NotOwnerViaRouter() public {
        address notRouter = makeAddr("notRouter");

        vm.prank(notRouter);
        vm.expectRevert(abi.encodeWithSelector(NotOwnerViaRouter.selector, notRouter, owner));
        ctmDeploymentTracker.bridgeCheckCounterpartAddress(123, bytes32(0), owner, L2_CHAIN_ASSET_HANDLER_ADDR);
    }

    function test_BridgeCheckCounterpartAddress_RevertWhen_WrongCounterpart() public {
        address wrongCounterpart = makeAddr("wrongCounterpart");

        vm.prank(assetRouter);
        vm.expectRevert(
            abi.encodeWithSelector(WrongCounterPart.selector, wrongCounterpart, L2_CHAIN_ASSET_HANDLER_ADDR)
        );
        ctmDeploymentTracker.bridgeCheckCounterpartAddress(123, bytes32(0), owner, wrongCounterpart);
    }

    function test_BridgeCheckCounterpartAddress_Success() public {
        vm.prank(assetRouter);
        ctmDeploymentTracker.bridgeCheckCounterpartAddress(123, bytes32(0), owner, L2_CHAIN_ASSET_HANDLER_ADDR);
    }

    function test_RegisterCTMAssetOnL1_RevertWhen_NotOwner() public {
        address notOwner = makeAddr("notOwner");
        address ctmAddress = makeAddr("ctmAddress");

        vm.prank(notOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        ctmDeploymentTracker.registerCTMAssetOnL1(ctmAddress);
    }

    function test_RegisterCTMAssetOnL1_RevertWhen_CTMNotRegistered() public {
        address ctmAddress = makeAddr("ctmAddress");

        // Mock chainTypeManagerIsRegistered to return false
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.chainTypeManagerIsRegistered.selector, ctmAddress),
            abi.encode(false)
        );

        vm.prank(owner);
        vm.expectRevert(CTMNotRegistered.selector);
        ctmDeploymentTracker.registerCTMAssetOnL1(ctmAddress);
    }

    function test_RegisterCTMAssetOnL1_Success() public {
        address ctmAddress = makeAddr("ctmAddress");

        // Mock chainTypeManagerIsRegistered to return true
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.chainTypeManagerIsRegistered.selector, ctmAddress),
            abi.encode(true)
        );

        // Mock chainAssetHandler
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(chainAssetHandler)
        );

        // Mock setAssetHandlerAddressThisChain
        vm.mockCall(
            assetRouter,
            abi.encodeWithSelector(bytes4(keccak256("setAssetHandlerAddressThisChain(bytes32,address)"))),
            abi.encode()
        );

        // Mock setCTMAssetAddress
        vm.mockCall(bridgehub, abi.encodeWithSelector(IBridgehubBase.setCTMAssetAddress.selector), abi.encode());

        vm.prank(owner);
        ctmDeploymentTracker.registerCTMAssetOnL1(ctmAddress);
    }

    function test_SetCtmAssetHandlerAddressOnL1_RevertWhen_NotOwner() public {
        address notOwner = makeAddr("notOwner");
        address ctmAddress = makeAddr("ctmAddress");

        vm.prank(notOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        ctmDeploymentTracker.setCtmAssetHandlerAddressOnL1(ctmAddress);
    }

    function test_SetCtmAssetHandlerAddressOnL1_Success() public {
        address ctmAddress = makeAddr("ctmAddress");

        // Mock chainAssetHandler
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(chainAssetHandler)
        );

        // Mock setAssetHandlerAddressThisChain
        vm.mockCall(
            assetRouter,
            abi.encodeWithSelector(bytes4(keccak256("setAssetHandlerAddressThisChain(bytes32,address)"))),
            abi.encode()
        );

        vm.prank(owner);
        ctmDeploymentTracker.setCtmAssetHandlerAddressOnL1(ctmAddress);
    }

    function test_CalculateAssetId() public {
        address ctmAddress = makeAddr("ctmAddress");
        bytes32 assetId = ctmDeploymentTracker.calculateAssetId(ctmAddress);

        // Verify it's not zero and matches expected calculation
        assertTrue(assetId != bytes32(0));
        bytes32 expected = keccak256(
            abi.encode(block.chainid, address(ctmDeploymentTracker), bytes32(uint256(uint160(ctmAddress))))
        );
        assertEq(assetId, expected);
    }

    function testFuzz_CalculateAssetId(address ctmAddress) public view {
        vm.assume(ctmAddress != address(0));
        bytes32 assetId = ctmDeploymentTracker.calculateAssetId(ctmAddress);
        assertTrue(assetId != bytes32(0));
    }

    function testFuzz_BridgehubDeposit_VariousAddresses(address ctmL1Address, address ctmL2Address) public {
        uint256 chainId = 123;
        bytes memory data = abi.encodePacked(
            CTM_DEPLOYMENT_TRACKER_ENCODING_VERSION,
            abi.encode(ctmL1Address, ctmL2Address)
        );

        vm.prank(bridgehub);
        L2TransactionRequestTwoBridgesInner memory request = ctmDeploymentTracker.bridgehubDeposit(
            chainId,
            owner,
            0,
            data
        );

        // Just verify it doesn't revert
        assertTrue(request.l2Calldata.length > 0);
    }
}
