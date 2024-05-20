// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {Utils} from "foundry-test/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/unit/concrete/Utils/UtilsFacet.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {TestnetVerifier} from "contracts/state-transition/TestnetVerifier.sol";

contract MailboxTest is Test {
    IMailbox internal mailboxFacet;
    UtilsFacet internal utilsFacet;
    IGetters internal gettersFacet;
    address sender;
    uint256 eraChainId = 9;
    address internal testnetVerifier = address(new TestnetVerifier());

    // function getMailboxSelectors() public pure returns (bytes4[] memory) {
    //     bytes4[] memory selectors = new bytes4[](1);
    //     selectors[0] = IMailbox.bridgehubRequestL2Transaction.selector;

    //     return selectors;
    // }

    function setUp() public virtual {
        sender = makeAddr("sender");
        vm.deal(sender, 100 ether);

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](3);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(new MailboxFacet(eraChainId)),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getMailboxSelectors()
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: address(new UtilsFacet()),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getUtilsFacetSelectors()
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: address(new GettersFacet()),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getGettersSelectors()
        });

        address diamondProxy = Utils.makeDiamondProxy(facetCuts, testnetVerifier);
        mailboxFacet = IMailbox(diamondProxy);
        utilsFacet = UtilsFacet(diamondProxy);
        gettersFacet = IGetters(diamondProxy);
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
