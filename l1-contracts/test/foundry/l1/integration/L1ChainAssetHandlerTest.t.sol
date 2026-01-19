// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {IBridgehubBase, L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {Vm} from "forge-std/Vm.sol";

import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {SimpleExecutor} from "contracts/dev-contracts/SimpleExecutor.sol";

import {IMessageRoot, IMessageVerification} from "contracts/core/message-root/IMessageRoot.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";
import {ETH_TOKEN_ADDRESS, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2Message} from "contracts/common/Messaging.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {IChainAssetHandler} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {NativeTokenVaultBase} from "contracts/bridge/ntv/NativeTokenVaultBase.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {FinalizeL1DepositParams} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ProofData} from "contracts/common/libraries/MessageHashing.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {BridgeHelper} from "contracts/bridge/BridgeHelper.sol";
import {BridgedStandardERC20, NonSequentialVersion} from "contracts/bridge/BridgedStandardERC20.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {IAssetTrackerBase} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";

import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {IL1ChainAssetHandler} from "contracts/core/chain-asset-handler/IL1ChainAssetHandler.sol";
import {IL2ChainAssetHandler} from "contracts/core/chain-asset-handler/IL2ChainAssetHandler.sol";
import {L2ChainAssetHandler} from "contracts/core/chain-asset-handler/L2ChainAssetHandler.sol";

interface IPausable {
    function pause() external;
    function unpause() external;
}

contract L1ChainAssetHandlerTest is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    using stdStorage for StdStorage;

    bytes32 constant NEW_PRIORITY_REQUEST_HASH =
        keccak256(
            "NewPriorityRequest(uint256,bytes32,uint64,(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256[4],bytes,bytes,uint256[],bytes,bytes),bytes[])"
        );

    struct NewPriorityRequest {
        uint256 txId;
        bytes32 txHash;
        uint64 expirationTimestamp;
        L2CanonicalTransaction transaction;
        bytes[] factoryDeps;
    }

    uint256 constant TEST_USERS_COUNT = 10;
    address[] public users;
    address[] public l2ContractAddresses;
    bytes32 public l2TokenAssetId;
    address public tokenL1Address;
    SimpleExecutor simpleExecutor;

    IL2ChainAssetHandler public l2ChainAssetHandler;

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
        _deployEra();
    }

    function setUp() public {
        prepare();
        bytes32 ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(eraZKChainId, ETH_TOKEN_ADDRESS);

        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler),
            abi.encodeWithSelector(IChainAssetHandler.migrationNumber.selector),
            abi.encode(0)
        );
        vm.mockCall(
            address(ecosystemAddresses.bridgehub.proxies.messageRoot),
            abi.encodeWithSelector(IL1MessageRoot.v31UpgradeChainBatchNumber.selector),
            abi.encode(10)
        );

        bytes32 ethAssetId = 0x8df3463b1850eb1d8d1847743ea155aef6b16074db8ba81d897dc30554fb2085;
        stdstore
            .target(address(ecosystemAddresses.bridgehub.proxies.assetTracker))
            .sig(IAssetTrackerBase.chainBalance.selector)
            .with_key(eraZKChainId)
            .with_key(ETH_TOKEN_ASSET_ID)
            .checked_write(100);
        vm.prank(Ownable2StepUpgradeable(addresses.l1NativeTokenVault).pendingOwner());
        Ownable2StepUpgradeable(addresses.l1NativeTokenVault).acceptOwnership();

        l2ChainAssetHandler = IL2ChainAssetHandler(
            address(
                new L2ChainAssetHandler()
                // L1_CHAIN_ID,
                // address(this),
                // ecosystemAddresses.bridgehub.proxies.bridgehub,
                // ecosystemAddresses.bridgehub.assetRouterProxy,
                // ecosystemAddresses.bridgehub.proxies.messageRoot
            )
        );
    }

    function test_setMigrationNumberForV31_Success() public {
        address eraChain = IBridgehubBase(ecosystemAddresses.bridgehub.proxies.bridgehub).getZKChain(eraZKChainId);
        vm.prank(eraChain);
        IChainAssetHandler(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).setMigrationNumberForV31(
            eraZKChainId
        );
    }

    function test_setMigrationNumberForV31_NotChain() public {
        address eraChain = IBridgehubBase(ecosystemAddresses.bridgehub.proxies.bridgehub).getZKChain(eraZKChainId);
        vm.expectRevert();
        IChainAssetHandler(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).setMigrationNumberForV31(
            eraZKChainId
        );
    }

    function test_pauseMigration_byOwner() public {
        address owner = Ownable2StepUpgradeable(address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler))
            .owner();
        vm.prank(owner);
        IChainAssetHandler(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).pauseMigration();
        // Optionally add: assert migrationPaused is true if readable
    }

    function test_unpauseMigration_byOwner() public {
        address owner = Ownable2StepUpgradeable(address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler))
            .owner();
        vm.prank(owner);
        IChainAssetHandler(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).unpauseMigration();
        // Optionally add: assert migrationPaused is false if readable
    }

    function test_pause_byOwner() public {
        address owner = Ownable2StepUpgradeable(address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler))
            .owner();
        vm.prank(owner);
        IPausable(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).pause();
        vm.prank(owner);
        IPausable(ecosystemAddresses.bridgehub.proxies.chainAssetHandler).unpause();
        // Optionally add: assert paused is true if readable
    }

    function test_bridgeBurn_Failed() public {
        vm.expectRevert();
        IChainAssetHandler(address(l2ChainAssetHandler)).bridgeBurn(eraZKChainId, 0, 0, address(0), "");

        address owner = Ownable2StepUpgradeable(address(ecosystemAddresses.bridgehub.proxies.chainAssetHandler))
            .owner();
        vm.prank(address(0));
        IChainAssetHandler(address(l2ChainAssetHandler)).pauseMigration();

        vm.expectRevert();
        vm.prank(address(0));
        IChainAssetHandler(address(l2ChainAssetHandler)).bridgeBurn(eraZKChainId, 0, 0, address(0), "");
    }

    function test_setSettlementLayerChainId_Success() public {
        address systemContext = L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR;
        vm.prank(systemContext);
        l2ChainAssetHandler.setSettlementLayerChainId(eraZKChainId, eraZKChainId);
    }
    function test_setSettlementLayerChainId_NotSystemContext() public {
        address notSystemContext = makeAddr("notSystemContext");
        vm.expectRevert();
        vm.prank(notSystemContext);
        l2ChainAssetHandler.setSettlementLayerChainId(eraZKChainId, eraZKChainId);
    }
}
