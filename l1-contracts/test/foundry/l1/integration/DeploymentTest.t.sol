// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";

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
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IncorrectBridgeHubAddress} from "contracts/common/L1ContractErrors.sol";
import {MessageRoot} from "contracts/bridgehub/MessageRoot.sol";

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
        address newChainAddress = addresses.bridgehub.getZKChain(chainId);
        address admin = IZKChain(addresses.bridgehub.getZKChain(chainId)).getAdmin();

        assertNotEq(admin, address(0));
        assertNotEq(newChainAddress, address(0));

        address[] memory chainAddresses = addresses.bridgehub.getAllZKChains();
        assertEq(chainAddresses.length, 1);
        assertEq(chainAddresses[0], newChainAddress);

        uint256[] memory chainIds = addresses.bridgehub.getAllZKChainChainIDs();
        assertEq(chainIds.length, 1);
        assertEq(chainIds[0], chainId);

        uint256 protocolVersion = addresses.chainTypeManager.getProtocolVersion(chainId);
        assertEq(protocolVersion, 25);
    }

    function test_bridgehubSetter() public {
        uint256 chainId = zkChainIds[0];
        uint256 randomChainId = 123456;

        vm.mockCall(
            address(addresses.chainTypeManager),
            abi.encodeWithSelector(IChainTypeManager.getZKChainLegacy.selector, randomChainId),
            abi.encode(address(0x01))
        );
        vm.store(address(addresses.bridgehub), keccak256(abi.encode(randomChainId, 205)), bytes32(uint256(uint160(1))));
        vm.store(
            address(addresses.bridgehub),
            keccak256(abi.encode(randomChainId, 204)),
            bytes32(uint256(uint160(address(addresses.chainTypeManager))))
        );
        addresses.bridgehub.registerLegacyChain(randomChainId);

        assertEq(addresses.bridgehub.settlementLayer(randomChainId), block.chainid);

        address messageRoot = address(addresses.bridgehub.messageRoot());
        assertTrue(MessageRoot(messageRoot).chainIndex(randomChainId) != 0);
    }

    function test_registerAlreadyDeployedZKChain() public {
        address owner = Ownable(address(addresses.bridgehub)).owner();

        {
            uint256 chainId = currentZKChainId++;
            bytes32 baseTokenAssetId = DataEncoding.encodeNTVAssetId(chainId, ETH_TOKEN_ADDRESS);

            address chain = _deployZkChain(
                chainId,
                baseTokenAssetId,
                owner,
                addresses.chainTypeManager.protocolVersion(),
                addresses.chainTypeManager.storedBatchZero(),
                address(addresses.bridgehub)
            );

            address stmAddr = IZKChain(chain).getChainTypeManager();

            vm.startBroadcast(owner);
            addresses.bridgehub.addChainTypeManager(stmAddr);
            addresses.bridgehub.addTokenAssetId(baseTokenAssetId);
            addresses.bridgehub.registerAlreadyDeployedZKChain(chainId, chain);
            vm.stopBroadcast();

            address bridgehubStmForChain = addresses.bridgehub.chainTypeManager(chainId);
            bytes32 bridgehubBaseAssetIdForChain = addresses.bridgehub.baseTokenAssetId(chainId);
            address bridgehubChainAddressForChain = addresses.bridgehub.getZKChain(chainId);
            address bhAddr = IZKChain(chain).getBridgehub();

            assertEq(bridgehubStmForChain, stmAddr);
            assertEq(bridgehubBaseAssetIdForChain, baseTokenAssetId);
            assertEq(bridgehubChainAddressForChain, chain);
            assertEq(bhAddr, address(addresses.bridgehub));
        }

        {
            uint256 chainId = currentZKChainId++;
            bytes32 baseTokenAssetId = DataEncoding.encodeNTVAssetId(chainId, ETH_TOKEN_ADDRESS);
            address chain = _deployZkChain(
                chainId,
                baseTokenAssetId,
                owner,
                addresses.chainTypeManager.protocolVersion(),
                addresses.chainTypeManager.storedBatchZero(),
                address(addresses.bridgehub.sharedBridge())
            );

            address stmAddr = IZKChain(chain).getChainTypeManager();

            vm.startBroadcast(owner);
            addresses.bridgehub.addTokenAssetId(baseTokenAssetId);
            vm.expectRevert(
                abi.encodeWithSelector(IncorrectBridgeHubAddress.selector, address(addresses.bridgehub.sharedBridge()))
            );
            addresses.bridgehub.registerAlreadyDeployedZKChain(chainId, chain);
            vm.stopBroadcast();
        }
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
