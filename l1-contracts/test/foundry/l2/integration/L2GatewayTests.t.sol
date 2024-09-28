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
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

import {L2Utils} from "../unit/utils/L2Utils.sol";
import {SystemContractsArgs} from "../unit/utils/L2Utils.sol";

import {L2ContractDeployer} from "./_SharedL2ContractDeployer.t.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

contract L2GatewayTests is Test, L2ContractDeployer { // is L1ContractDeployer, ZKChainDeployer, TokenDeployer {
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

    uint256 internal constant L1_CHAIN_ID = 9;
    uint256 internal ERA_CHAIN_ID = 270;
    address internal l1AssetRouter = makeAddr("l1AssetRouter");
    address internal aliasedL1AssetRouter = AddressAliasHelper.applyL1ToL2Alias(l1AssetRouter);

    address internal l1CTMDeployer = makeAddr("l1CTMDeployer");
    address internal l1CTM = makeAddr("l1CTM");
    bytes32 internal ctmAssetId = keccak256(abi.encode(L1_CHAIN_ID, l1CTMDeployer, abi.encode(l1CTM)));

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

        L2Utils.initSystemContracts(
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
        deployL2Contracts();

        vm.prank(aliasedL1AssetRouter);
        l2AssetRouter.setAssetHandlerAddress(L1_CHAIN_ID, ctmAssetId, L2_BRIDGEHUB_ADDR);
        vm.prank(ownerWallet);
        l2Bridgehub.addChainTypeManager(address(addresses.stateTransition.chainTypeManagerProxy));
        vm.prank(AddressAliasHelper.applyL1ToL2Alias(l1CTMDeployer));
        l2Bridgehub.setAssetHandlerAddress(bytes32(uint256(uint160(l1CTM))), address(addresses.stateTransition.chainTypeManagerProxy));
        chainTypeManager = IChainTypeManager(address(addresses.stateTransition.chainTypeManagerProxy));
    }

    function test_gatewayShouldFinalizeDeposit() public {
        finalizeDeposit();
    }

    function test_forwardToL3OnGateway() public {
        // todo fix this test
        // finalizeDeposit();

        // IBridgehub bridgehub = IBridgehub(L2_BRIDGEHUB_ADDR);
        // vm.prank(SETTLEMENT_LAYER_RELAY_SENDER);
        // bridgehub.forwardTransactionOnGateway(ERA_CHAIN_ID, bytes32(0), 0);
    }

    function finalizeDeposit() public {
        // bytes memory chainData = abi.encode(exampleChainCommitment);
        // bytes memory ctmData = abi.encode(
        //     baseTokenAssetId,
        //     msg.sender,
        //     chainTypeManager.protocolVersion(),
        //     config.contracts.diamondCutData
        // );

        // BridgehubMintCTMAssetData memory data = BridgehubMintCTMAssetData({
        //     chainId: ERA_CHAIN_ID,
        //     baseTokenAssetId: baseTokenAssetId,
        //     ctmData: ctmData,
        //     chainData: chainData
        // });
        // vm.prank(aliasedL1AssetRouter);
        // l2AssetRouter.finalizeDeposit(L1_CHAIN_ID, ctmAssetId, abi.encode(data));
    }
}
