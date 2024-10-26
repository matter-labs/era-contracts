// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {Utils} from "./Utils.sol";
import {L2ContractsBytecodesLib} from "./L2ContractsBytecodesLib.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {L2SharedBridgeLegacy} from "contracts/bridge/L2SharedBridgeLegacy.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

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
    bytes32 baseTokenAssetId;
    uint128 baseTokenGasPriceMultiplierNominator;
    uint128 baseTokenGasPriceMultiplierDenominator;
    address bridgehub;
    // TODO(EVM-744): maybe rename to asset router
    address sharedBridgeProxy;
    address nativeTokenVault;
    address chainTypeManagerProxy;
    address validatorTimelock;
    bytes diamondCutData;
    bytes forceDeployments;
    address governanceSecurityCouncilAddress;
    uint256 governanceMinDelay;
    address l1Nullifier;
}

contract RegisterZKChainScript is Script {
    using stdToml for string;

    address internal constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
    bytes32 internal constant STATE_TRANSITION_NEW_CHAIN_HASH = keccak256("NewZKChain(uint256,address)");

    struct Output {
        address governance;
        address diamondProxy;
        address chainAdmin;
        address l2LegacySharedBridge;
        address accessControlRestrictionAddress;
        address chainProxyAdmin;
    }

    struct LegacySharedBridgeParams {
        bytes implementationConstructorParams;
        address implementationAddress;
        bytes proxyConstructorParams;
        address proxyAddress;
    }

    LegacySharedBridgeParams internal legacySharedBridgeParams;

    Config internal config;
    Output internal output;

    function run() public {
        console.log("Deploying ZKChain");

        initializeConfig();
        // TODO: some chains may not want to have a legacy shared bridge
        runInner("/script-out/output-register-zk-chain.toml", false);
    }

    function runForTest() public {
        console.log("Deploying ZKChain");

        initializeConfigTest();
        // TODO: Yes, it is the same as for prod since it is never read from down the line
        runInner(vm.envString("ZK_CHAIN_OUT"), false);
    }

    function runInner(string memory outputPath, bool initializeL2LegacyBridge) internal {
        string memory root = vm.projectRoot();
        outputPath = string.concat(root, outputPath);

        if (initializeL2LegacyBridge) {
            // This must be run before the chain is deployed
            setUpLegacySharedBridgeParams();
        }

        deployGovernance();
        deployChainAdmin();
        deployChainProxyAddress();
        checkTokenAddress();
        registerAssetIdOnBridgehub();
        registerTokenOnNTV();
        registerZKChain();
        addValidators();
        configureZkSyncStateTransition();
        setPendingAdmin();

        if (initializeL2LegacyBridge) {
            deployLegacySharedBridge();
        }

        saveOutput(outputPath);
    }

    function initializeConfig() internal {
        // Grab config from output of l1 deployment
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/register-zk-chain.toml");
        string memory toml = vm.readFile(path);

        config.deployerAddress = msg.sender;

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml

        config.bridgehub = toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr");
        config.chainTypeManagerProxy = toml.readAddress(
            "$.deployed_addresses.state_transition.chain_type_manager_proxy_addr"
        );
        config.validatorTimelock = toml.readAddress("$.deployed_addresses.validator_timelock_addr");
        // config.bridgehubGovernance = toml.readAddress("$.deployed_addresses.governance_addr");
        config.nativeTokenVault = toml.readAddress("$.deployed_addresses.native_token_vault_addr");
        config.sharedBridgeProxy = toml.readAddress("$.deployed_addresses.bridges.shared_bridge_proxy_addr");
        config.l1Nullifier = toml.readAddress("$.deployed_addresses.bridges.l1_nullifier_proxy_addr");

        config.diamondCutData = toml.readBytes("$.contracts_config.diamond_cut_data");
        config.forceDeployments = toml.readBytes("$.contracts_config.force_deployments_data");

        config.ownerAddress = toml.readAddress("$.owner_address");

        config.chainChainId = toml.readUint("$.chain.chain_chain_id");
        config.baseTokenGasPriceMultiplierNominator = uint128(
            toml.readUint("$.chain.base_token_gas_price_multiplier_nominator")
        );
        config.baseTokenGasPriceMultiplierDenominator = uint128(
            toml.readUint("$.chain.base_token_gas_price_multiplier_denominator")
        );
        config.baseToken = toml.readAddress("$.chain.base_token_addr");
        config.governanceSecurityCouncilAddress = toml.readAddress("$.chain.governance_security_council_address");
        config.governanceMinDelay = uint256(toml.readUint("$.chain.governance_min_delay"));
        config.bridgehubCreateNewChainSalt = toml.readUint("$.chain.bridgehub_create_new_chain_salt");
        config.validiumMode = toml.readBool("$.chain.validium_mode");
        config.validatorSenderOperatorCommitEth = toml.readAddress("$.chain.validator_sender_operator_commit_eth");
        config.validatorSenderOperatorBlobsEth = toml.readAddress("$.chain.validator_sender_operator_blobs_eth");
    }

    function getConfig() public view returns (Config memory) {
        return config;
    }

    function initializeConfigTest() internal {
        // Grab config from output of l1 deployment
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, vm.envString("L1_OUTPUT")); //"/script-config/register-zkChain.toml");
        string memory toml = vm.readFile(path);

        config.deployerAddress = msg.sender;

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml

        config.bridgehub = toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr");
        // TODO(EVM-744): name of the key is a bit inconsistent
        config.chainTypeManagerProxy = toml.readAddress(
            "$.deployed_addresses.state_transition.state_transition_proxy_addr"
        );
        config.validatorTimelock = toml.readAddress("$.deployed_addresses.validator_timelock_addr");
        // config.bridgehubGovernance = toml.readAddress("$.deployed_addresses.governance_addr");
        config.nativeTokenVault = toml.readAddress("$.deployed_addresses.native_token_vault_addr");
        config.sharedBridgeProxy = toml.readAddress("$.deployed_addresses.bridges.shared_bridge_proxy_addr");
        config.l1Nullifier = toml.readAddress("$.deployed_addresses.bridges.l1_nullifier_proxy_addr");

        config.diamondCutData = toml.readBytes("$.contracts_config.diamond_cut_data");
        config.forceDeployments = toml.readBytes("$.contracts_config.force_deployments_data");

        path = string.concat(root, vm.envString("ZK_CHAIN_CONFIG"));
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
    }

    function getOwnerAddress() public view returns (address) {
        return config.ownerAddress;
    }

    function checkTokenAddress() internal view {
        if (config.baseToken == address(0)) {
            revert("Token address is not set");
        }

        // Check if it's ethereum address
        if (config.baseToken == ADDRESS_ONE) {
            return;
        }

        if (config.baseToken.code.length == 0) {
            revert("Token address is not a contract address");
        }

        console.log("Using base token address:", config.baseToken);
    }

    function setUpLegacySharedBridgeParams() internal {
        bytes memory implementationConstructorParams = hex"";

        address legacyBridgeImplementationAddress = L2ContractHelper.computeCreate2Address(
            msg.sender,
            "",
            L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readL2LegacySharedBridgeBytecode()),
            keccak256(implementationConstructorParams)
        );

        bytes memory proxyInitializationParams = abi.encodeCall(
            L2SharedBridgeLegacy.initialize,
            (
                config.sharedBridgeProxy,
                L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readBeaconProxyBytecode()),
                // This is not exactly correct, this should be ecosystem governance and not chain governance
                msg.sender
            )
        );

        bytes memory proxyConstructorParams = abi.encode(
            legacyBridgeImplementationAddress,
            // In real production, this would be aliased ecosystem governance.
            // But in real production we also do not initialize legacy shared bridge
            msg.sender,
            proxyInitializationParams
        );

        address proxyAddress = L2ContractHelper.computeCreate2Address(
            msg.sender,
            "",
            L2ContractHelper.hashL2Bytecode(L2ContractsBytecodesLib.readTransparentUpgradeableProxyBytecode()),
            keccak256(proxyConstructorParams)
        );

        vm.broadcast();
        L1NullifierDev(config.l1Nullifier).setL2LegacySharedBridge(config.chainChainId, proxyAddress);

        legacySharedBridgeParams = LegacySharedBridgeParams({
            implementationConstructorParams: implementationConstructorParams,
            implementationAddress: legacyBridgeImplementationAddress,
            proxyConstructorParams: proxyConstructorParams,
            proxyAddress: proxyAddress
        });
    }

    function registerAssetIdOnBridgehub() internal {
        IBridgehub bridgehub = IBridgehub(config.bridgehub);
        Ownable ownable = Ownable(config.bridgehub);
        INativeTokenVault ntv = INativeTokenVault(config.nativeTokenVault);
        bytes32 baseTokenAssetId = ntv.assetId(config.baseToken);
        uint256 baseTokenOriginChain = ntv.originChainId(baseTokenAssetId);

        if (baseTokenAssetId == bytes32(0)) {
            baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, config.baseToken);
        }

        if (bridgehub.assetIdIsRegistered(baseTokenAssetId)) {
            console.log("Base token asset id already registered on Bridgehub");
        } else {
            bytes memory data = abi.encodeCall(bridgehub.addTokenAssetId, (baseTokenAssetId));
            Utils.executeUpgrade({
                _governor: ownable.owner(),
                _salt: bytes32(config.bridgehubCreateNewChainSalt),
                _target: config.bridgehub,
                _data: data,
                _value: 0,
                _delay: 0
            });
            console.log("Base token asset id registered on Bridgehub");
        }
    }

    function registerTokenOnNTV() internal {
        INativeTokenVault ntv = INativeTokenVault(config.nativeTokenVault);
        bytes32 baseTokenAssetId = ntv.assetId(config.baseToken);
        uint256 baseTokenOriginChain = ntv.originChainId(baseTokenAssetId);

        // If it hasn't been registered already with ntv
        if (baseTokenAssetId == bytes32(0)) {
            baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, config.baseToken);
        }
        config.baseTokenAssetId = baseTokenAssetId;
        if (ntv.tokenAddress(baseTokenAssetId) != address(0) || config.baseToken == ETH_TOKEN_ADDRESS) {
            console.log("Token already registered on NTV");
        } else {
            vm.broadcast();
            ntv.registerToken(config.baseToken);
            console.log("Token registered on NTV");
        }
    }

    function deployGovernance() internal {
        vm.broadcast();
        Governance governance = new Governance(
            config.ownerAddress,
            config.governanceSecurityCouncilAddress,
            config.governanceMinDelay
        );
        console.log("Governance deployed at:", address(governance));
        output.governance = address(governance);
    }

    function deployChainAdmin() internal {
        vm.broadcast();
        AccessControlRestriction restriction = new AccessControlRestriction(0, config.ownerAddress);
        output.accessControlRestrictionAddress = address(restriction);

        address[] memory restrictions = new address[](1);
        restrictions[0] = address(restriction);

        vm.broadcast();
        ChainAdmin chainAdmin = new ChainAdmin(restrictions);
        output.chainAdmin = address(chainAdmin);
    }

    function registerZKChain() internal {
        IBridgehub bridgehub = IBridgehub(config.bridgehub);
        Ownable ownable = Ownable(config.bridgehub);

        vm.recordLogs();
        bytes memory data = abi.encodeCall(
            bridgehub.createNewChain,
            (
                config.chainChainId,
                config.chainTypeManagerProxy,
                config.baseTokenAssetId,
                config.bridgehubCreateNewChainSalt,
                msg.sender,
                abi.encode(config.diamondCutData, config.forceDeployments),
                getFactoryDeps()
            )
        );
        Utils.executeUpgrade({
            _governor: ownable.owner(),
            _salt: bytes32(config.bridgehubCreateNewChainSalt),
            _target: config.bridgehub,
            _data: data,
            _value: 0,
            _delay: 0
        });
        console.log("ZK chain registered");

        // Get new diamond proxy address from emitted events
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address diamondProxyAddress;
        uint256 logsLength = logs.length;
        for (uint256 i = 0; i < logsLength; ++i) {
            if (logs[i].topics[0] == STATE_TRANSITION_NEW_CHAIN_HASH) {
                diamondProxyAddress = address(uint160(uint256(logs[i].topics[2])));
                break;
            }
        }
        if (diamondProxyAddress == address(0)) {
            revert("Diamond proxy address not found");
        }
        output.diamondProxy = diamondProxyAddress;
        console.log("ZKChain diamond proxy deployed at:", diamondProxyAddress);
    }

    function addValidators() internal {
        ValidatorTimelock validatorTimelock = ValidatorTimelock(config.validatorTimelock);

        vm.startBroadcast(msg.sender);
        validatorTimelock.addValidator(config.chainChainId, config.validatorSenderOperatorCommitEth);
        validatorTimelock.addValidator(config.chainChainId, config.validatorSenderOperatorBlobsEth);
        vm.stopBroadcast();

        console.log("Validators added");
    }

    function configureZkSyncStateTransition() internal {
        IZKChain zkChain = IZKChain(output.diamondProxy);

        vm.startBroadcast(msg.sender);
        zkChain.setTokenMultiplier(
            config.baseTokenGasPriceMultiplierNominator,
            config.baseTokenGasPriceMultiplierDenominator
        );

        if (config.validiumMode) {
            zkChain.setPubdataPricingMode(PubdataPricingMode.Validium);
        }

        vm.stopBroadcast();
        console.log("ZkSync State Transition configured");
    }

    function setPendingAdmin() internal {
        IZKChain zkChain = IZKChain(output.diamondProxy);

        vm.startBroadcast(msg.sender);
        zkChain.setPendingAdmin(output.chainAdmin);
        vm.stopBroadcast();
        console.log("Owner for ", output.diamondProxy, "set to", output.chainAdmin);
    }

    function deployChainProxyAddress() internal {
        vm.startBroadcast();
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        proxyAdmin.transferOwnership(output.chainAdmin);
        vm.stopBroadcast();
        console.log("Transparent Proxy Admin deployed at:", address(proxyAdmin));
        output.chainProxyAdmin = address(proxyAdmin);
    }

    function deployLegacySharedBridge() internal {
        bytes[] memory emptyDeps = new bytes[](0);
        address correctLegacyBridgeImplAddr = Utils.deployThroughL1({
            bytecode: L2ContractsBytecodesLib.readL2LegacySharedBridgeBytecode(),
            constructorargs: legacySharedBridgeParams.implementationConstructorParams,
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: emptyDeps,
            chainId: config.chainChainId,
            bridgehubAddress: config.bridgehub,
            l1SharedBridgeProxy: config.sharedBridgeProxy
        });

        address correctProxyAddress = Utils.deployThroughL1({
            bytecode: L2ContractsBytecodesLib.readTransparentUpgradeableProxyBytecode(),
            constructorargs: legacySharedBridgeParams.proxyConstructorParams,
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: emptyDeps,
            chainId: config.chainChainId,
            bridgehubAddress: config.bridgehub,
            l1SharedBridgeProxy: config.sharedBridgeProxy
        });

        require(
            correctLegacyBridgeImplAddr == legacySharedBridgeParams.implementationAddress,
            "Legacy bridge implementation address mismatch"
        );
        require(correctProxyAddress == legacySharedBridgeParams.proxyAddress, "Legacy bridge proxy address mismatch");

        output.l2LegacySharedBridge = correctProxyAddress;
    }

    function getFactoryDeps() internal view returns (bytes[] memory) {
        bytes[] memory factoryDeps = new bytes[](3);
        factoryDeps[0] = L2ContractsBytecodesLib.readBeaconProxyBytecode();
        factoryDeps[1] = L2ContractsBytecodesLib.readStandardERC20Bytecode();
        factoryDeps[2] = L2ContractsBytecodesLib.readUpgradeableBeaconBytecode();
        return factoryDeps;
    }

    function saveOutput(string memory outputPath) internal {
        vm.serializeAddress("root", "diamond_proxy_addr", output.diamondProxy);
        vm.serializeAddress("root", "chain_admin_addr", output.chainAdmin);
        vm.serializeAddress("root", "l2_legacy_shared_bridge_addr", output.l2LegacySharedBridge);
        vm.serializeAddress("root", "access_control_restriction_addr", output.accessControlRestrictionAddress);
        vm.serializeAddress("root", "chain_proxy_admin_addr", output.chainProxyAdmin);

        string memory toml = vm.serializeAddress("root", "governance_addr", output.governance);
        string memory root = vm.projectRoot();
        vm.writeToml(toml, outputPath);
        console.log("Output saved at:", outputPath);
    }
}
