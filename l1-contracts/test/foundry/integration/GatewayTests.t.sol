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
import {ETH_TOKEN_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER} from "contracts/common/Config.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK} from "contracts/common/Config.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {L2Message} from "contracts/common/Messaging.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {IL1AssetRouter} from "contracts/bridge/interfaces/IL1AssetRouter.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {IStateTransitionManager} from "contracts/state-transition/IStateTransitionManager.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {TxStatus} from "contracts/common/Messaging.sol";

contract GatewayTests is L1ContractDeployer, HyperchainDeployer, TokenDeployer, L2TxMocker, GatewayDeployer {
    uint256 constant TEST_USERS_COUNT = 10;
    address[] public users;
    address[] public l2ContractAddresses;

    uint256 migratingChainId = 10;
    uint256 gatewayChainId = 11;
    uint256 mintChainId = 12;

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
        vm.deal(Ownable(l1Script.getBridgehubProxyAddress()).owner(), 100000000000000000000000000000000000);
        vm.deal(l1Script.getOwnerAddress(), 100000000000000000000000000000000000);
        IZkSyncHyperchain chain = IZkSyncHyperchain(
            IBridgehub(l1Script.getBridgehubProxyAddress()).getHyperchain(migratingChainId)
        );
        IZkSyncHyperchain chain2 = IZkSyncHyperchain(
            IBridgehub(l1Script.getBridgehubProxyAddress()).getHyperchain(gatewayChainId)
        );
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

    function test_l2Registration() public {
        gatewayScript.registerGateway();
        gatewayScript.moveChainToGateway();
        gatewayScript.registerL2Contracts();
    }

    function test_finishMoveChain() public {
        finishMoveChain();
    }

    function test_startMessageToL3() public {
        finishMoveChain();
        IBridgehub bridgehub = IBridgehub(l1Script.getBridgehubProxyAddress());
        uint256 expectedValue = 1000000000000000000000;

        L2TransactionRequestDirect memory request = _createL2TransactionRequestDirect(
            migratingChainId,
            expectedValue,
            0,
            72000000,
            800,
            "0x"
        );
        bridgehub.requestL2TransactionDirect{value: expectedValue}(request);
    }

    function test_forwardToL3OnGateway() public {
        finishMoveChain();

        IBridgehub bridgehub = IBridgehub(l1Script.getBridgehubProxyAddress());
        L2CanonicalTransaction memory tx = L2CanonicalTransaction({
            txType: 255,
            from: uint256(0),
            to: uint256(0),
            gasLimit: 72000000,
            gasPerPubdataByteLimit: 800,
            maxFeePerGas: 1,
            maxPriorityFeePerGas: 0,
            paymaster: 0,
            // Note, that the priority operation id is used as "nonce" for L1->L2 transactions
            nonce: 0,
            value: 0,
            reserved: [uint256(0), 0, 0, 0],
            data: "0x",
            signature: new bytes(0),
            factoryDeps: new uint256[](0),
            paymasterInput: "0x",
            reservedDynamic: "0x"
        });
        vm.chainId(12345);
        vm.startBroadcast(SETTLEMENT_LAYER_RELAY_SENDER);
        bridgehub.forwardTransactionOnGateway(mintChainId, tx, new bytes[](0), bytes32(0), 0);
        vm.stopBroadcast();
    }

    function test_recoverFromFailedChainMigration() public {
        gatewayScript.registerGateway();
        gatewayScript.moveChainToGateway();


        // Setup
        IBridgehub bridgehub = IBridgehub(l1Script.getBridgehubProxyAddress());
        address chainAdmin = IZkSyncHyperchain(bridgehub.getHyperchain(migratingChainId)).getAdmin();
        IL1AssetRouter assetRouter = bridgehub.sharedBridge();
        bytes32 assetId = bridgehub.stmAssetIdFromChainId(migratingChainId);
        bytes32 l2TxHash = keccak256("l2TxHash");
        uint256 l2BatchNumber = 5;
        uint256 l2MessageIndex = 0;
        uint16 l2TxNumberInBatch = 0;
        bytes32[] memory merkleProof = new bytes32[](1);
        TxStatus status = TxStatus.Failure;
        bytes memory transferData = abi.encode(1, address(0));
        bytes32 txDataHash = keccak256(bytes.concat(bytes1(0x01), abi.encode(chainAdmin, assetId, transferData)));

        // Mock Call for Msg Inclusion
        vm.mockCall(
            address(bridgehub), 
            abi.encodeWithSelector(
                IBridgehub.proveL1ToL2TransactionStatus.selector,
                migratingChainId,
                l2TxHash,
                l2BatchNumber,
                l2MessageIndex,
                l2TxNumberInBatch,
                merkleProof,
                status
            ),
            abi.encode(true)
        );

        // Set Deposit Hapened
        vm.startBroadcast(address(bridgeHub));
        assetRouter.bridgehubConfirmL2Transaction({
            _chainId: migratingChainId,
            _txDataHash: txDataHash,
            _txHash: l2TxHash
        });
        vm.stopBroadcast();

        vm.startBroadcast();
        assetRouter.bridgeRecoverFailedTransfer({
            _chainId: migratingChainId,
            _depositSender: chainAdmin,
            _assetId: assetId,
            _assetData: transferData,
            _l2TxHash: l2TxHash,
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: l2TxNumberInBatch,
            _merkleProof: merkleProof
        });
        vm.stopBroadcast();
    }

    function finishMoveChain() public {
        IBridgehub bridgehub = IBridgehub(l1Script.getBridgehubProxyAddress());
        IStateTransitionManager stm = IStateTransitionManager(l1Script.getSTM());
        IZkSyncHyperchain chain = IZkSyncHyperchain(bridgehub.getHyperchain(migratingChainId));
        bytes32 assetId = bridgehub.stmAssetIdFromChainId(migratingChainId);

        bytes memory initialDiamondCut = l1Script.getInitialDiamondCutData();
        bytes memory chainData = abi.encode(AdminFacet(address(chain)).prepareChainCommitment());
        bytes memory stmData = abi.encode(address(1), msg.sender, stm.protocolVersion(), initialDiamondCut);
        bytes memory bridgehubMintData = abi.encode(mintChainId, stmData, chainData);
        vm.startBroadcast(address(bridgehub.sharedBridge()));
        bridgehub.bridgeMint(gatewayChainId, assetId, bridgehubMintData);
        vm.stopBroadcast();
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
