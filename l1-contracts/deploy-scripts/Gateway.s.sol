// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";
// import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
// import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
// import {Governance} from "contracts/governance/Governance.sol";
// import {Utils} from "./Utils.sol";
// import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
// import {IL1NativeTokenVault} from "contracts/bridge/interfaces/IL1NativeTokenVault.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehub.sol";
import {L2_BRIDGEHUB_ADDR} from "contracts/common/L2ContractAddresses.sol";

// import {IL1AssetRouter} from "contracts/bridge/interfaces/IL1AssetRouter.sol";

import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";

contract GatewayScript is Script {
    using stdToml for string;

    address internal constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
    bytes32 internal constant STATE_TRANSITION_NEW_CHAIN_HASH = keccak256("NewHyperchain(uint256,address)");

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        address deployerAddress;
        address ownerAddress;
        uint256 chainChainId;
        bool validiumMode;
        uint256 bridgehubCreateNewChainSalt;
        address validatorSenderOperatorCommitEth;
        address validatorSenderOperatorBlobsEth;
        address baseToken;
        uint128 baseTokenGasPriceMultiplierNominator;
        uint128 baseTokenGasPriceMultiplierDenominator;
        address bridgehub;
        address stmDeploymentTracker;
        address nativeTokenVault;
        address stateTransitionProxy;
        address sharedBridgeProxy;
        address validatorTimelock;
        bytes diamondCutData;
        bytes forceDeployments;
        address governanceSecurityCouncilAddress;
        uint256 governanceMinDelay;
        address newDiamondProxy;
        address governance;
        uint256 gatewayChainId;
    }

    Config internal config;

    function run() public {
        console.log("Setting up the Gateway script");

        initializeConfig();
    }

    function initializeConfig() internal {
        // Grab config from output of l1 deployment
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, vm.envString("L1_OUTPUT")); //"/script-config/register-hyperchain.toml");
        string memory toml = vm.readFile(path);

        config.deployerAddress = msg.sender;

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml

        config.bridgehub = toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr");
        config.stateTransitionProxy = toml.readAddress(
            "$.deployed_addresses.state_transition.state_transition_proxy_addr"
        );
        config.sharedBridgeProxy = toml.readAddress("$.deployed_addresses.bridges.shared_bridge_proxy_addr");
        config.validatorTimelock = toml.readAddress("$.deployed_addresses.validator_timelock_addr");
        // config.bridgehubGovernance = toml.readAddress("$.deployed_addresses.governance_addr");
        config.nativeTokenVault = toml.readAddress("$.deployed_addresses.native_token_vault_addr");
        config.diamondCutData = toml.readBytes("$.contracts_config.diamond_cut_data");
        config.forceDeployments = toml.readBytes("$.contracts_config.force_deployments_data");
        config.stmDeploymentTracker = toml.readAddress(
            "$.deployed_addresses.bridgehub.stm_deployment_tracker_proxy_addr"
        );
        path = string.concat(root, vm.envString("HYPERCHAIN_CONFIG"));
        toml = vm.readFile(path);

        config.ownerAddress = toml.readAddress("$.owner_address");

        config.chainChainId = toml.readUint("$.chain.chain_chain_id");
        config.bridgehubCreateNewChainSalt = toml.readUint("$.chain.bridgehub_create_new_chain_salt");
        config.baseToken = toml.readAddress("$.chain.base_token_addr");
        config.validiumMode = toml.readBool("$.chain.validium_mode");
        config.validatorSenderOperatorCommitEth = toml.readAddress("$.chain.validator_sender_operator_commit_eth");
        config.validatorSenderOperatorBlobsEth = toml.readAddress("$.chain.validator_sender_operator_blobs_eth");
        config.baseTokenGasPriceMultiplierNominator = uint128(
            toml.readUint("$.chain.base_token_gas_price_multiplier_nominator")
        );
        config.baseTokenGasPriceMultiplierDenominator = uint128(
            toml.readUint("$.chain.base_token_gas_price_multiplier_denominator")
        );
        config.governanceMinDelay = uint256(toml.readUint("$.chain.governance_min_delay"));
        config.governanceSecurityCouncilAddress = toml.readAddress("$.chain.governance_security_council_address");

        path = string.concat(root, vm.envString("GATEWAY_CONFIG"));
        toml = vm.readFile(path);

        config.gatewayChainId = toml.readUint("$.chain.chain_chain_id");
    }

    function registerGateway() public {
        IBridgehub bridgehub = IBridgehub(config.bridgehub);
        Ownable ownable = Ownable(config.bridgehub);
        vm.prank(ownable.owner());
        bridgehub.registerSettlementLayer(config.gatewayChainId, true);
        // bytes memory data = abi.encodeCall(stm.registerSettlementLayer, (config.chainChainId, true));
        // Utils.executeUpgrade({
        //     _governor: ownable.owner(),
        //     _salt: bytes32(config.bridgehubCreateNewChainSalt),
        //     _target: config.stateTransitionProxy,
        //     _data: data,
        //     _value: 0,
        //     _delay: 0
        // });
        console.log("Gateway registered on STM");
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
        IZkSyncHyperchain chain = IZkSyncHyperchain(bridgehub.getHyperchain(config.chainChainId));
        console.log("chainAdmin", bridgehub.getHyperchain(config.chainChainId), chain.getAdmin());
        bytes32 stmAssetId = bridgehub.stmAssetIdFromChainId(config.chainChainId);
        bytes memory diamondCutData = config.diamondCutData; // todo replace with config.zkDiamondCutData;
        bytes memory stmData = abi.encode(newAdmin, diamondCutData);
        bytes memory chainData = abi.encode(address(1));
        bytes memory bridgehubData = abi.encode(config.chainChainId, stmData, chainData);
        bytes memory routerData = bytes.concat(bytes1(0x01), abi.encode(stmAssetId, bridgehubData));

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
        Ownable ownable = Ownable(config.stmDeploymentTracker);
        // IStateTransitionManager stm = IStateTransitionManager(config.stateTransitionProxy);

        uint256 gasPrice = 10;
        uint256 l2GasLimit = 72000000;

        uint256 expectedCost = bridgehub.l2TransactionBaseCost(
            config.chainChainId,
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        ) * 2;
        bytes32 assetId = bridgehub.stmAssetIdFromChainId(config.chainChainId);
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
            secondBridgeAddress: config.stmDeploymentTracker,
            secondBridgeValue: 0,
            secondBridgeCalldata: abi.encode(config.stateTransitionProxy, config.stateTransitionProxy)
        });
        vm.startBroadcast(ownable.owner());
        bridgehub.requestL2TransactionTwoBridges{value: expectedCost}(assetRouterRegistrationRequest);
        bridgehub.requestL2TransactionTwoBridges{value: expectedCost}(bridehubRegistrationRequest);
        vm.stopBroadcast();
    }
}
