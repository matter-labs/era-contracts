// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {UtilsCallMockerTest} from "foundry-test/l1/unit/concrete/Utils/UtilsCallMocker.t.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IL1ChainAssetHandler} from "contracts/core/chain-asset-handler/IL1ChainAssetHandler.sol";
import {L1ChainAssetHandler} from "contracts/core/chain-asset-handler/L1ChainAssetHandler.sol";
import {IEIP7702Checker} from "contracts/state-transition/chain-interfaces/IEIP7702Checker.sol";

contract MailboxTest is UtilsCallMockerTest {
    IMailbox internal mailboxFacet;
    UtilsFacet internal utilsFacet;
    IGetters internal gettersFacet;
    address sender;
    uint256 constant eraChainId = 9;
    address internal testnetVerifier = address(new EraTestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));
    address diamondProxy;
    address bridgehub;
    address chainAssetHandler;
    address interopCenter;
    IEIP7702Checker eip7702Checker;
    L1ChainAssetHandler realChainAssetHandler;

    function setupEcosystem() internal {
        sender = makeAddr("sender");
        bridgehub = makeAddr("bridgehub");
        chainAssetHandler = makeAddr("chainAssetHandler");
        interopCenter = makeAddr("interopCenter");
        vm.deal(sender, 100 ether);

        eip7702Checker = IEIP7702Checker(Utils.deployEIP7702Checker());
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(new uint256[](0))
        );

        // Deploy a real L1ChainAssetHandler for settlement layer validation (avoiding mocks).
        realChainAssetHandler = new L1ChainAssetHandler(
            address(this), // owner
            bridgehub
        );

        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(realChainAssetHandler)
        );
        vm.mockCall(
            address(chainAssetHandler),
            abi.encodeWithSelector(IChainAssetHandlerBase.migrationNumber.selector),
            abi.encode(1)
        );
        vm.mockCall(
            address(chainAssetHandler),
            abi.encodeWithSelector(IL1ChainAssetHandler.isMigrationInProgress.selector),
            abi.encode(false)
        );
        // Mock isValidSettlementLayer to always return true for any settlement layer validation
        vm.mockCall(
            address(chainAssetHandler),
            abi.encodeWithSelector(IL1ChainAssetHandler.isValidSettlementLayer.selector),
            abi.encode(true)
        );
    }

    /// @notice Deploys diamond proxy
    /// @dev Assumes that `setupEcosystem` has been called to set up necessary ecosystem dependencies and mocks.
    function deployDiamondProxy() internal returns (address proxy) {
        // Re-apply diamond init mocks each time, since tests may override assetRouter etc.
        mockDiamondInitInteropCenterCallsWithAddress(bridgehub, address(0), bytes32(0));

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](3);
        facetCuts[0] = Diamond.FacetCut({
            facet: address(
                new MailboxFacet(eraChainId, block.chainid, address(chainAssetHandler), eip7702Checker, false)
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
        facetCuts[2] = Diamond.FacetCut({
            facet: address(new GettersFacet()),
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: Utils.getGettersSelectors()
        });

        mockDiamondInitInteropCenterCallsWithAddress(bridgehub, address(0), bytes32(0));
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(chainAssetHandler)
        );
        vm.mockCall(
            address(chainAssetHandler),
            abi.encodeWithSelector(IChainAssetHandlerBase.migrationNumber.selector),
            abi.encode(1)
        );
        vm.mockCall(
            address(chainAssetHandler),
            abi.encodeWithSelector(IL1ChainAssetHandler.isMigrationInProgress.selector),
            abi.encode(false)
        );
        mockChainTypeManagerVerifier(testnetVerifier);
        proxy = Utils.makeDiamondProxy(facetCuts, bridgehub);
        utilsFacet = UtilsFacet(proxy);
        utilsFacet.util_setBridgehub(bridgehub);
    }

    function setupDiamondProxy() public {
        setupEcosystem();
        address diamondProxy = deployDiamondProxy();

        mailboxFacet = IMailbox(diamondProxy);
        utilsFacet = UtilsFacet(diamondProxy);
        gettersFacet = IGetters(diamondProxy);

        // utilsFacet.util_setBridgehub(bridgehub);
        // utilsFacet.util_setInteropCenter(interopCenter);
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
