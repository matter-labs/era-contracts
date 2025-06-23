// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";

import {IBridgehub, L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehub.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK, ETH_TOKEN_ADDRESS, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2CanonicalTransaction, L2Message} from "contracts/common/Messaging.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {AddressesAlreadyGenerated} from "test/foundry/L1TestsErrors.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {IncorrectBridgeHubAddress} from "contracts/common/L1ContractErrors.sol";
import {MessageRoot} from "contracts/bridgehub/MessageRoot.sol";
import {ConfigSemaphore} from "./utils/_ConfigSemaphore.sol";
import {IAssetTracker} from "contracts/bridge/asset-tracker/IAssetTracker.sol";
import {CHAIN_REGISTRATION_SENDER_ENCODING_VERSION} from "contracts/bridgehub/ChainRegistrationSender.sol";

contract DeploymentTests is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker, ConfigSemaphore {
    using stdStorage for StdStorage;
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
        takeConfigLock(); // Prevents race condition with configs
        _generateUserAddresses();

        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);

        _deployEra();
        _deployZKChain(ETH_TOKEN_ADDRESS);
        _deployZKChain(ETH_TOKEN_ADDRESS);

        releaseConfigLock();

        for (uint256 i = 0; i < zkChainIds.length; i++) {
            address contractAddress = makeAddr(string(abi.encode("contract", i)));
            l2ContractAddresses.push(contractAddress);

            _addL2ChainContract(zkChainIds[i], contractAddress);
        }
    }

    function setUp() public {
        prepare();
    }

    function test_chainRegistrationSender() public {
        address owner = Ownable(address(addresses.bridgehub)).owner();
        stdstore
            .target(address(addresses.chainRegistrationSender))
            .sig(addresses.chainRegistrationSender.chainRegisteredOnChain.selector)
            .with_key(zkChainIds[0])
            .with_key(zkChainIds[1])
            .checked_write(false);

        vm.startBroadcast(owner);
        addresses.chainRegistrationSender.registerChain(zkChainIds[0], zkChainIds[1]);
        vm.stopBroadcast();
    }

    // deposits ERC20 token to the ZK chain where base token is ETH
    // this function use requestL2TransactionTwoBridges function from shared bridge.
    // tokenAddress should be any ERC20 token, excluding ETH
    function chainRegistrationSenderDeposit(uint256 l2Value, address tokenAddress) private {
        TestnetERC20Token currentToken = TestnetERC20Token(tokenAddress);
        uint256 currentChainId = zkChainIds[0];
        address currentUser = users[0];

        uint256 gasPrice = 10000000;
        vm.txGasPrice(gasPrice);

        uint256 l2GasLimit = 1000000;
        MailboxFacet chainMailBox = MailboxFacet(getZKChainAddress(currentChainId));

        uint256 minRequiredGas = chainMailBox.l2TransactionBaseCost(
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );

        uint256 mintValue = minRequiredGas;
        vm.deal(currentUser, mintValue);

        // currentToken.mint(currentUser, l2Value);
        // currentToken.approve(address(addresses.sharedBridge), l2Value);

        bytes memory secondBridgeCallData = bytes.concat(
            CHAIN_REGISTRATION_SENDER_ENCODING_VERSION,
            abi.encode(currentChainId)
        );
        L2TransactionRequestTwoBridgesOuter memory requestTx = _createL2TransactionRequestTwoBridges({
            _chainId: currentChainId,
            _mintValue: mintValue,
            _secondBridgeValue: 0,
            _secondBridgeAddress: address(addresses.chainRegistrationSender),
            _l2Value: 0,
            _l2GasLimit: l2GasLimit,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _secondBridgeCalldata: secondBridgeCallData
        });

        vm.recordLogs();
        bytes32 resultantHash = addresses.bridgehub.requestL2TransactionTwoBridges{value: mintValue}(requestTx);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // NewPriorityRequest memory request = _getNewPriorityQueueFromLogs(logs);

        // assertNotEq(resultantHash, bytes32(0));
        // assertNotEq(request.txHash, bytes32(0));
        // _handleRequestByMockL2Contract(request, RequestType.TWO_BRIDGES);

        // depositsUsers[currentUser][ETH_TOKEN_ADDRESS] += mintValue;
        // depositsBridge[currentChainAddress][ETH_TOKEN_ADDRESS] += mintValue;
        // tokenSumDeposit[ETH_TOKEN_ADDRESS] += mintValue;

        // depositsUsers[currentUser][currentTokenAddress] += l2Value;
        // depositsBridge[currentChainAddress][currentTokenAddress] += l2Value;
        // tokenSumDeposit[currentTokenAddress] += l2Value;
        // l2ValuesSum[currentTokenAddress] += l2Value;
    }

    function test_chainRegistrationSenderDeposit() public {
        stdstore
            .target(address(addresses.chainRegistrationSender))
            .sig(addresses.chainRegistrationSender.chainRegisteredOnChain.selector)
            .with_key(zkChainIds[0])
            .with_key(zkChainIds[1])
            .checked_write(false);
        chainRegistrationSenderDeposit(1000000, ETH_TOKEN_ADDRESS);
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
