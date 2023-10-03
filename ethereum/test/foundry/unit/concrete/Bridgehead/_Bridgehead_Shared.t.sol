// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {Bridgehead} from "../../../../../cache/solpp-generated-contracts/bridgehead/Bridgehead.sol";
import {IAllowList} from "../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";

contract BridgeheadTest is Test {
    Bridgehead internal bridgehead;
    address internal constant GOVERNOR = address(0x101010101010101010101);
    address internal constant NON_GOVERNOR = address(0x202020202020202020202);

    constructor() {
        address governor = GOVERNOR;
        address chainImplementation = makeAddr("chainImplementation");
        address chainProxyAdmin = makeAddr("chainProxyAdmin");
        IAllowList allowList = IAllowList(GOVERNOR);
        uint256 priorityTxMaxGasLimit = 10000;

        bridgehead = new Bridgehead();
        bridgehead.initialize(governor, chainImplementation, chainProxyAdmin, allowList, priorityTxMaxGasLimit);
    }
}
