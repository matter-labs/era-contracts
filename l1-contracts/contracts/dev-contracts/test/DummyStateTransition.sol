// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {MailboxFacet} from "../../state-transition/chain-deps/facets/Mailbox.sol";

contract DummyStateTransition is MailboxFacet{

    constructor(address bridgeHubAddress) {
        s.bridgehub = bridgeHubAddress;
    }

}