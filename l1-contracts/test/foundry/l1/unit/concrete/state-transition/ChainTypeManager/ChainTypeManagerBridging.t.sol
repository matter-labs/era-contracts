// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {AdminZero, OutdatedProtocolVersion} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {TxStatus} from "contracts/common/Messaging.sol";

contract ChainTypeManagerBridgingTest is ChainTypeManagerTest {
    address internal chainAssetHandlerMock;

    function setUp() public {
        deploy();
        chainAssetHandlerMock = makeAddr("chainAssetHandler");
    }

    // Test onlyChainAssetHandler modifier reverts for non-asset-handler
    function test_RevertWhen_forwardedBridgeBurnNotChainAssetHandler() public {
        vm.stopPrank();

        address notAssetHandler = makeAddr("notAssetHandler");

        // Mock chainAssetHandler to return a different address
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSignature("chainAssetHandler()"),
            abi.encode(chainAssetHandlerMock)
        );

        vm.prank(notAssetHandler);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notAssetHandler));
        chainContractAddress.forwardedBridgeBurn(chainId, abi.encode(makeAddr("admin"), bytes("")));
    }

    // Test forwardedBridgeBurn reverts when admin is zero
    function test_RevertWhen_forwardedBridgeBurnAdminZero() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));
        _mockGetZKChainFromBridgehub(chainAddress);

        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSignature("chainAssetHandler()"),
            abi.encode(chainAssetHandlerMock)
        );

        vm.stopPrank();
        vm.prank(chainAssetHandlerMock);
        vm.expectRevert(AdminZero.selector);
        chainContractAddress.forwardedBridgeBurn(chainId, abi.encode(address(0), bytes("")));
    }

    // Test forwardedBridgeMint reverts for non-asset-handler
    function test_RevertWhen_forwardedBridgeMintNotChainAssetHandler() public {
        vm.stopPrank();

        address notAssetHandler = makeAddr("notAssetHandler");

        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSignature("chainAssetHandler()"),
            abi.encode(chainAssetHandlerMock)
        );

        bytes memory ctmData = abi.encode(
            bytes32(uint256(1)), // baseTokenAssetId
            makeAddr("admin"),
            0, // protocolVersion
            abi.encode(getDiamondCutData(diamondInit))
        );

        vm.prank(notAssetHandler);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notAssetHandler));
        chainContractAddress.forwardedBridgeMint(chainId, ctmData);
    }

    // Test forwardedBridgeMint reverts when protocol version is outdated
    function test_RevertWhen_forwardedBridgeMintOutdatedProtocolVersion() public {
        vm.stopPrank();

        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSignature("chainAssetHandler()"),
            abi.encode(chainAssetHandlerMock)
        );
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, chainId),
            abi.encode(address(0))
        );

        bytes memory ctmData = abi.encode(
            bytes32(uint256(1)), // baseTokenAssetId
            makeAddr("admin"),
            999, // Wrong protocol version
            abi.encode(getDiamondCutData(diamondInit))
        );

        vm.prank(chainAssetHandlerMock);
        vm.expectRevert(abi.encodeWithSelector(OutdatedProtocolVersion.selector, 0, 999));
        chainContractAddress.forwardedBridgeMint(chainId, ctmData);
    }

    // Test onlyBridgehub modifier in createNewChain
    function test_RevertWhen_createNewChainNotBridgehub() public {
        vm.stopPrank();

        address notBridgehub = makeAddr("notBridgehub");

        vm.prank(notBridgehub);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notBridgehub));
        chainContractAddress.createNewChain({
            _chainId: chainId + 1,
            _baseTokenAssetId: bytes32(uint256(1)),
            _admin: makeAddr("admin"),
            _initData: bytes(""),
            _factoryDeps: new bytes[](0)
        });
    }

    // Test forwardedBridgeConfirmTransferResult (empty function)
    function test_forwardedBridgeConfirmTransferResult() public {
        // This function is empty, so just call it to increase coverage
        chainContractAddress.forwardedBridgeConfirmTransferResult(
            chainId,
            TxStatus.Success,
            bytes32(0),
            makeAddr("sender"),
            bytes("")
        );

        // Also test with failure status
        chainContractAddress.forwardedBridgeConfirmTransferResult(
            chainId,
            TxStatus.Failure,
            bytes32(uint256(1)),
            makeAddr("sender2"),
            bytes("some data")
        );
    }
}
