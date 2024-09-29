// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";

import {L2_ASSET_ROUTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_BRIDGEHUB_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {ETH_TOKEN_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER} from "contracts/common/Config.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {BridgehubMintCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IL2AssetRouter} from "contracts/bridge/asset-router/IL2AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

import {L2ContractDummyDeployer} from "./_SharedL2ContractDummyDeployer.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {SystemContractsArgs} from "./_SharedL2ContractDummyDeployer.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";

abstract contract L2GatewayTestsAbstract is Test, DeployUtils {
    // We need to emulate a L1->L2 transaction from the L1 bridge to L2 counterpart.
    // It is a bit easier to use EOA and it is sufficient for the tests.
    address internal l1BridgeWallet = address(1);
    address internal aliasedL1BridgeWallet;

    // The owner of the beacon and the native token vault
    address internal ownerWallet = address(2);

    BridgedStandardERC20 internal standardErc20Impl;

    UpgradeableBeacon internal beacon;
    BeaconProxy internal proxy;

    IL2AssetRouter l2AssetRouter = IL2AssetRouter(L2_ASSET_ROUTER_ADDR);
    IBridgehub l2Bridgehub = IBridgehub(L2_BRIDGEHUB_ADDR);

    uint256 internal constant L1_CHAIN_ID = 10; // it cannot be 9, the default block.chainid
    uint256 internal ERA_CHAIN_ID = 270;
    uint256 internal mintChainId = 300;
    address internal l1AssetRouter = makeAddr("l1AssetRouter");
    address internal aliasedL1AssetRouter = AddressAliasHelper.applyL1ToL2Alias(l1AssetRouter);

    address internal l1CTMDeployer = makeAddr("l1CTMDeployer");
    address internal l1CTM = makeAddr("l1CTM");
    bytes32 internal ctmAssetId = keccak256(abi.encode(L1_CHAIN_ID, l1CTMDeployer, bytes32(uint256(uint160(l1CTM)))));

    bytes32 internal baseTokenAssetId =
        keccak256(abi.encode(L1_CHAIN_ID, L2_NATIVE_TOKEN_VAULT_ADDR, abi.encode(ETH_TOKEN_ADDRESS)));

    bytes internal exampleChainCommitment;

    IChainTypeManager internal chainTypeManager;

    // L2ContractDeployer internal deployScript;

    function setUp() public {
        aliasedL1BridgeWallet = AddressAliasHelper.applyL1ToL2Alias(l1BridgeWallet);

        standardErc20Impl = new BridgedStandardERC20();
        beacon = new UpgradeableBeacon(address(standardErc20Impl));
        beacon.transferOwnership(ownerWallet);

        // One of the purposes of deploying it here is to publish its bytecode
        BeaconProxy beaconProxy = new BeaconProxy(address(beacon), new bytes(0));
        proxy = beaconProxy;
        bytes32 beaconProxyBytecodeHash;
        assembly {
            beaconProxyBytecodeHash := extcodehash(beaconProxy)
        }

        address l2SharedBridge = makeAddr("l2SharedBridge");

        initSystemContracts(
            SystemContractsArgs({
                l1ChainId: L1_CHAIN_ID,
                eraChainId: ERA_CHAIN_ID,
                l1AssetRouter: l1AssetRouter,
                legacySharedBridge: l2SharedBridge,
                l2TokenBeacon: address(beacon),
                l2TokenProxyBytecodeHash: beaconProxyBytecodeHash,
                aliasedOwner: ownerWallet,
                contractsDeployedAlready: false,
                l1CtmDeployer: l1CTMDeployer
            })
        );
        deployL2Contracts(L1_CHAIN_ID);

        vm.prank(aliasedL1AssetRouter);
        l2AssetRouter.setAssetHandlerAddress(L1_CHAIN_ID, ctmAssetId, L2_BRIDGEHUB_ADDR);
        vm.prank(ownerWallet);
        l2Bridgehub.addChainTypeManager(address(addresses.stateTransition.chainTypeManagerProxy));
        vm.prank(AddressAliasHelper.applyL1ToL2Alias(l1CTMDeployer));
        l2Bridgehub.setAssetHandlerAddress(
            bytes32(uint256(uint160(l1CTM))),
            address(addresses.stateTransition.chainTypeManagerProxy)
        );
        chainTypeManager = IChainTypeManager(address(addresses.stateTransition.chainTypeManagerProxy));
        getExampleChainCommitment();
    }

    function test_gatewayShouldFinalizeDeposit() public {
        finalizeDeposit();
    }

    function getExampleChainCommitment() internal returns (bytes memory) {
        vm.mockCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(IL1AssetRouter.L1_NULLIFIER.selector),
            abi.encode(L2_ASSET_ROUTER_ADDR)
        );
        vm.mockCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSelector(IL1Nullifier.l2BridgeAddress.selector),
            abi.encode(address(0))
        );
        vm.prank(L2_BRIDGEHUB_ADDR);
        address chainAddress = chainTypeManager.createNewChain(
            ERA_CHAIN_ID + 1,
            baseTokenAssetId,
            L2_ASSET_ROUTER_ADDR,
            address(0x1),
            abi.encode(config.contracts.diamondCutData, generatedData.forceDeploymentsData),
            new bytes[](0)
        );
        exampleChainCommitment = abi.encode(IZKChain(chainAddress).prepareChainCommitment());
    }

    function test_forwardToL3OnGateway() public {
        // todo fix this test
        finalizeDeposit();
        IBridgehub bridgehub = IBridgehub(L2_BRIDGEHUB_ADDR);
        vm.prank(SETTLEMENT_LAYER_RELAY_SENDER);
        bridgehub.forwardTransactionOnGateway(mintChainId, bytes32(0), 0);
    }

    function finalizeDeposit() public {
        bytes memory chainData = exampleChainCommitment;
        bytes memory ctmData = abi.encode(
            baseTokenAssetId,
            msg.sender,
            chainTypeManager.protocolVersion(),
            config.contracts.diamondCutData
        );
        BridgehubMintCTMAssetData memory data = BridgehubMintCTMAssetData({
            chainId: mintChainId,
            baseTokenAssetId: baseTokenAssetId,
            ctmData: ctmData,
            chainData: chainData
        });
        vm.prank(aliasedL1AssetRouter);
        l2AssetRouter.finalizeDeposit(L1_CHAIN_ID, ctmAssetId, abi.encode(data));
    }

    function initSystemContracts(SystemContractsArgs memory _args) internal virtual;
    function deployL2Contracts(uint256 _l1ChainId) public virtual;
}
