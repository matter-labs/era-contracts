// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L1Erc20BridgeTest} from "./_L1Erc20Bridge_Shared.t.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";

contract GettersTest is L1Erc20BridgeTest {
    using stdStorage for StdStorage;

    function test_l2TokenAddress() public {
        address daiOnEthereum = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        address daiOnEra = 0x4B9eb6c0b6ea15176BBF62841C6B2A8a398cb656;

        stdstore.target(address(bridge)).sig("l2Bridge()").checked_write(
            address(0x11f943b2c77b743AB90f4A0Ae7d5A4e7FCA3E102)
        );

        stdstore.target(address(bridge)).sig("l2TokenBeacon()").checked_write(
            address(0x1Eb710030273e529A6aD7E1e14D4e601765Ba3c6)
        );

        stdstore.target(address(bridge)).sig("l2TokenProxyBytecodeHash()").checked_write(
            bytes32(0x01000121a363b3fbec270986067c1b553bf540c30a6f186f45313133ff1a1019)
        );

        address token = bridge.l2TokenAddress(daiOnEthereum);
        assertEq(token, daiOnEra);
    }
}
