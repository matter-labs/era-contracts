// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import "forge-std/console.sol";

import {L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehub.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {HyperchainDeployer} from "./_SharedHyperchainDeployer.t.sol";
import {GatewayDeployer} from "./_SharedGatewayDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK} from "contracts/common/Config.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {L2Message} from "contracts/common/Messaging.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";

contract GatewayTests is L1ContractDeployer, HyperchainDeployer, TokenDeployer, L2TxMocker, GatewayDeployer {
    uint256 constant TEST_USERS_COUNT = 10;
    address[] public users;
    address[] public l2ContractAddresses;

    // generate MAX_USERS addresses and append it to users array
    function _generateUserAddresses() internal {
        require(users.length == 0, "Addresses already generated");

        for (uint256 i = 0; i < TEST_USERS_COUNT; i++) {
            address newAddress = makeAddr(string(abi.encode("account", i)));
            users.push(newAddress);
        }
    }

    function prepare() public {
        _generateUserAddresses();

        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);

        _deployEra();
        _deployHyperchain(ETH_TOKEN_ADDRESS);
        acceptPendingAdmin();
        _deployHyperchain(ETH_TOKEN_ADDRESS);
        acceptPendingAdmin();
        // _deployHyperchain(tokens[0]);
        // _deployHyperchain(tokens[0]);
        // _deployHyperchain(tokens[1]);
        // _deployHyperchain(tokens[1]);

        for (uint256 i = 0; i < hyperchainIds.length; i++) {
            address contractAddress = makeAddr(string(abi.encode("contract", i)));
            l2ContractAddresses.push(contractAddress);

            _addL2ChainContract(hyperchainIds[i], contractAddress);
            // _registerL2SharedBridge(hyperchainIds[i], contractAddress);
        }

        _initializeGatewayScript();

        // console.log("KL todo", Ownable(l1Script.getBridgehubProxyAddress()).owner(), l1Script.getBridgehubProxyAddress());
        // vm.deal(Ownable(l1Script.getBridgehubProxyAddress()).owner(), 100000000000000000000000000000000000);
        // vm.deal(l1Script.getOwnerAddress(), 100000000000000000000000000000000000);
        IZkSyncHyperchain chain = IZkSyncHyperchain(IBridgehub(l1Script.getBridgehubProxyAddress()).getHyperchain(10));
        IZkSyncHyperchain chain2 = IZkSyncHyperchain(IBridgehub(l1Script.getBridgehubProxyAddress()).getHyperchain(11));
        vm.deal(chain.getAdmin(), 100000000000000000000000000000000000);
        vm.deal(chain2.getAdmin(), 100000000000000000000000000000000000);

        // console.log("kl todo balance", Ownable(l1Script.getBridgehubProxyAddress()).owner().balance);
        // vm.deal(msg.sender, 100000000000000000000000000000000000);
        // vm.deal(l1Script.getBridgehubProxyAddress(), 100000000000000000000000000000000000);
    }

    function setUp() public {
        prepare();
    }

    //
    function test_registerGateway() public {
        gatewayScript.registerGateway();
    }

    //
    function test_moveChainToGateway() public {
        gatewayScript.registerGateway();
        gatewayScript.moveChainToGateway();
        // require(bridgehub.settlementLayer())
    }

    function test_l2Registration() public {}

    function test_finishMoveChain() public {}

    function test_startMessageToL3() public {}

    function test_forwardToL3OnGateway() public {}

    // add this to be excluded from coverage report
    function test() internal override {}
}
