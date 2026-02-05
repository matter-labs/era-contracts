// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {IAssetHandler} from "contracts/bridge/interfaces/IAssetHandler.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

contract MockAssetHandler is IAssetHandler {
    bool public called;
    uint256 public lastChainId;
    bytes32 public lastAssetId;
    bytes public lastTransferData;

    function bridgeMint(uint256 _chainId, bytes32 _assetId, bytes calldata _transferData) external payable override {
        called = true;
        lastChainId = _chainId;
        lastAssetId = _assetId;
        lastTransferData = _transferData;
    }

    function bridgeBurn(
        uint256 _chainId,
        uint256 _msgValue,
        bytes32 _assetId,
        address _originalCaller,
        bytes calldata _data
    ) external payable override returns (bytes memory) {
        return abi.encode("mock");
    }
}

contract TestAssetRouterBase is AssetRouterBase {
    address public nativeTokenVault;

    // constructor() AssetRouterBase(1, 1, IBridgehubBase(address(1))) {}

    function setAssetHandlerAddressThisChain(bytes32, address) external override {}

    function bridgehubDepositBaseToken(uint256, bytes32, address, uint256) external payable override {}

    function finalizeDeposit(uint256 _chainId, bytes32 _assetId, bytes calldata _transferData) public payable override {
        _finalizeDeposit(_chainId, _assetId, _transferData, nativeTokenVault);
    }

    function _ensureTokenRegisteredWithNTV(address) internal pure override returns (bytes32) {
        return keccak256("test");
    }

    function setNTV(address _ntv) external {
        nativeTokenVault = _ntv;
    }

    function setAssetHandler(bytes32 _assetId, address _handler) external {
        assetHandlerAddress[_assetId] = _handler;
    }

    function BRIDGE_HUB() external view returns (IBridgehubBase) {
        return IBridgehubBase(address(1));
    }

    function L1_CHAIN_ID() external view returns (uint256) {
        return 1;
    }

    function _bridgehub() internal view override returns (IBridgehubBase) {
        return IBridgehubBase(address(1));
    }

    function _l1ChainId() internal view returns (uint256) {
        return 1;
    }

    function _eraChainId() internal view returns (uint256) {
        return 1;
    }
}

contract AssetRouterBase_FinalizeDepositBranches_Test is Test {
    TestAssetRouterBase router;
    MockAssetHandler existingHandler;
    MockAssetHandler ntvHandler;

    function setUp() public {
        router = new TestAssetRouterBase();
        existingHandler = new MockAssetHandler();
        ntvHandler = new MockAssetHandler();
        router.setNTV(address(ntvHandler));
    }

    function test_ExistingAssetHandler_CallsHandler() public {
        bytes32 assetId = keccak256("testAsset");
        bytes memory transferData = abi.encode("testData");

        // Set existing handler
        router.setAssetHandler(assetId, address(existingHandler));

        router.finalizeDeposit{value: 1 ether}(1, assetId, transferData);

        assertTrue(existingHandler.called());
        assertEq(existingHandler.lastChainId(), 1);
        assertEq(existingHandler.lastAssetId(), assetId);
        assertEq(keccak256(existingHandler.lastTransferData()), keccak256(transferData));

        // NTV should not be called
        assertFalse(ntvHandler.called());
    }

    function test_NoAssetHandler_AutoRegistersNTV() public {
        bytes32 assetId = keccak256("newAsset");
        bytes memory transferData = abi.encode("testData");

        // No handler set for this assetId
        assertEq(router.assetHandlerAddress(assetId), address(0));

        router.finalizeDeposit{value: 1 ether}(1, assetId, transferData);

        // NTV should be called
        assertTrue(ntvHandler.called());
        assertEq(ntvHandler.lastChainId(), 1);
        assertEq(ntvHandler.lastAssetId(), assetId);
        assertEq(keccak256(ntvHandler.lastTransferData()), keccak256(transferData));

        // Asset handler should be registered
        assertEq(router.assetHandlerAddress(assetId), address(ntvHandler));
    }
}
