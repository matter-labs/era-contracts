// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

/* solhint-disable max-line-length */

import {BridgeheadTest} from "../_Bridgehead_Shared.t.sol";
import {IAllowList} from "../../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";
import {IBridgeheadChain} from "../../../../../../cache/solpp-generated-contracts/bridgehead/chain-interfaces/IBridgeheadChain.sol";
import {IProofForBridgehead} from "../../../../../../cache/solpp-generated-contracts/proof-system/proof-system-interfaces/IProofSystem.sol";

/* solhint-enable max-line-length */

contract BridgeheadMailboxTest is BridgeheadTest {
    uint256 internal chainId;
    address internal chainProofSystem;
    address internal chainGovernor;
    IAllowList internal chainAllowList;

    constructor() {
        chainId = 987654321;
        chainProofSystem = makeAddr("chainProofSystem");
        chainGovernor = makeAddr("chainGovernor");
        chainAllowList = IAllowList(makeAddr("chainAllowList"));

        vm.mockCall(
            bridgehead.getChainImplementation(),
            abi.encodeWithSelector(IBridgeheadChain.initialize.selector),
            ""
        );
        vm.mockCall(chainProofSystem, abi.encodeWithSelector(IProofForBridgehead.newChain.selector), "");

        vm.startPrank(GOVERNOR);
        bridgehead.newProofSystem(chainProofSystem);
        bridgehead.newChain(chainId, chainProofSystem, chainGovernor, chainAllowList, getDiamondCutData());
    }
}
