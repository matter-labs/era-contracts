// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {BridgeheadChainTest} from "./_BridgeheadChain_Shared.t.sol";
import {IAllowList} from "../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";
import {BridgeheadChain} from "../../../../../cache/solpp-generated-contracts/bridgehead/BridgeheadChain.sol";

contract InitializeTest is BridgeheadChainTest {
    function setUp() public {
        bridgeheadChain = new BridgeheadChain();

        chainId = 838383838383;
        proofSystem = makeAddr("proofSystem");
        governor = makeAddr("governor");
        allowList = IAllowList(makeAddr("owner"));
        priorityTxMaxGasLimit = 99999;
    }

    function test_RevertWhen_GovernorIsZeroAddress() public {
        governor = address(0);

        vm.expectRevert(bytes.concat("vy"));
        bridgeheadChain.initialize(chainId, proofSystem, governor, allowList, priorityTxMaxGasLimit);
    }

    function test_InitializeSuccessfully() public {
        bridgeheadChain.initialize(chainId, proofSystem, governor, allowList, priorityTxMaxGasLimit);

        assertEq(bridgeheadChain.getChainId(), chainId);
        assertEq(bridgeheadChain.getProofSystem(), proofSystem);
        assertEq(bridgeheadChain.getGovernor(), governor);
        assertEq(address(bridgeheadChain.getAllowList()), address(allowList));
        assertEq(bridgeheadChain.getPriorityTxMaxGasLimit(), priorityTxMaxGasLimit);
    }
}
