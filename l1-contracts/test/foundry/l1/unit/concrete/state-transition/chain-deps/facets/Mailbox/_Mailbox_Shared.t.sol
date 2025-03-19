// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {TestnetVerifier} from "contracts/state-transition/verifiers/TestnetVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";

contract MailboxTest is Test {
    IMailbox internal mailboxFacet;
    UtilsFacet internal utilsFacet;
    IGetters internal gettersFacet;
    address sender;
    uint256 constant eraChainId = 9;
    address internal testnetVerifier = address(new TestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));
    address diamondProxy;
    address bridgehub;

    function deployDiamondProxy() internal returns (address proxy) {
        sender = makeAddr("sender");
        bridgehub = makeAddr("bridgehub");
        vm.deal(sender, 100 ether);

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](3);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(new MailboxFacet(eraChainId, block.chainid)),
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

        proxy = Utils.makeDiamondProxy(facetCuts, testnetVerifier);
        utilsFacet = UtilsFacet(proxy);
        utilsFacet.util_setBridgehub(bridgehub);
    }

    function setupDiamondProxy() public {
        address diamondProxy = deployDiamondProxy();

        mailboxFacet = IMailbox(diamondProxy);
        utilsFacet = UtilsFacet(diamondProxy);
        gettersFacet = IGetters(diamondProxy);
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
