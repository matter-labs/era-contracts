// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {Utils} from "foundry-test/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/unit/concrete/Utils/UtilsFacet.sol";

import {MailboxFacet} from "solpp/state-transition/chain-deps/facets/Mailbox.sol";
import {Diamond} from "solpp/state-transition/libraries/Diamond.sol";
import {IMailbox} from "solpp/state-transition/chain-interfaces/IMailbox.sol";

contract MailboxTest is Test {
    IMailbox internal mailboxFacet;
    UtilsFacet internal utilsFacet;
    address sender;

    function getMailboxSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IMailbox.bridgehubRequestL2Transaction.selector;
        return selectors;
    }

    function setUp() public virtual {
        sender = makeAddr("sender");
        vm.deal(sender, 100 ether);

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(new MailboxFacet()),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: getMailboxSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(new UtilsFacet()),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getUtilsFacetSelectors()
        });

        address diamondProxy = Utils.makeDiamondProxy(facetCuts);
        mailboxFacet = IMailbox(diamondProxy);
        utilsFacet = UtilsFacet(diamondProxy);
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
