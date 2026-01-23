// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";

import {IL2NativeTokenVault} from "../../../../../contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_ASSET_ROUTER,
    L2_BASE_TOKEN_SYSTEM_CONTRACT,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET} from "contracts/common/Config.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IL2Bridgehub} from "contracts/core/bridgehub/IL2Bridgehub.sol";
import {BridgehubMintCTMAssetData, IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {IL2AssetRouter} from "../../../../../contracts/bridge/asset-router/IL2AssetRouter.sol";
import {IL1Nullifier} from "../../../../../contracts/bridge/interfaces/IL1Nullifier.sol";
import {IL1AssetRouter} from "../../../../../contracts/bridge/asset-router/IL1AssetRouter.sol";

import {
    BridgehubL2TransactionRequest,
    L2Message,
    MessageInclusionProof
} from "../../../../../contracts/common/Messaging.sol";
import {IInteropCenter, InteropCenter} from "../../../../../contracts/interop/InteropCenter.sol";
import {L2WrappedBaseToken} from "../../../../../contracts/bridge/L2WrappedBaseToken.sol";
import {L2SharedBridgeLegacy} from "../../../../../contracts/bridge/L2SharedBridgeLegacy.sol";
import {MailboxFacet} from "../../../../../contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {AdminFacet} from "../../../../../contracts/state-transition/chain-deps/facets/Admin.sol";
import {DataEncoding} from "../../../../../contracts/common/libraries/DataEncoding.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ZKChainBase} from "contracts/state-transition/chain-deps/facets/ZKChainBase.sol";
import {SystemContractsArgs} from "./Utils.sol";

import {DeployIntegrationUtils} from "../deploy-scripts/DeployIntegrationUtils.s.sol";
import {UtilsCallMockerTest} from "foundry-test/l1/unit/concrete/Utils/Utils.t.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {IERC7786Recipient} from "contracts/interop/IERC7786Recipient.sol";

abstract contract SharedL2ContractDeployer is UtilsCallMockerTest, DeployIntegrationUtils {
    L2WrappedBaseToken internal weth;
    address internal l1WethAddress = address(4);

    // The owner of the beacon and the native token vault
    address internal ownerWallet = address(2);

    BridgedStandardERC20 internal standardErc20Impl;

    UpgradeableBeacon internal beacon;
    BeaconProxy internal proxy;

    IL2AssetRouter l2AssetRouter = IL2AssetRouter(L2_ASSET_ROUTER_ADDR);
    IL2Bridgehub l2Bridgehub = IL2Bridgehub(L2_BRIDGEHUB_ADDR);
    InteropCenter l2InteropCenter = InteropCenter(L2_INTEROP_CENTER_ADDR);
    IL2NativeTokenVault l2NativeTokenVault = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);

    uint256 internal constant L1_CHAIN_ID = 10; // it cannot be 9, the default block.chainid
    uint256 internal ERA_CHAIN_ID = 270;
    uint256 internal GATEWAY_CHAIN_ID = 506;
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

    bytes32 internal baseTokenAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);

    bytes internal exampleChainCommitment;

    address internal sharedBridgeLegacy;

    IChainTypeManager internal chainTypeManager;

    address UNBUNDLER_ADDRESS;
    address EXECUTION_ADDRESS;
    address interopTargetContract;
    uint256 originalChainId;

    function setUp() public virtual {
        setUpInner(false);
    }

    function setUpInner(bool _skip) public virtual {
        // Timestamp needs to be big enough for `pauseDepositsBeforeInitiatingMigration` time checks
        vm.warp(PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET + 1);

        if (_skip) {
            vm.startBroadcast();
        }
        standardErc20Impl = new BridgedStandardERC20();
        beacon = new UpgradeableBeacon(address(standardErc20Impl));
        // beacon.transferOwnership(ownerWallet);

        // One of the purposes of deploying it here is to publish its bytecode
        BeaconProxy beaconProxy = new BeaconProxy(address(beacon), new bytes(0));
        proxy = beaconProxy;
        bytes32 beaconProxyBytecodeHash;
        assembly {
            beaconProxyBytecodeHash := extcodehash(beaconProxy)
        }
        UNBUNDLER_ADDRESS = makeAddr("unbundlerAddress");
        EXECUTION_ADDRESS = makeAddr("executionAddress");

        interopTargetContract = makeAddr("interopTargetContract");
        originalChainId = block.chainid;

        coreAddresses.bridgehub.proxies.bridgehub = L2_BRIDGEHUB_ADDR;
        sharedBridgeLegacy = deployL2SharedBridgeLegacy(
            L1_CHAIN_ID,
            ERA_CHAIN_ID,
            ownerWallet,
            l1AssetRouter,
            beaconProxyBytecodeHash
        );

        L2WrappedBaseToken weth = deployL2Weth();
        if (_skip) {
            vm.stopBroadcast();
        }
        initSystemContracts(
            SystemContractsArgs({
                broadcast: _skip,
                l1ChainId: L1_CHAIN_ID,
                eraChainId: ERA_CHAIN_ID,
                gatewayChainId: GATEWAY_CHAIN_ID,
                l1AssetRouter: l1AssetRouter,
                legacySharedBridge: sharedBridgeLegacy,
                l2TokenBeacon: address(beacon),
                l2TokenProxyBytecodeHash: beaconProxyBytecodeHash,
                aliasedOwner: ownerWallet,
                contractsDeployedAlready: false,
                l1CtmDeployer: l1CTMDeployer,
                maxNumberOfZKChains: 100
            })
        );
        if (!_skip) {
            deployL2Contracts(L1_CHAIN_ID);

            vm.prank(aliasedL1AssetRouter);
            l2AssetRouter.setAssetHandlerAddress(L1_CHAIN_ID, ctmAssetId, L2_CHAIN_ASSET_HANDLER_ADDR);
            vm.prank(ownerWallet);
            l2Bridgehub.addChainTypeManager(address(ctmAddresses.stateTransition.proxies.chainTypeManager));
            vm.prank(AddressAliasHelper.applyL1ToL2Alias(l1CTMDeployer));
            l2Bridgehub.setCTMAssetAddress(
                bytes32(uint256(uint160(l1CTM))),
                address(ctmAddresses.stateTransition.proxies.chainTypeManager)
            );
            chainTypeManager = IChainTypeManager(address(ctmAddresses.stateTransition.proxies.chainTypeManager));
            getExampleChainCommitment();
        }

        vm.mockCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1.selector),
            abi.encode(bytes(""))
        );
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector),
            abi.encode(baseTokenAssetId)
        );
        bytes32 realBaseTokenAssetId = L2_ASSET_ROUTER.BASE_TOKEN_ASSET_ID();
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, block.chainid),
            abi.encode(realBaseTokenAssetId)
        );

        vm.mockCall(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_BASE_TOKEN_SYSTEM_CONTRACT.burnMsgValue.selector),
            abi.encode(bytes(""))
        );
        vm.mockCall(
            L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
            abi.encodeWithSelector(L2_BASE_TOKEN_SYSTEM_CONTRACT.mint.selector),
            abi.encode(bytes(""))
        );
        vm.mockCall(
            address(interopTargetContract),
            abi.encodeWithSelector(IERC7786Recipient.receiveMessage.selector),
            abi.encode(IERC7786Recipient.receiveMessage.selector)
        );
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
            abi.encodeWithSelector(IBridgehubBase.baseToken.selector, ERA_CHAIN_ID + 1),
            abi.encode(address(uint160(1)))
        );
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId.selector),
            abi.encode(block.chainid)
        );
        vm.prank(L2_BRIDGEHUB_ADDR);
        mockDiamondInitInteropCenterCallsWithAddress(L2_BRIDGEHUB_ADDR, L2_ASSET_ROUTER_ADDR, baseTokenAssetId);
        uint256 currentChainId = block.chainid;
        vm.chainId(L1_CHAIN_ID);
        address chainAddress = chainTypeManager.createNewChain(
            ERA_CHAIN_ID + 1,
            baseTokenAssetId,
            chainAdmin,
            abi.encode(config.contracts.diamondCutData, generatedData.forceDeploymentsData),
            new bytes[](0)
        );
        vm.chainId(currentChainId);

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
        address proxyAdmin = makeAddr("proxyAdmin");
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

    function finalizeDeposit() public {
        finalizeDepositWithCustomCommitment(exampleChainCommitment);
    }

    function finalizeDepositWithChainId(uint256 _chainId) public {
        finalizeDepositWithCustomCommitmentAndChainId(_chainId, exampleChainCommitment);
    }

    function finalizeDepositWithCustomCommitment(bytes memory chainCommitment) public {
        finalizeDepositWithCustomCommitmentAndChainId(mintChainId, chainCommitment);
    }

    function finalizeDepositWithCustomCommitmentAndChainId(uint256 _chainId, bytes memory chainCommitment) public {
        bytes memory chainData = chainCommitment;
        bytes memory ctmData = abi.encode(
            baseTokenAssetId,
            ownerWallet,
            chainTypeManager.protocolVersion(),
            config.contracts.diamondCutData
        );
        BridgehubMintCTMAssetData memory data = BridgehubMintCTMAssetData({
            chainId: _chainId,
            baseTokenAssetId: baseTokenAssetId,
            batchNumber: 0,
            ctmData: ctmData,
            chainData: chainData,
            migrationNumber: 0
        });
        vm.prank(aliasedL1AssetRouter);
        AssetRouterBase(address(l2AssetRouter)).finalizeDeposit(L1_CHAIN_ID, ctmAssetId, abi.encode(data));
    }

    function performDeposit(address depositor, address receiver, uint256 amount) internal {
        vm.prank(aliasedL1AssetRouter);
        L2AssetRouter(L2_ASSET_ROUTER_ADDR).finalizeDeposit({
            _l1Sender: depositor,
            _l2Receiver: receiver,
            _l1Token: L1_TOKEN_ADDRESS,
            _amount: amount,
            _data: encodeTokenData(TOKEN_DEFAULT_NAME, TOKEN_DEFAULT_SYMBOL, TOKEN_DEFAULT_DECIMALS)
        });
    }

    function initializeTokenByDeposit() internal returns (address l2TokenAddress) {
        performDeposit(makeAddr("someDepositor"), makeAddr("someReceiver"), 1);

        l2TokenAddress = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).l2TokenAddress(L1_TOKEN_ADDRESS);
        if (l2TokenAddress == address(0)) {
            revert("Token not initialized");
        }
        vm.prank(L2_NATIVE_TOKEN_VAULT_ADDR);
        BridgedStandardERC20(l2TokenAddress).bridgeMint(address(this), 100000);
    }

    function getInclusionProof(address messageSender) public view returns (MessageInclusionProof memory) {
        return getInclusionProof(messageSender, ERA_CHAIN_ID);
    }

    function getInclusionProof(
        address messageSender,
        uint256 _chainId
    ) public view returns (MessageInclusionProof memory) {
        bytes32[] memory proof = new bytes32[](27);
        proof[0] = bytes32(0x010f050000000000000000000000000000000000000000000000000000000000);
        proof[1] = bytes32(0x72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43ba);
        proof[2] = bytes32(0xc3d03eebfd83049991ea3d3e358b6712e7aa2e2e63dc2d4b438987cec28ac8d0);
        proof[3] = bytes32(0xe3697c7f33c31a9b0f0aeb8542287d0d21e8c4cf82163d0c44c7a98aa11aa111);
        proof[4] = bytes32(0x199cc5812543ddceeddd0fc82807646a4899444240db2c0d2f20c3cceb5f51fa);
        proof[5] = bytes32(0xe4733f281f18ba3ea8775dd62d2fcd84011c8c938f16ea5790fd29a03bf8db89);
        proof[6] = bytes32(0x1798a1fd9c8fbb818c98cff190daa7cc10b6e5ac9716b4a2649f7c2ebcef2272);
        proof[7] = bytes32(0x66d7c5983afe44cf15ea8cf565b34c6c31ff0cb4dd744524f7842b942d08770d);
        proof[8] = bytes32(0xb04e5ee349086985f74b73971ce9dfe76bbed95c84906c5dffd96504e1e5396c);
        proof[9] = bytes32(0xac506ecb5465659b3a927143f6d724f91d8d9c4bdb2463aee111d9aa869874db);
        proof[10] = bytes32(0x124b05ec272cecd7538fdafe53b6628d31188ffb6f345139aac3c3c1fd2e470f);
        proof[11] = bytes32(0xc3be9cbd19304d84cca3d045e06b8db3acd68c304fc9cd4cbffe6d18036cb13f);
        proof[12] = bytes32(0xfef7bd9f889811e59e4076a0174087135f080177302763019adaf531257e3a87);
        proof[13] = bytes32(0xa707d1c62d8be699d34cb74804fdd7b4c568b6c1a821066f126c680d4b83e00b);
        proof[14] = bytes32(0xf6e093070e0389d2e529d60fadb855fdded54976ec50ac709e3a36ceaa64c291);
        proof[15] = bytes32(0xe4ed1ec13a28c40715db6399f6f99ce04e5f19d60ad3ff6831f098cb6cf75944);
        proof[16] = bytes32(0x000000000000000000000000000000000000000000000000000000000000001e);
        proof[17] = bytes32(0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21);
        proof[18] = bytes32(0x72bb6e886e3de761d93578a590bfe0e44fb544481eb63186f6a6d184aec321a8);
        proof[19] = bytes32(0x3cc519adb13de86ec011fa462394c5db945103c4d35919c9433d7b990de49c87);
        proof[20] = bytes32(0xcc52bf2ee1507ce0b5dbf31a95ce4b02043c142aab2466fc24db520852cddf5f);
        proof[21] = bytes32(0x40ad48c159fc740c32e9b540f79561a4760501ef80e32c61e477ac3505d3dabd);
        proof[22] = bytes32(0x0000000000000000000000000000009f00000000000000000000000000000001);
        proof[23] = bytes32(0x00000000000000000000000000000000000000000000000000000000000001fa);
        proof[24] = bytes32(0x0102000100000000000000000000000000000000000000000000000000000000);
        proof[25] = bytes32(0xf84927dc03d95cc652990ba75874891ccc5a4d79a0e10a2ffdd238a34a39f828);
        proof[26] = bytes32(0xe25714e53790167f58b1da56145a1c025a461008fe358f583f53d764000ca847);

        return
            MessageInclusionProof({
                chainId: _chainId,
                l1BatchNumber: 31,
                l2MessageIndex: 0,
                message: L2Message(
                    0,
                    address(messageSender),
                    hex"9c884fd1000000000000000000000000000000000000000000000000000000000000010f76b59944c0e577e988c1b823ef4ad168478ddfe6044cca433996ade7637ec70d00000000000000000000000083aeb38092d5f5a5cf7fb8ccf94c981c1d37d81300000000000000000000000083aeb38092d5f5a5cf7fb8ccf94c981c1d37d813000000000000000000000000ee0dcf9b8c3048530fd6b2211ae3ba32e8590905000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000001c1010000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000180000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000004574254430000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000457425443000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000"
                ),
                proof: proof
            });
    }

    function initSystemContracts(SystemContractsArgs memory _args) internal virtual;
    function deployL2Contracts(uint256 _l1ChainId) public virtual;

    function test() internal virtual override(DeployIntegrationUtils, UtilsCallMockerTest) {}
}
