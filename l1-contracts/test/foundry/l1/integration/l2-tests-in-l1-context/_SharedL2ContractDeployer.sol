// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";

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
import {L2WrappedBaseToken} from "contracts/bridge/L2WrappedBaseToken.sol";
import {L2SharedBridgeLegacy} from "contracts/bridge/L2SharedBridgeLegacy.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {BridgehubL2TransactionRequest} from "contracts/common/Messaging.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {SystemContractsArgs} from "./Utils.sol";

import {DeployUtils} from "deploy-scripts/DeployUtils.s.sol";
import {DeployIntegrationUtils} from "../deploy-scripts/DeployIntegrationUtils.s.sol";

abstract contract SharedL2ContractDeployer is Test, DeployIntegrationUtils {
    L2WrappedBaseToken internal weth;
    address internal l1WethAddress = address(4);

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

    // We won't actually deploy an L1 token in these tests, but we need some address for it.
    address internal L1_TOKEN_ADDRESS = 0x1111100000000000000000000000000000011111;

    string internal constant TOKEN_DEFAULT_NAME = "TestnetERC20Token";
    string internal constant TOKEN_DEFAULT_SYMBOL = "TET";
    uint8 internal constant TOKEN_DEFAULT_DECIMALS = 18;
    address internal l1CTMDeployer = makeAddr("l1CTMDeployer");
    address internal l1CTM = makeAddr("l1CTM");
    bytes32 internal ctmAssetId = keccak256(abi.encode(L1_CHAIN_ID, l1CTMDeployer, bytes32(uint256(uint160(l1CTM)))));

    bytes32 internal baseTokenAssetId =
        keccak256(abi.encode(L1_CHAIN_ID, L2_NATIVE_TOKEN_VAULT_ADDR, abi.encode(ETH_TOKEN_ADDRESS)));

    bytes internal exampleChainCommitment;

    address internal sharedBridgeLegacy;

    IChainTypeManager internal chainTypeManager;

    function setUp() public {
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

        sharedBridgeLegacy = deployL2SharedBridgeLegacy(
            L1_CHAIN_ID,
            ERA_CHAIN_ID,
            ownerWallet,
            l1AssetRouter,
            beaconProxyBytecodeHash
        );

        L2WrappedBaseToken weth = deployL2Weth();

        initSystemContracts(
            SystemContractsArgs({
                l1ChainId: L1_CHAIN_ID,
                eraChainId: ERA_CHAIN_ID,
                l1AssetRouter: l1AssetRouter,
                legacySharedBridge: sharedBridgeLegacy,
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
        l2Bridgehub.setCTMAssetAddress(
            bytes32(uint256(uint160(l1CTM))),
            address(addresses.stateTransition.chainTypeManagerProxy)
        );
        chainTypeManager = IChainTypeManager(address(addresses.stateTransition.chainTypeManagerProxy));
        getExampleChainCommitment();
    }

    function getExampleChainCommitment() internal returns (bytes memory) {
        address chainAdmin = makeAddr("chainAdmin");

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
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehub.baseToken.selector, ERA_CHAIN_ID + 1),
            abi.encode(address(uint160(1)))
        );

        vm.prank(L2_BRIDGEHUB_ADDR);
        address chainAddress = chainTypeManager.createNewChain(
            ERA_CHAIN_ID + 1,
            baseTokenAssetId,
            chainAdmin,
            abi.encode(config.contracts.diamondCutData, generatedData.forceDeploymentsData),
            new bytes[](0)
        );

        uint256 currentChainId = block.chainid;

        // This function is available only on L1 (and it is correct),
        // but inside testing we need to call this function to recreate commitment
        vm.chainId(L1_CHAIN_ID);
        vm.prank(chainAdmin);
        AdminFacet(chainAddress).setTokenMultiplier(1, 1);

        vm.chainId(currentChainId);

        // Now, let's also append a priority transaction for a more representative example
        bytes[] memory deps = new bytes[](0);

        vm.prank(address(l2Bridgehub));
        MailboxFacet(chainAddress).bridgehubRequestL2Transaction(
            BridgehubL2TransactionRequest({
                sender: address(0),
                contractL2: address(0),
                // Just a giant number so it is always enough
                mintValue: 1 ether,
                l2Value: 10,
                l2Calldata: hex"",
                l2GasLimit: 72_000_000,
                l2GasPerPubdataByteLimit: 800,
                factoryDeps: deps,
                refundRecipient: address(0)
            })
        );

        exampleChainCommitment = abi.encode(IZKChain(chainAddress).prepareChainCommitment());
    }

    /// @notice Encodes the token data.
    /// @param name The name of the token.
    /// @param symbol The symbol of the token.
    /// @param decimals The decimals of the token.
    function encodeTokenData(
        string memory name,
        string memory symbol,
        uint8 decimals
    ) internal pure returns (bytes memory) {
        bytes memory encodedName = abi.encode(name);
        bytes memory encodedSymbol = abi.encode(symbol);
        bytes memory encodedDecimals = abi.encode(decimals);

        return abi.encode(encodedName, encodedSymbol, encodedDecimals);
    }

    function deployL2SharedBridgeLegacy(
        uint256 _l1ChainId,
        uint256 _eraChainId,
        address _aliasedOwner,
        address _l1SharedBridge,
        bytes32 _l2TokenProxyBytecodeHash
    ) internal returns (address) {
        bytes32 ethAssetId = DataEncoding.encodeNTVAssetId(_l1ChainId, ETH_TOKEN_ADDRESS);

        L2SharedBridgeLegacy bridge = new L2SharedBridgeLegacy();
        console.log("bridge", address(bridge));
        address proxyAdmin = address(0x1);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(bridge),
            proxyAdmin,
            abi.encodeWithSelector(
                L2SharedBridgeLegacy.initialize.selector,
                _l1SharedBridge,
                _l2TokenProxyBytecodeHash,
                _aliasedOwner
            )
        );
        console.log("proxy", address(proxy));
        return address(proxy);
    }

    function deployL2Weth() internal returns (L2WrappedBaseToken) {
        L2WrappedBaseToken wethImpl = new L2WrappedBaseToken();
        TransparentUpgradeableProxy wethProxy = new TransparentUpgradeableProxy(address(wethImpl), ownerWallet, "");
        weth = L2WrappedBaseToken(payable(wethProxy));
        weth.initializeV3("Wrapped Ether", "WETH", L2_ASSET_ROUTER_ADDR, l1WethAddress, baseTokenAssetId);
        return weth;
    }

    function initSystemContracts(SystemContractsArgs memory _args) internal virtual;
    function deployL2Contracts(uint256 _l1ChainId) public virtual;

    function test() internal virtual override {}
}
