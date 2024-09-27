// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehub.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK} from "contracts/common/Config.sol";
import {L2CanonicalTransaction, L2Message} from "contracts/common/Messaging.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {AddressesAlreadyGenerated} from "test/foundry/L1TestsErrors.sol";

contract DeploymentTests is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    uint256 constant TEST_USERS_COUNT = 10;
    address[] public users;
    address[] public l2ContractAddresses;

    // generate MAX_USERS addresses and append it to users array
    function _generateUserAddresses() internal {
        if (users.length != 0) {
            revert AddressesAlreadyGenerated();
        }

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
        // _deployZKChain(ETH_TOKEN_ADDRESS);
        // _deployZKChain(ETH_TOKEN_ADDRESS);
        // _deployZKChain(tokens[0]);
        // _deployZKChain(tokens[0]);
        // _deployZKChain(tokens[1]);
        // _deployZKChain(tokens[1]);

        for (uint256 i = 0; i < zkChainIds.length; i++) {
            address contractAddress = makeAddr(string(abi.encode("contract", i)));
            l2ContractAddresses.push(contractAddress);

            _addL2ChainContract(zkChainIds[i], contractAddress);
        }
    }

    function setUp() public {
        prepare();
    }

    // Check whether the sum of ETH deposits from tests, updated on each deposit and withdrawal,
    // equals the balance of L1Shared bridge.
    function test_initialDeployment() public {
        uint256 chainId = zkChainIds[0];
        IBridgehub bridgehub = IBridgehub(l1Script.getBridgehubProxyAddress());
        address newChainAddress = bridgehub.getZKChain(chainId);
        address admin = IZKChain(bridgehub.getZKChain(chainId)).getAdmin();
        IChainTypeManager ctm = IChainTypeManager(bridgehub.chainTypeManager(chainId));

        assertNotEq(admin, address(0));
        assertNotEq(newChainAddress, address(0));

        address[] memory chainAddresses = bridgehub.getAllZKChains();
        assertEq(chainAddresses.length, 1);
        assertEq(chainAddresses[0], newChainAddress);

        uint256[] memory chainIds = bridgehub.getAllZKChainChainIDs();
        assertEq(chainIds.length, 1);
        assertEq(chainIds[0], chainId);

        uint256 protocolVersion = ctm.getProtocolVersion(chainId);
        assertEq(protocolVersion, 0);
    }

    function test_bridgehubSetter() public {
        IBridgehub bridgehub = IBridgehub(l1Script.getBridgehubProxyAddress());
        uint256 chainId = zkChainIds[0];
        IChainTypeManager chainTypeManager = IChainTypeManager(bridgehub.chainTypeManager(chainId));
        uint256 randomChainId = 123456;

        vm.mockCall(
            address(chainTypeManager),
            abi.encodeWithSelector(IChainTypeManager.getZKChainLegacy.selector, randomChainId),
            abi.encode(address(0x01))
        );
        vm.store(address(bridgehub), keccak256(abi.encode(randomChainId, 205)), bytes32(uint256(uint160(1))));
        vm.store(
            address(bridgehub),
            keccak256(abi.encode(randomChainId, 204)),
            bytes32(uint256(uint160(address(chainTypeManager))))
        );
        bridgehub.setLegacyBaseTokenAssetId(randomChainId);
        bridgehub.setLegacyChainAddress(randomChainId);
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
