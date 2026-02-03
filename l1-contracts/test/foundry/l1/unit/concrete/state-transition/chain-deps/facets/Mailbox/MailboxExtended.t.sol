// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IMailboxImpl} from "contracts/state-transition/chain-interfaces/IMailboxImpl.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {UtilsCallMockerTest} from "foundry-test/l1/unit/concrete/Utils/UtilsCallMocker.t.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IChainAssetHandler} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IL1ChainAssetHandler} from "contracts/core/chain-asset-handler/IL1ChainAssetHandler.sol";
import {IEIP7702Checker} from "contracts/state-transition/chain-interfaces/IEIP7702Checker.sol";
import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";
import {L2Message, L2Log} from "contracts/common/Messaging.sol";
import {InvalidChainId, ZeroAddress, AddressNotZero} from "contracts/common/L1ContractErrors.sol";
import {DepositsPaused, LocalRootIsZero, LocalRootMustBeZero, NotHyperchain, NotL1, NotSettlementLayer} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {DepthMoreThanOneForRecursiveMerkleProof, OnlyGateway} from "contracts/core/bridgehub/L1BridgehubErrors.sol";
import {PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET, PAUSE_DEPOSITS_TIME_WINDOW_START_MAINNET} from "contracts/common/Config.sol";

contract MailboxOnGatewayTest is UtilsCallMockerTest {
    IMailbox internal mailboxFacet;
    UtilsFacet internal utilsFacet;
    address bridgehub;
    address chainAssetHandler;
    uint256 constant eraChainId = 9;
    uint256 constant l1ChainId = 1;
    uint256 constant gatewayChainId = 505; // Different from L1

    function setUp() public {
        // Set up on a non-L1 chain (Gateway)
        vm.chainId(gatewayChainId);

        bridgehub = makeAddr("bridgehub");
        chainAssetHandler = makeAddr("chainAssetHandler");

        // Deploy without EIP7702Checker since we're not on L1
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](2);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(
                new MailboxFacet(eraChainId, l1ChainId, address(chainAssetHandler), IEIP7702Checker(address(0)), false)
            ),
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

        mockDiamondInitInteropCenterCallsWithAddress(bridgehub, address(0), bytes32(0));
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(chainAssetHandler)
        );
        vm.mockCall(
            address(chainAssetHandler),
            abi.encodeWithSelector(IChainAssetHandler.migrationNumber.selector),
            abi.encode(1)
        );

        address testnetVerifier = address(new EraTestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));
        mockChainTypeManagerVerifier(testnetVerifier);
        address diamondProxy = Utils.makeDiamondProxy(facetCuts, testnetVerifier, bridgehub);

        mailboxFacet = IMailbox(diamondProxy);
        utilsFacet = UtilsFacet(diamondProxy);

        utilsFacet.util_setBridgehub(bridgehub);
        utilsFacet.util_setChainId(eraChainId);
    }

    function test_onlyL1Modifier_RevertsOnGateway() public {
        // Any function with onlyL1 modifier should revert when called on Gateway
        // requestL2ServiceTransaction uses onlyL1 modifier
        // Mock the chainRegistrationSender call to return the test caller
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehubBase.chainRegistrationSender.selector),
            abi.encode(address(this))
        );

        vm.expectRevert(abi.encodeWithSelector(NotL1.selector, gatewayChainId));
        IMailboxImpl(address(mailboxFacet)).requestL2ServiceTransaction(address(0x123), bytes(""));
    }
}

contract MailboxConstructorTest is Test {
    function test_Constructor_RevertWhen_EIP7702CheckerIsZeroOnL1() public {
        // On L1, EIP7702Checker cannot be zero
        vm.chainId(1); // L1 chain ID
        vm.expectRevert(ZeroAddress.selector);
        new MailboxFacet(9, 1, address(0x123), IEIP7702Checker(address(0)), false);
    }

    function test_Constructor_RevertWhen_EIP7702CheckerIsNotZeroOnGateway() public {
        // On Gateway, EIP7702Checker must be zero
        vm.chainId(505); // Gateway chain ID
        IEIP7702Checker eip7702Checker = IEIP7702Checker(makeAddr("eip7702Checker"));
        vm.expectRevert(AddressNotZero.selector);
        new MailboxFacet(9, 1, address(0x123), eip7702Checker, false);
    }

    function test_Constructor_Success_OnL1WithChecker() public {
        vm.chainId(1); // L1 chain ID
        IEIP7702Checker eip7702Checker = IEIP7702Checker(makeAddr("eip7702Checker"));
        MailboxFacet mailbox = new MailboxFacet(9, 1, address(0x123), eip7702Checker, false);
        assertNotEq(address(mailbox), address(0));
    }

    function test_Constructor_Success_OnGatewayWithoutChecker() public {
        vm.chainId(505); // Gateway chain ID
        MailboxFacet mailbox = new MailboxFacet(9, 1, address(0x123), IEIP7702Checker(address(0)), false);
        assertNotEq(address(mailbox), address(0));
    }
}
