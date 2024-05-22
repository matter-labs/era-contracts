// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {MailboxTest} from "./_Mailbox_Shared.t.sol";
import {IL1SharedBridge} from "contracts/bridge/interfaces/IL1SharedBridge.sol";

contract MailboxTransferEthToSharedBridge is MailboxTest {
    address baseTokenBridge;

    function setUp() public virtual {
        prepare();
        
        baseTokenBridge = makeAddr("bridge");
        vm.deal(diamondProxy, 1 ether);
        utilsFacet.util_setChainId(eraChainId);
        utilsFacet.util_setBaseTokenBridge(baseTokenBridge);
    }

    modifier useBaseTokenBridge() {
        vm.startPrank(baseTokenBridge);
        _;
        vm.stopPrank();
    }

    function test_success_transfer() public useBaseTokenBridge {
        vm.mockCall(baseTokenBridge, abi.encodeWithSelector(IL1SharedBridge.receiveEth.selector, eraChainId), "");

        mailboxFacet.transferEthToSharedBridge();
    }

    function test_RevertWhen_wrongCaller() public {
        vm.expectRevert("Hyperchain: Only base token bridge can call this function");
        vm.prank(sender);
        mailboxFacet.transferEthToSharedBridge();
    }

    function test_RevertWhen_hyperchainIsNotEra() public useBaseTokenBridge {
        utilsFacet.util_setChainId(eraChainId + 1);

        vm.expectRevert("Mailbox: transferEthToSharedBridge only available for Era on mailbox");
        mailboxFacet.transferEthToSharedBridge();
    }
}
