// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1InteropHandler, IL1AssetTrackerTransient} from "contracts/interop/L1InteropHandler.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {L2Message, MessageInclusionProof} from "contracts/common/Messaging.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract L1InteropHandlerPauseTest is Test {
    L1InteropHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal messageRoot = makeAddr("messageRoot");
    address internal assetRouter = makeAddr("assetRouter");
    address internal assetTracker = makeAddr("assetTracker");
    address internal proxyAdmin = makeAddr("proxyAdmin");

    function setUp() public {
        L1InteropHandler implementation = new L1InteropHandler(
            IMessageRootBase(messageRoot),
            assetRouter,
            IL1AssetTrackerTransient(assetTracker)
        );
        handler = L1InteropHandler(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    proxyAdmin,
                    abi.encodeCall(L1InteropHandler.initialize, (owner))
                )
            )
        );
    }

    function _dummyProof() internal pure returns (MessageInclusionProof memory) {
        return
            MessageInclusionProof({
                chainId: 1,
                l1BatchNumber: 1,
                l2MessageIndex: 0,
                message: L2Message({txNumberInBatch: 0, sender: address(0), data: hex""}),
                proof: new bytes32[](0)
            });
    }

    function test_initialize_SetsOwnerAndChainId() public view {
        assertEq(handler.owner(), owner);
        assertEq(handler.L1_CHAIN_ID(), block.chainid);
    }

    function test_pause_Success() public {
        vm.prank(owner);
        handler.pause();
        assertTrue(handler.paused());
    }

    function test_pause_RevertWhen_NotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        handler.pause();
    }

    function test_executeBundle_RevertWhen_Paused() public {
        vm.prank(owner);
        handler.pause();

        vm.expectRevert("Pausable: paused");
        handler.executeBundle(hex"", _dummyProof());
    }

    function test_unpause_RestoresExecution() public {
        vm.prank(owner);
        handler.pause();
        vm.prank(owner);
        handler.unpause();
        assertFalse(handler.paused());

        // Execution proceeds past the pause gate (and reverts later on the empty bundle).
        vm.expectRevert();
        handler.executeBundle(hex"", _dummyProof());
    }

    function test_unpause_RevertWhen_NotOwner() public {
        vm.prank(owner);
        handler.pause();

        vm.expectRevert("Ownable: caller is not the owner");
        handler.unpause();
    }
}
