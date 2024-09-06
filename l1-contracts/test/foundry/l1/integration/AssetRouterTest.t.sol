// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/console.sol";

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
import {HyperchainDeployer} from "./_SharedHyperchainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {BASE_TOKEN_VIRTUAL_ADDRESS} from "contracts/common/Config.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK} from "contracts/common/Config.sol";
import {L2CanonicalTransaction, L2Message} from "contracts/common/Messaging.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {IStateTransitionManager} from "contracts/state-transition/IStateTransitionManager.sol";
import {IL1AssetRouterCombined} from "contracts/bridge/asset-router/IL1AssetRouterCombined.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {IL1Nullifier, FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {BridgeHelper} from "contracts/bridge/BridgeHelper.sol";

contract DeploymentTests is L1ContractDeployer, HyperchainDeployer, TokenDeployer, L2TxMocker {
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
        // _deployHyperchain(BASE_TOKEN_VIRTUAL_ADDRESS);
        // _deployHyperchain(BASE_TOKEN_VIRTUAL_ADDRESS);
        // _deployHyperchain(tokens[0]);
        // _deployHyperchain(tokens[0]);
        // _deployHyperchain(tokens[1]);
        // _deployHyperchain(tokens[1]);

        for (uint256 i = 0; i < hyperchainIds.length; i++) {
            address contractAddress = makeAddr(string(abi.encode("contract", i)));
            l2ContractAddresses.push(contractAddress);

            _addL2ChainContract(hyperchainIds[i], contractAddress);
        }
    }

    function setUp() public {
        prepare();
    }

    // Check whether the sum of ETH deposits from tests, updated on each deposit and withdrawal,
    // equals the balance of L1Shared bridge.
    function test_DepositToL1() public {
        vm.mockCall(
            address(bridgeHub),
            abi.encodeWithSelector(IBridgehub.proveL2MessageInclusion.selector),
            abi.encode(true)
        );
        uint256 chainId = eraHyperchainId;
        bytes32 assetId = DataEncoding.encodeNTVAssetId(chainId, address(1));
        bytes memory transferData = DataEncoding.encodeBridgeMintData({
            _prevMsgSender: BASE_TOKEN_VIRTUAL_ADDRESS,
            _l2Receiver: BASE_TOKEN_VIRTUAL_ADDRESS,
            _l1Token: BASE_TOKEN_VIRTUAL_ADDRESS,
            _amount: 100,
            _erc20Metadata: BridgeHelper.getERC20Getters(BASE_TOKEN_VIRTUAL_ADDRESS, BASE_TOKEN_VIRTUAL_ADDRESS)
        });
        l1Nullifier.finalizeDeposit(
            FinalizeL1DepositParams({
                chainId: chainId,
                l2BatchNumber: 1,
                l2MessageIndex: 1,
                l2Sender: L2_ASSET_ROUTER_ADDR,
                l2TxNumberInBatch: 1,
                message: abi.encodePacked(IL1AssetRouter.finalizeDeposit.selector, chainId, assetId, transferData),
                merkleProof: new bytes32[](0)
            })
        );
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
