// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";
// import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {IBridgehub, BridgehubBurnSTMAssetData} from "contracts/bridgehub/IBridgehub.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehub.sol";
import {L2_BRIDGEHUB_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {StateTransitionDeployedAddresses, Utils, L2ContractsBytecodes, L2_BRIDGEHUB_ADDRESS} from "./Utils.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";


/// @notice Scripts that is responsible for preparing the chain to become a gateway
contract GatewayPreparation is Script {
    using stdToml for string;

    address internal constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
    bytes32 internal constant STATE_TRANSITION_NEW_CHAIN_HASH = keccak256("NewHyperchain(uint256,address)");

    address deployerAddress;
    uint256 l1ChainId;

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        address bridgehub;
        address stmDeploymentTracker;
        address stateTransitionProxy;
        address sharedBridgeProxy;
        address governance;
        uint256 chainChainId;

        bytes gatewayDiamondCutData;
    }

    Config internal config;

    function run() public {
        console.log("Setting up the Gateway script");

        initializeConfig();
    }

    function initializeConfig() internal {
        deployerAddress = msg.sender;
        l1ChainId = block.chainid;

        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/gateway-preparation-l1.toml");
        string memory toml = vm.readFile(path);

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml

        // Initializing all values at once is preferrable to ensure type safety of
        // the fact that all values are initialized
        config = Config({
            bridgehub: toml.readAddress("$.bridgehub_proxy_addr"),
            stmDeploymentTracker: toml.readAddress(
                "$.stm_deployment_tracker_proxy_addr"
            ),
            stateTransitionProxy: toml.readAddress(
                "$.state_transition_proxy_addr"
            ),
            sharedBridgeProxy: toml.readAddress("$.shared_bridge_proxy_addr"),
            chainChainId: toml.readUint("$.chain_chain_id"),
            governance: toml.readAddress("$.governance"),
            gatewayDiamondCutData: toml.readBytes("$.gateway_diamond_cut_data")
        });
    }

    function saveOutput(bytes32 l2TxHash) internal {
        string memory toml = vm.serializeBytes32("root", "governance_l2_tx_hash", l2TxHash);
        string memory path = string.concat(vm.projectRoot(), "/script-out/output-gateway-preparation-l1.toml");
        vm.writeToml(toml, path);
    }

    /// @dev Requires the sender to be the owner of the contract
    function governanceRegisterGateway() public {
        initializeConfig();

        IBridgehub bridgehub = IBridgehub(config.bridgehub);

        if(bridgehub.whitelistedSettlementLayers(config.chainChainId)) {
            console.log("Chain already whitelisted as settlement layer");
        } else {

            bytes memory data = abi.encodeCall(bridgehub.registerSettlementLayer, (config.chainChainId, true));
            Utils.executeUpgrade({
                _governor: config.governance,
                _salt: bytes32(0),
                _target: address(bridgehub),
                _data: data,
                _value: 0,
                _delay: 0
            });
            console.log("Gateway whitelisted as settlement layer");

        }
        // No tx has been executed, so we save an empty hash
        saveOutput(bytes32(0));
    }

    /// @dev Requires the sender to be the owner of the contract
    function governanceWhitelistGatewaySTM(address gatewaySTMAddress, bytes32 governanoceOperationSalt) public {
        initializeConfig();

        bytes memory data = abi.encodeCall(
            IBridgehub.addStateTransitionManager,
            (gatewaySTMAddress)
        );

        bytes32 l2TxHash = Utils.runGovernanceL1L2DirectTransaction(
            config.governance,
            governanoceOperationSalt,
            data,
            Utils.MAX_PRIORITY_TX_GAS,
            new bytes[](0),
            L2_BRIDGEHUB_ADDRESS,
            config.chainChainId,
            config.bridgehub,
            config.sharedBridgeProxy
        );

        saveOutput(l2TxHash);
    }

    function governanceSetSTMAssetHandler(bytes32 governanoceOperationSalt) public {
        initializeConfig();

        bytes32 assetId = IBridgehub(config.bridgehub).stmAssetId(config.stateTransitionProxy);
        
        // This should be equivalent to `config.stateTransitionProxy`, but we just double checking to ensure that
        // bridgehub was initialized correctly
        address stmAddress = IBridgehub(config.bridgehub).stmAssetIdToAddress(assetId);
        require(stmAddress == config.stateTransitionProxy, "STM asset id does not match the expected STM address");


        // TODO; refactor to use a constant
        bytes memory secondBridgeData = abi.encodePacked(bytes1(0x02), abi.encode(assetId, L2_BRIDGEHUB_ADDRESS));

        bytes32 l2TxHash = Utils.runGovernanceL1L2TwoBridgesTransaction(
            config.governance,
            governanoceOperationSalt,
            Utils.MAX_PRIORITY_TX_GAS,
            config.chainChainId,
            config.bridgehub,
            config.sharedBridgeProxy,
            config.sharedBridgeProxy,
            0,
            secondBridgeData
        );

        saveOutput(l2TxHash);
    }

    function registerAssetIdInBridgehub(address gatewaySTMAddress, bytes32 governanoceOperationSalt) public {
        initializeConfig();

        // TODO; refactor to use 0x02
        bytes memory secondBridgeData = abi.encodePacked(bytes1(0x01), abi.encode(config.stateTransitionProxy, gatewaySTMAddress));

        bytes32 l2TxHash = Utils.runGovernanceL1L2TwoBridgesTransaction(
            config.governance,
            governanoceOperationSalt,
            Utils.MAX_PRIORITY_TX_GAS,
            config.chainChainId,
            config.bridgehub,
            config.sharedBridgeProxy,
            config.stmDeploymentTracker,
            0,
            secondBridgeData
        );

        saveOutput(l2TxHash);
    }

    // TODO: maybe move into a separate script
    /// @dev Calling this function requires private key to the admin of the chain
    function migrateChainToGateway(
        address chainAdmin,
        uint256 chainId,
        bytes32 adminOperationSalt
    ) public {
        initializeConfig();

        // For now this is how it is going to be.
        // TODO: include it in the input
        address l2ChainAdmin = AddressAliasHelper.applyL1ToL2Alias(chainAdmin);

        bytes32 chainAssetId = IBridgehub(config.bridgehub).stmAssetIdFromChainId(chainId);

        bytes memory bridgehubData = abi.encode(BridgehubBurnSTMAssetData({
            chainId: chainId,
            stmData: abi.encode(l2ChainAdmin, config.gatewayDiamondCutData),
            chainData: abi.encode(IZkSyncHyperchain(IBridgehub(config.bridgehub).getHyperchain(chainId)).getProtocolVersion())
        }));

        // TODO: use constant for the 0x01
        bytes memory secondBridgeData = abi.encodePacked(bytes1(0x01), abi.encode(chainAssetId, bridgehubData));

        bytes32 l2TxHash = Utils.runAdminL1L2TwoBridgesTransaction(
            chainAdmin,
            Utils.MAX_PRIORITY_TX_GAS,
            config.chainChainId,
            config.bridgehub,
            config.sharedBridgeProxy,
            config.sharedBridgeProxy,
            0,
            secondBridgeData
        );

        saveOutput(l2TxHash);
    }

    // /// @dev The sender may not have any privileges
    // function deployGatewayContracts() public {
    //     L2ContractsBytecodes memory bytecodes = Utils.readL2ContractsBytecodes();

        
    //     GatewayFacets memory facets = deployGatewayFacets(bytecodes);
    //     address verifierAddress = deployGatewayVerifier(bytecodes);


    //     deployGatewayStateTransitionManager(bytecodes);


    //     // Deploy validator timelock

    // }

    // function deployGatewayFacets(L2ContractsBytecodes memory bytecodes) internal returns (GatewayFacets memory facets) {
    //     bytes[] memory emoptyDeps = new bytes[](0);
        
    //     // Deploy facets
    //     facets.adminFacet = Utils.deployThroughL1({
    //         bytecode: bytecodes.adminFacet,
    //         constructorargs: abi.encode(l1ChainId),
    //         create2salt: bytes32(0),
    //         l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
    //         factoryDeps: emoptyDeps, 
    //         chainId: config.chainChainId,
    //         bridgehubAddress: config.bridgehub,
    //         l1SharedBridgeProxy: config.sharedBridgeProxy
    //     });

    //     facets.mailboxFacet = Utils.deployThroughL1({
    //         bytecode: bytecodes.mailboxFacet,
    //         constructorargs: abi.encode(l1ChainId, config.eraChainId),
    //         create2salt: bytes32(0),
    //         l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
    //         factoryDeps: emoptyDeps, 
    //         chainId: config.chainChainId,
    //         bridgehubAddress: config.bridgehub,
    //         l1SharedBridgeProxy: config.sharedBridgeProxy
    //     });

    //     facets.executorFacet = Utils.deployThroughL1({
    //         bytecode: bytecodes.executorFacet,
    //         constructorargs: hex"",
    //         create2salt: bytes32(0),
    //         l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
    //         factoryDeps: emoptyDeps, 
    //         chainId: config.chainChainId,
    //         bridgehubAddress: config.bridgehub,
    //         l1SharedBridgeProxy: config.sharedBridgeProxy
    //     });

    //     facets.gettersFacet = Utils.deployThroughL1({
    //         bytecode: bytecodes.gettersFacet,
    //         constructorargs: hex"",
    //         create2salt: bytes32(0),
    //         l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
    //         factoryDeps: emoptyDeps, 
    //         chainId: config.chainChainId,
    //         bridgehubAddress: config.bridgehub,
    //         l1SharedBridgeProxy: config.sharedBridgeProxy
    //     });
    // }

    // function deployGatewayVerifier(L2ContractsBytecodes memory bytecodes) internal returns (address verifier) {
    //     bytes[] memory emoptyDeps = new bytes[](0);

    //     bytes bytecode;
    //     if (config.testnetVerifier) {
    //         bytecode = bytecodes.testnetVerifier;
    //     } else {
    //         bytecode = bytecodes.verifier;
    //     }

    //     verifier = Utils.deployThroughL1({
    //         bytecode: bytecode,
    //         constructorargs: hex"",
    //         create2salt: bytes32(0),
    //         l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
    //         factoryDeps: emoptyDeps, 
    //         chainId: config.chainChainId,
    //         bridgehubAddress: config.bridgehub,
    //         l1SharedBridgeProxy: config.sharedBridgeProxy
    //     });
    // }

    // function deployValidatorTimelock(L2ContractsBytecodes memory bytecodes) internal returns (address validatorTimelock) {
    //     bytes[] memory emoptyDeps = new bytes[](0);

    //     address aliasedGovernor = AddressAliasHelper.applyL1ToL2Alias(config.governance);

    //     validatorTimelock = Utils.deployThroughL1({
    //         bytecode: bytecodes.validatorTimelock,
    //         constructorargs: abi.encode(aliasedGovernor, 0, config.eraChainId),
    //         create2salt: bytes32(0),
    //         l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
    //         factoryDeps: emoptyDeps, 
    //         chainId: config.chainChainId,
    //         bridgehubAddress: config.bridgehub,
    //         l1SharedBridgeProxy: config.sharedBridgeProxy
    //     });
    // }

    // function deployGatewayStateTransitionManager(L2ContractsBytecodes memory bytecodes) internal {
    //     // 

    //     // Deploy stm implementation
    //     address stmImplAddress = Utils.deployThroughL1({
    //         bytecode: bytecodes.stateTransitionManager,
    //         constructorargs: L2_BRIDGEHUB_ADDRESS,
    //         create2salt: bytes32(0),
    //         l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
    //         factoryDeps,
    //         uint256 chainId,
    //         address bridgehubAddress,
    //         address l1SharedBridgeProxy
    //     })

    // }

    // function deployGatewayValidatorTimelock() internal {

    // }

    // function moveChainToGateway() public {
    //     IBridgehub bridgehub = IBridgehub(config.bridgehub);
    //     // IL1AssetRouter router = IL1AssetRouter(config.sharedBridgeProxy);
    //     Ownable ownable = Ownable(config.bridgehub);

    //     uint256 gasPrice = 10; //Utils.bytesToUint256(vm.rpc("eth_gasPrice", "[]"));
    //     uint256 l2GasLimit = 72000000;

    //     uint256 expectedCost = bridgehub.l2TransactionBaseCost(
    //         config.gatewayChainId,
    //         gasPrice,
    //         l2GasLimit,
    //         REQUIRED_L2_GAS_PRICE_PER_PUBDATA
    //     ) * 2;

    //     address newAdmin = ownable.owner();
    //     console.log("newAdmin", newAdmin);
    //     IZkSyncHyperchain chain = IZkSyncHyperchain(bridgehub.getHyperchain(config.chainChainId));
    //     console.log("chainAdmin", bridgehub.getHyperchain(config.chainChainId), chain.getAdmin());
    //     bytes32 stmAssetId = bridgehub.stmAssetIdFromChainId(config.chainChainId);
    //     bytes memory diamondCutData = config.diamondCutData; // todo replace with config.zkDiamondCutData;
    //     bytes memory stmData = abi.encode(newAdmin, diamondCutData);
    //     bytes memory chainData = abi.encode(chain.getProtocolVersion());
    //     BridgehubBurnSTMAssetData memory stmAssetData = BridgehubBurnSTMAssetData({
    //         chainId: config.chainChainId,
    //         stmData: stmData,
    //         chainData: chainData
    //     });
    //     bytes memory bridgehubData = abi.encode(stmAssetData);
    //     bytes memory routerData = bytes.concat(bytes1(0x01), abi.encode(stmAssetId, bridgehubData));

    //     vm.startBroadcast(chain.getAdmin());
    //     L2TransactionRequestTwoBridgesOuter memory request = L2TransactionRequestTwoBridgesOuter({
    //         chainId: config.gatewayChainId,
    //         mintValue: expectedCost,
    //         l2Value: 0,
    //         l2GasLimit: l2GasLimit,
    //         l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    //         refundRecipient: newAdmin,
    //         secondBridgeAddress: config.sharedBridgeProxy,
    //         secondBridgeValue: 0,
    //         secondBridgeCalldata: routerData
    //     });
    //     bridgehub.requestL2TransactionTwoBridges{value: expectedCost}(request);
    //     vm.stopBroadcast();
    //     console.log("Chain moved to Gateway");
    // }

    // function registerL2Contracts() public {
    //     IBridgehub bridgehub = IBridgehub(config.bridgehub);
    //     Ownable ownable = Ownable(config.stmDeploymentTracker);
    //     // IStateTransitionManager stm = IStateTransitionManager(config.stateTransitionProxy);

    //     uint256 gasPrice = 10;
    //     uint256 l2GasLimit = 72000000;

    //     uint256 expectedCost = bridgehub.l2TransactionBaseCost(
    //         config.chainChainId,
    //         gasPrice,
    //         l2GasLimit,
    //         REQUIRED_L2_GAS_PRICE_PER_PUBDATA
    //     ) * 2;
    //     bytes32 assetId = bridgehub.stmAssetIdFromChainId(config.chainChainId);
    //     bytes memory routerData = bytes.concat(bytes1(0x02), abi.encode(assetId, L2_BRIDGEHUB_ADDR));
    //     L2TransactionRequestTwoBridgesOuter
    //         memory assetRouterRegistrationRequest = L2TransactionRequestTwoBridgesOuter({
    //             chainId: config.chainChainId,
    //             mintValue: expectedCost,
    //             l2Value: 0,
    //             l2GasLimit: l2GasLimit,
    //             l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    //             refundRecipient: ownable.owner(),
    //             secondBridgeAddress: config.sharedBridgeProxy,
    //             secondBridgeValue: 0,
    //             secondBridgeCalldata: routerData
    //         });

    //     L2TransactionRequestTwoBridgesOuter memory bridehubRegistrationRequest = L2TransactionRequestTwoBridgesOuter({
    //         chainId: config.chainChainId,
    //         mintValue: expectedCost,
    //         l2Value: 0,
    //         l2GasLimit: l2GasLimit,
    //         l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    //         refundRecipient: ownable.owner(),
    //         secondBridgeAddress: config.stmDeploymentTracker,
    //         secondBridgeValue: 0,
    //         secondBridgeCalldata: bytes.concat(
    //             bytes1(0x01),
    //             abi.encode(config.stateTransitionProxy, config.stateTransitionProxy)
    //         )
    //     });
    //     vm.startBroadcast(ownable.owner());
    //     bridgehub.requestL2TransactionTwoBridges{value: expectedCost}(assetRouterRegistrationRequest);
    //     bridgehub.requestL2TransactionTwoBridges{value: expectedCost}(bridehubRegistrationRequest);
    //     vm.stopBroadcast();
    // }
}
