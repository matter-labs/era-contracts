// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {L1SharedBridgeTest} from "./_L1SharedBridge_Shared.t.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L2Message, TxStatus} from "contracts/common/Messaging.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";

/// We are testing all the specified revert and require cases.
contract L1SharedBridgeAdminTest is L1SharedBridgeTest {
    function testAdminCanInitializeChainGovernance() public {
        uint256 randomChainId = 123456;
        address randomL2Bridge = makeAddr("randomL2Bridge");

        vm.prank(admin);
        sharedBridge.initializeChainGovernance(randomChainId, randomL2Bridge);

        assertEq(sharedBridge.l2BridgeAddress(randomChainId), randomL2Bridge);
    }
}
