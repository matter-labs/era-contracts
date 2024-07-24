// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {MailboxTest} from "./_Mailbox_Shared.t.sol";
import {IL1SharedBridge} from "contracts/bridge/interfaces/IL1SharedBridge.sol";
import {DummySharedBridge} from "contracts/dev-contracts/test/DummySharedBridge.sol";

contract MailboxTransferEthToSharedBridge is MailboxTest {
    address baseTokenBridgeAddress;
    DummySharedBridge l1SharedBridge;

    function setUp() public virtual {
        setupDiamondProxy();

        l1SharedBridge = new DummySharedBridge(keccak256("dummyDepositHash"));
        baseTokenBridgeAddress = address(l1SharedBridge);

        utilsFacet.util_setChainId(eraChainId);
        utilsFacet.util_setBaseTokenBridge(baseTokenBridgeAddress);
    }

    modifier useBaseTokenBridge() {
        vm.startPrank(baseTokenBridgeAddress);
        _;
        vm.stopPrank();
    }

    function test_success_transfer(uint256 randomAmount) public useBaseTokenBridge {
        vm.deal(diamondProxy, randomAmount);

        assertEq(address(l1SharedBridge).balance, 0);
        assertEq(address(diamondProxy).balance, randomAmount);
        mailboxFacet.transferEthToSharedBridge();
        assertEq(address(l1SharedBridge).balance, randomAmount);
        assertEq(address(diamondProxy).balance, 0);
    }

    function test_RevertWhen_wrongCaller() public {
        vm.expectRevert("Hyperchain: Only base token bridge can call this function");
        vm.prank(sender);
        mailboxFacet.transferEthToSharedBridge();
    }

    function test_RevertWhen_hyperchainIsNotEra(uint256 randomChainId) public useBaseTokenBridge {
        vm.assume(eraChainId != randomChainId);
        utilsFacet.util_setChainId(randomChainId);

        vm.expectRevert("Mailbox: transferEthToSharedBridge only available for Era on mailbox");
        mailboxFacet.transferEthToSharedBridge();
    }
}
