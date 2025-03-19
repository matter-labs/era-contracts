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
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {Utils, ADDRESS_ONE} from "./Utils.sol";
import {L2ContractsBytecodesLib} from "./L2ContractsBytecodesLib.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {L2SharedBridgeLegacy} from "contracts/bridge/L2SharedBridgeLegacy.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {L2LegacySharedBridgeTestHelper} from "./L2LegacySharedBridgeTestHelper.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {Call} from "contracts/governance/Common.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {Create2AndTransfer} from "./Create2AndTransfer.sol";

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
    address l1Erc20Bridge;
    bool initializeLegacyBridge;
    address governance;
    address create2FactoryAddress;
    bytes32 create2Salt;
    bool allowEvmEmulator;
    address serverNotifierProxy;
}

contract RegisterZKChainScript is Script {
    using stdToml for string;

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
        runInner("/script-out/output-register-zk-chain.toml");
    }

    function runForTest() public {
        console.log("Deploying ZKChain");

        initializeConfigTest();
        runInner(vm.envString("ZK_CHAIN_OUT"));
    }

    function runInner(string memory outputPath) internal {
        string memory root = vm.projectRoot();

        outputPath = string.concat(root, outputPath);

        if (config.initializeLegacyBridge) {
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

        if (config.initializeLegacyBridge) {
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
        config.l1Erc20Bridge = toml.readAddress("$.deployed_addresses.bridges.erc20_bridge_proxy_addr");
        config.serverNotifierProxy = toml.readAddress("$.deployed_addresses.server_notifier_proxy_addr");

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
        config.initializeLegacyBridge = toml.readBool("$.initialize_legacy_bridge");

        config.governance = toml.readAddress("$.governance");
        config.create2FactoryAddress = toml.readAddress("$.create2_factory_address");
        config.create2Salt = toml.readBytes32("$.create2_salt");
        config.allowEvmEmulator = toml.readBool("$.chain.allow_evm_emulator");
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
        config.serverNotifierProxy = toml.readAddress("$.deployed_addresses.server_notifier_proxy_addr");

        config.diamondCutData = toml.readBytes("$.contracts_config.diamond_cut_data");
        config.forceDeployments = toml.readBytes("$.contracts_config.force_deployments_data");

        config.governance = toml.readAddress("$.deployed_addresses.governance_addr");
        config.create2FactoryAddress = toml.readAddress("$.create2_factory_addr");
        config.create2Salt = toml.readBytes32("$.create2_factory_salt");

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
        config.allowEvmEmulator = toml.readBool("$.chain.allow_evm_emulator");
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
        // Ecosystem governance is the owner of the L1Nullifier
        address ecosystemGovernance = L1NullifierDev(config.l1Nullifier).owner();
        address bridgeAddress = L2LegacySharedBridgeTestHelper.calculateL2LegacySharedBridgeProxyAddr(
            config.l1Erc20Bridge,
            config.l1Nullifier,
            ecosystemGovernance
        );
        vm.broadcast();
        L1NullifierDev(config.l1Nullifier).setL2LegacySharedBridge(config.chainChainId, bridgeAddress);
    }

    function registerAssetIdOnBridgehub() internal {
        IBridgehub bridgehub = IBridgehub(config.bridgehub);
        ChainAdminOwnable admin = ChainAdminOwnable(payable(bridgehub.admin()));
        INativeTokenVault ntv = INativeTokenVault(config.nativeTokenVault);
        bytes32 baseTokenAssetId = ntv.assetId(config.baseToken);
        uint256 baseTokenOriginChain = ntv.originChainId(baseTokenAssetId);

        if (baseTokenAssetId == bytes32(0)) {
            baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, config.baseToken);
        }

        if (bridgehub.assetIdIsRegistered(baseTokenAssetId)) {
            console.log("Base token asset id already registered on Bridgehub");
        } else {
            IChainAdminOwnable.Call[] memory calls = new IChainAdminOwnable.Call[](1);
            calls[0] = IChainAdminOwnable.Call({
                target: config.bridgehub,
                value: 0,
                data: abi.encodeCall(bridgehub.addTokenAssetId, (baseTokenAssetId))
            });
            vm.broadcast(admin.owner());
            admin.multicall(calls, true);

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
        bytes memory input = abi.encode(
            config.ownerAddress,
            config.governanceSecurityCouncilAddress,
            config.governanceMinDelay
        );
        address governance = Utils.deployViaCreate2(
            abi.encodePacked(type(Governance).creationCode, input),
            config.create2Salt,
            config.create2FactoryAddress
        );
        console.log("Governance deployed at:", governance);
        output.governance = governance;
    }

    function deployChainAdmin() internal {
        // TODO(EVM-924): provide an option to deploy a non-single owner ChainAdmin.
        (address chainAdmin, address accessControlRestriction) = deployChainAdminOwnable();

        output.accessControlRestrictionAddress = accessControlRestriction;
        output.chainAdmin = chainAdmin;
    }

    function deployChainAdminOwnable() internal returns (address chainAdmin, address accessControlRestriction) {
        chainAdmin = Utils.deployViaCreate2(
            abi.encodePacked(type(ChainAdminOwnable).creationCode, abi.encode(config.ownerAddress, address(0))),
            config.create2Salt,
            config.create2FactoryAddress
        );
        // The single owner chainAdmin does not have a separate control restriction contract.
        // We set to it to zero explicitly so that it is clear to the reader.
        accessControlRestriction = address(0);

        console.log("ChainAdminOwnable deployed at:", accessControlRestriction);
    }

    // TODO(EVM-924): this function is unused
    function deployChainAdminWithRestrictions()
        internal
        returns (address chainAdmin, address accessControlRestriction)
    {
        bytes memory input = abi.encode(0, config.ownerAddress);
        accessControlRestriction = Utils.deployViaCreate2(
            abi.encodePacked(type(AccessControlRestriction).creationCode, input),
            config.create2Salt,
            config.create2FactoryAddress
        );

        address[] memory restrictions = new address[](1);
        restrictions[0] = accessControlRestriction;

        input = abi.encode(restrictions);
        chainAdmin = Utils.deployViaCreate2(
            abi.encodePacked(type(ChainAdmin).creationCode, input),
            config.create2Salt,
            config.create2FactoryAddress
        );
    }

    function registerZKChain() internal {
        IBridgehub bridgehub = IBridgehub(config.bridgehub);
        ChainAdminOwnable admin = ChainAdminOwnable(payable(bridgehub.admin()));

        IChainAdminOwnable.Call[] memory calls = new IChainAdminOwnable.Call[](1);
        calls[0] = IChainAdminOwnable.Call({
            target: config.bridgehub,
            value: 0,
            data: abi.encodeCall(
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
            )
        });
        vm.broadcast(admin.owner());
        admin.multicall(calls, true);
        console.log("ZK chain registered");

        // Get new diamond proxy address from emitted events
        address diamondProxyAddress = bridgehub.getZKChain(config.chainChainId);
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
        bytes memory input = abi.encode(type(ProxyAdmin).creationCode, config.create2Salt, output.chainAdmin);
        bytes memory encoded = abi.encodePacked(type(Create2AndTransfer).creationCode, input);
        address create2AndTransfer = Utils.deployViaCreate2(encoded, config.create2Salt, config.create2FactoryAddress);

        address proxyAdmin = vm.computeCreate2Address(config.create2Salt, keccak256(encoded), create2AndTransfer);

        console.log("Transparent Proxy Admin deployed at:", address(proxyAdmin));
        output.chainProxyAdmin = address(proxyAdmin);
    }

    function deployLegacySharedBridge() internal {
        bytes[] memory emptyDeps = new bytes[](0);
        address legacyBridgeImplAddr = Utils.deployThroughL1Deterministic({
            bytecode: L2ContractsBytecodesLib.readL2LegacySharedBridgeDevBytecode(),
            constructorargs: hex"",
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: emptyDeps,
            chainId: config.chainChainId,
            bridgehubAddress: config.bridgehub,
            l1SharedBridgeProxy: config.sharedBridgeProxy
        });

        output.l2LegacySharedBridge = Utils.deployThroughL1Deterministic({
            bytecode: L2ContractsBytecodesLib.readTransparentUpgradeableProxyBytecode(),
            constructorargs: L2LegacySharedBridgeTestHelper.getLegacySharedBridgeProxyConstructorParams(
                legacyBridgeImplAddr,
                config.l1Erc20Bridge,
                config.l1Nullifier,
                // Ecosystem governance is the owner of the L1Nullifier
                L1NullifierDev(config.l1Nullifier).owner()
            ),
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: emptyDeps,
            chainId: config.chainChainId,
            bridgehubAddress: config.bridgehub,
            l1SharedBridgeProxy: config.sharedBridgeProxy
        });
    }

    function getFactoryDeps() internal view returns (bytes[] memory) {
        bytes[] memory factoryDeps = new bytes[](4);
        factoryDeps[0] = L2ContractsBytecodesLib.readBeaconProxyBytecode();
        factoryDeps[1] = L2ContractsBytecodesLib.readStandardERC20Bytecode();
        factoryDeps[2] = L2ContractsBytecodesLib.readUpgradeableBeaconBytecode();
        factoryDeps[3] = L2ContractsBytecodesLib.readTransparentUpgradeableProxyBytecodeFromSystemContracts();
        return factoryDeps;
    }

    function saveOutput(string memory outputPath) internal {
        vm.serializeAddress("root", "diamond_proxy_addr", output.diamondProxy);
        vm.serializeAddress("root", "chain_admin_addr", output.chainAdmin);
        if (output.l2LegacySharedBridge != address(0)) {
            vm.serializeAddress("root", "l2_legacy_shared_bridge_addr", output.l2LegacySharedBridge);
        }
        vm.serializeAddress("root", "access_control_restriction_addr", output.accessControlRestrictionAddress);
        vm.serializeAddress("root", "chain_proxy_admin_addr", output.chainProxyAdmin);

        string memory toml = vm.serializeAddress("root", "governance_addr", output.governance);
        string memory root = vm.projectRoot();
        vm.writeToml(toml, outputPath);
        console.log("Output saved at:", outputPath);
    }

    function governanceExecuteCalls(bytes memory callsToExecute, address governanceAddr) internal {
        IGovernance governance = IGovernance(governanceAddr);
        Ownable2Step ownable = Ownable2Step(governanceAddr);

        Call[] memory calls = abi.decode(callsToExecute, (Call[]));

        IGovernance.Operation memory operation = IGovernance.Operation({
            calls: calls,
            predecessor: bytes32(0),
            salt: bytes32(0)
        });

        vm.startBroadcast(ownable.owner());
        governance.scheduleTransparent(operation, 0);
        // We assume that the total value is 0
        governance.execute{value: 0}(operation);
        vm.stopBroadcast();
    }
}
