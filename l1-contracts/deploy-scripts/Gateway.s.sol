// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";
// import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {IBridgehub, BridgehubBurnCTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {GatewayTransactionFilterer} from "contracts/transactionFilterer/GatewayTransactionFilterer.sol";
// import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
// import {Governance} from "contracts/governance/Governance.sol";
// import {Utils} from "./Utils.sol";
// import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
// import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehub.sol";
import {L2_BRIDGEHUB_ADDR} from "contracts/common/L2ContractAddresses.sol";

// import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";

contract GatewayScript is Script {
    using stdToml for string;

    address internal constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
    bytes32 internal constant STATE_TRANSITION_NEW_CHAIN_HASH = keccak256("NewZKChain(uint256,address)");

    address deployerAddress;

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        address bridgehub;
        address ctmDeploymentTracker;
        address nativeTokenVault;
        address stateTransitionProxy;
        address sharedBridgeProxy;
        uint256 chainChainId;
        bytes diamondCutData;
        bytes forceDeployments;
        address governance;
        uint256 gatewayChainId;
    }

    // The address of the validator timelock on gateway
    struct GatewayConfig {
        address validatorTimelock;
    }

    Config internal config;

    function run() public {
        console.log("Setting up the Gateway script");

        deployerAddress = msg.sender;

        initializeConfig();
    }

    function initializeConfig() internal {
        // Grab config from output of l1 deployment
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, vm.envString("L1_OUTPUT")); //"/script-config/register-zkChain.toml");
        string memory toml = vm.readFile(path);

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml

        // config.bridgehub = toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr");
        // config.stateTransitionProxy = toml.readAddress(
        //     "$.deployed_addresses.state_transition.chain_type_manager_proxy_addr"
        // );
        // config.sharedBridgeProxy = toml.readAddress("$.deployed_addresses.bridges.shared_bridge_proxy_addr");
        // config.validatorTimelock = toml.readAddress("$.deployed_addresses.validator_timelock_addr");
        // // config.bridgehubGovernance = toml.readAddress("$.deployed_addresses.governance_addr");
        // config.nativeTokenVault = toml.readAddress("$.deployed_addresses.native_token_vault_addr");
        // config.diamondCutData = toml.readBytes("$.contracts_config.diamond_cut_data");
        // config.forceDeployments = toml.readBytes("$.contracts_config.force_deployments_data");
        // config.stmDeploymentTracker = toml.readAddress(
        //     "$.deployed_addresses.bridgehub.stm_deployment_tracker_proxy_addr"
        // );
        // path = string.concat(root, vm.envString("HYPERCHAIN_CONFIG"));
        // toml = vm.readFile(path);

        // config.chainChainId = toml.readUint("$.chain.chain_chain_id");

        // path = string.concat(root, vm.envString("GATEWAY_CONFIG"));
        // toml = vm.readFile(path);

        // config.gatewayChainId = toml.readUint("$.chain.chain_chain_id");
    }

    function registerGateway() public {
        IBridgehub bridgehub = IBridgehub(config.bridgehub);
        Ownable ownable = Ownable(config.bridgehub);
        Ownable ownableStmDT = Ownable(config.ctmDeploymentTracker);
        IZKChain chainL2 = IZKChain(bridgehub.getZKChain(config.chainChainId));
        IZKChain chain = IZKChain(bridgehub.getZKChain(config.gatewayChainId));
        vm.startPrank(chain.getAdmin());
        GatewayTransactionFilterer transactionFiltererImplementation = new GatewayTransactionFilterer(
            IBridgehub(config.bridgehub),
            config.sharedBridgeProxy
        );
        address transactionFiltererProxy = address(
            new TransparentUpgradeableProxy(
                address(transactionFiltererImplementation),
                chain.getAdmin(),
                abi.encodeCall(GatewayTransactionFilterer.initialize, ownable.owner())
            )
        );
        chain.setTransactionFilterer(transactionFiltererProxy);
        vm.stopPrank();

        vm.startPrank(ownable.owner());
        GatewayTransactionFilterer(transactionFiltererProxy).grantWhitelist(ownableStmDT.owner());
        GatewayTransactionFilterer(transactionFiltererProxy).grantWhitelist(chainL2.getAdmin());
        GatewayTransactionFilterer(transactionFiltererProxy).grantWhitelist(config.sharedBridgeProxy);
        bridgehub.registerSettlementLayer(config.gatewayChainId, true);
        console.log("Gateway registered on CTM");
    }

    function moveChainToGateway() public {
        IBridgehub bridgehub = IBridgehub(config.bridgehub);
        // IL1AssetRouter router = IL1AssetRouter(config.sharedBridgeProxy);
        Ownable ownable = Ownable(config.bridgehub);

        uint256 gasPrice = 10; //Utils.bytesToUint256(vm.rpc("eth_gasPrice", "[]"));
        uint256 l2GasLimit = 72000000;

        uint256 expectedCost = bridgehub.l2TransactionBaseCost(
            config.gatewayChainId,
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        ) * 2;

        address newAdmin = ownable.owner();
        console.log("newAdmin", newAdmin);
        IZKChain chain = IZKChain(bridgehub.getZKChain(config.chainChainId));
        console.log("chainAdmin", bridgehub.getZKChain(config.chainChainId), chain.getAdmin());
        bytes32 ctmAssetId = bridgehub.ctmAssetIdFromChainId(config.chainChainId);
        bytes memory diamondCutData = config.diamondCutData; // todo replace with config.zkDiamondCutData;
        bytes memory ctmData = abi.encode(newAdmin, diamondCutData);
        bytes memory chainData = abi.encode(chain.getProtocolVersion());
        BridgehubBurnCTMAssetData memory ctmAssetData = BridgehubBurnCTMAssetData({
            chainId: config.chainChainId,
            ctmData: ctmData,
            chainData: chainData
        });
        bytes memory bridgehubData = abi.encode(ctmAssetData);
        bytes memory routerData = bytes.concat(bytes1(0x01), abi.encode(ctmAssetId, bridgehubData));

        vm.startBroadcast(chain.getAdmin());
        L2TransactionRequestTwoBridgesOuter memory request = L2TransactionRequestTwoBridgesOuter({
            chainId: config.gatewayChainId,
            mintValue: expectedCost,
            l2Value: 0,
            l2GasLimit: l2GasLimit,
            l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            refundRecipient: newAdmin,
            secondBridgeAddress: config.sharedBridgeProxy,
            secondBridgeValue: 0,
            secondBridgeCalldata: routerData
        });
        bridgehub.requestL2TransactionTwoBridges{value: expectedCost}(request);
        vm.stopBroadcast();
        console.log("Chain moved to Gateway");
    }

    function registerL2Contracts() public {
        IBridgehub bridgehub = IBridgehub(config.bridgehub);
        Ownable ownable = Ownable(config.ctmDeploymentTracker);
        // IStateTransitionManager stm = IStateTransitionManager(config.stateTransitionProxy);

        uint256 gasPrice = 10;
        uint256 l2GasLimit = 72000000;

        uint256 expectedCost = bridgehub.l2TransactionBaseCost(
            config.chainChainId,
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        ) * 2;
        bytes32 assetId = bridgehub.ctmAssetIdFromChainId(config.chainChainId);
        bytes memory routerData = bytes.concat(bytes1(0x02), abi.encode(assetId, L2_BRIDGEHUB_ADDR));
        L2TransactionRequestTwoBridgesOuter
            memory assetRouterRegistrationRequest = L2TransactionRequestTwoBridgesOuter({
                chainId: config.chainChainId,
                mintValue: expectedCost,
                l2Value: 0,
                l2GasLimit: l2GasLimit,
                l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                refundRecipient: ownable.owner(),
                secondBridgeAddress: config.sharedBridgeProxy,
                secondBridgeValue: 0,
                secondBridgeCalldata: routerData
            });

        L2TransactionRequestTwoBridgesOuter memory bridehubRegistrationRequest = L2TransactionRequestTwoBridgesOuter({
            chainId: config.chainChainId,
            mintValue: expectedCost,
            l2Value: 0,
            l2GasLimit: l2GasLimit,
            l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            refundRecipient: ownable.owner(),
            secondBridgeAddress: config.ctmDeploymentTracker,
            secondBridgeValue: 0,
            secondBridgeCalldata: bytes.concat(
                bytes1(0x01),
                abi.encode(config.stateTransitionProxy, config.stateTransitionProxy)
            )
        });
        vm.startBroadcast(ownable.owner());
        bridgehub.requestL2TransactionTwoBridges{value: expectedCost}(assetRouterRegistrationRequest);
        bridgehub.requestL2TransactionTwoBridges{value: expectedCost}(bridehubRegistrationRequest);
        vm.stopBroadcast();
    }
}
