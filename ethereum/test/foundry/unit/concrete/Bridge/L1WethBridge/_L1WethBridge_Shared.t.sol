// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {AllowList} from "../../../../../../cache/solpp-generated-contracts/common/AllowList.sol";
import {L1WethBridge} from "../../../../../../cache/solpp-generated-contracts/bridge/L1WethBridge.sol";
import {WETH9} from "../../../../../../cache/solpp-generated-contracts/dev-contracts/WETH9.sol";
// import {GettersFacet} from "../../../../../../cache/solpp-generated-contracts/state-transition/chain-deps/facets/Getters.sol";
// import {MailboxFacet} from "../../../../../../cache/solpp-generated-contracts/state-transition/chain-deps/facets/Mailbox.sol";
// import {DiamondInit} from "../../../../../../cache/solpp-generated-contracts/state-transition/chain-deps/DiamondInit.sol";
// import {VerifierParams} from "../../../../../../cache/solpp-generated-contracts/state-transition/chain-deps/StateTransitionChainStorage.sol";
// import {Diamond} from "../../../../../../cache/solpp-generated-contracts/common/libraries/Diamond.sol";
// import {DiamondProxy} from "../../../../../../cache/solpp-generated-contracts/common/DiamondProxy.sol";
import {IAllowList} from "../../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";
// import {Utils} from "../../Utils/Utils.sol";
import {IStateTransitionChain} from "../../../../../../cache/solpp-generated-contracts/state-transition/chain-interfaces/IStateTransitionChain.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract L1WethBridgeTest is Test {
    address internal owner;
    address internal randomSigner;
    AllowList internal allowList;
    L1WethBridge internal bridgeProxy;
    WETH9 internal l1Weth;
    bytes4 internal functionSignature = 0x6c0960f9;

    function setUp() public {
        owner = makeAddr("owner");
        randomSigner = makeAddr("randomSigner");

        l1Weth = new WETH9();

        // address[] addresses = Utils.initial_deployment();

        IStateTransitionChain zkSync = IStateTransitionChain(address(diamondProxy));

        L1WethBridge bridge = new L1WethBridge(payable(address(l1Weth)), zkSync, allowList);

        bytes memory garbageBytecode = abi.encodePacked(
            bytes32(0x1111111111111111111111111111111111111111111111111111111111111111)
        );
        address garbageAddress = makeAddr("garbageAddress");

        bytes[] memory factoryDeps = new bytes[](2);
        factoryDeps[0] = garbageBytecode;
        factoryDeps[1] = garbageBytecode;
        bytes memory bridgeInitData = abi.encodeWithSelector(
            bridge.initialize.selector,
            factoryDeps,
            garbageAddress,
            owner,
            1000000000000000000,
            1000000000000000000
        );

        ERC1967Proxy x = new ERC1967Proxy{value: 2000000000000000000}(address(bridge), bridgeInitData);

        bridgeProxy = L1WethBridge(payable(address(x)));

        vm.prank(owner);
        allowList.setAccessMode(address(bridgeProxy), IAllowList.AccessMode.Public);
    }
}
