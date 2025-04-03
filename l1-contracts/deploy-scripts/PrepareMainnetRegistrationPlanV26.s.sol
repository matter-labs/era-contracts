// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {L2SharedBridgeLegacy} from "contracts/bridge/L2SharedBridgeLegacy.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {Call} from "contracts/governance/Common.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

import {L2ContractsBytecodesLib} from "./L2ContractsBytecodesLib.sol";
import {L2LegacySharedBridgeTestHelper} from "./L2LegacySharedBridgeTestHelper.sol";
import {Create2AndTransfer} from "./Create2AndTransfer.sol";
import {Utils} from "./Utils.sol";

contract PrepareMainnetRegistrationPlanV26 is Script {
    using stdToml for string;

    address internal constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
    address internal constant DETERMINISTIC_CREATE2_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    enum DAValidatorType {
        Rollup,
        NoDA,
        Avail
    }

    struct Config {
        // Ecosystem config
        bytes diamondCutData;
        bytes forceDeployments;
        address bridgehub;
        address chainTypeManagerProxy;
        address validatorTimelock;
        address nativeTokenVault;
        address l1SharedBridgeProxy;
        address l1NullifierProxy;
        // Chain config
        uint256 chainId;
        bool validiumMode;
        DAValidatorType validatorType;
        address operator;
        address blobOperator;
        address tokenMultiplierSetter;
        address baseToken;
        uint128 baseTokenNominator;
        uint128 baseTokenDenominator;
        address chainAdmin;
        address tempChainAdminOwner;
        address finalChainAdminOwner;
        bytes32 create2Salt;
        // DA config
        address rollupL1DaValidator;
        address noDaValidiumL1Validator;
        address availL1DaValidator;
        // Derived
        address ecosystemAdmin;
        address ecosystemAdminOwner;
        bytes32 baseTokenAssetId;
        address expectedL2DAValidatorAddress;
    }

    struct Output {
        // L1 contracts
        address chainProxyAdmin;
        address diamondProxy;
        // L2 contracts
        address l2DAValidatorAddress;
        address l2Multicall3;
        address l2TimestampAsserter;
    }

    Config internal config;
    Output internal output;

    function run() public {
        initializeConfig();

        registerTokenOnNTV();
        registerZKChain();

        configureZKChain();
        deployL2Contracts();

        transferChainAdminOwnership();

        saveOutput();
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-prepare-mainnet-registration-plan.toml");
        string memory toml = vm.readFile(path);

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml

        // Ecosystem config
        config.diamondCutData = toml.readBytes("$.ecosystem.diamond_cut_data");
        config.forceDeployments = toml.readBytes("$.ecosystem.force_deployments_data");
        config.bridgehub = toml.readAddress("$.ecosystem.bridgehub_proxy_addr");
        config.chainTypeManagerProxy = toml.readAddress("$.ecosystem.chain_type_manager_proxy_addr");
        config.validatorTimelock = toml.readAddress("$.ecosystem.validator_timelock_addr");
        config.nativeTokenVault = toml.readAddress("$.ecosystem.native_token_vault_addr");
        config.l1SharedBridgeProxy = toml.readAddress("$.ecosystem.l1_shared_bridge_proxy_addr");
        config.l1NullifierProxy = toml.readAddress("$.ecosystem.l1_nullifier_proxy_addr");

        // Chain config
        config.chainId = toml.readUint("$.chain.chain_id");
        config.validiumMode = toml.readBool("$.chain.validium_mode");
        uint256 validatorTypeUint = toml.readUint("$.chain.da_validator_type");
        require(validatorTypeUint < 3, "Invalid DA validator type");
        config.validatorType = DAValidatorType(validatorTypeUint);
        config.operator = toml.readAddress("$.chain.operator");
        config.blobOperator = toml.readAddress("$.chain.blob_operator");
        config.tokenMultiplierSetter = toml.readAddress("$.chain.token_multiplier_setter");
        config.baseToken = toml.readAddress("$.chain.base_token_addr");
        config.baseTokenNominator = uint128(toml.readUint("$.chain.base_token_nominator"));
        config.baseTokenDenominator = uint128(toml.readUint("$.chain.base_token_denominator"));
        config.chainAdmin = toml.readAddress("$.chain.chain_admin_addr");
        config.tempChainAdminOwner = toml.readAddress("$.chain.temp_chain_admin_owner_addr");
        config.finalChainAdminOwner = toml.readAddress("$.chain.final_chain_admin_owner_addr");
        config.create2Salt = toml.readBytes32("$.chain.create2_factory_salt");

        // DA config
        config.rollupL1DaValidator = toml.readAddress("$.da.rollup_l1_da_validator_addr");
        config.noDaValidiumL1Validator = toml.readAddress("$.da.no_da_validium_l1_validator_addr");
        config.availL1DaValidator = toml.readAddress("$.da.avail_l1_da_validator_addr");

        // Checks
        require(config.chainAdmin != address(0), "Chain admin address is not set");
        require(
            (!config.validiumMode && config.validatorType == DAValidatorType.Rollup) ||
                (config.validiumMode && config.validatorType != DAValidatorType.Rollup),
            "Incompatible DA parameters"
        );
        checkTokenAddress();

        // Derive
        IBridgehub bridgehub = IBridgehub(config.bridgehub);
        ChainAdminOwnable ecosystemAdmin = ChainAdminOwnable(payable(bridgehub.admin()));
        config.ecosystemAdmin = address(ecosystemAdmin);
        config.ecosystemAdminOwner = ecosystemAdmin.owner();
        config.baseTokenAssetId = deriveBaseTokenAssetId();
        config.expectedL2DAValidatorAddress = calculateExpectedL2DAValidatorAddress();
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

    function deriveBaseTokenAssetId() internal view returns (bytes32) {
        INativeTokenVault ntv = INativeTokenVault(config.nativeTokenVault);
        bytes32 baseTokenAssetId = ntv.assetId(config.baseToken);
        // If it hasn't been registered already with ntv
        if (baseTokenAssetId == bytes32(0)) {
            baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, config.baseToken);
        }
        return baseTokenAssetId;
    }

    function registerTokenOnNTV() internal {
        INativeTokenVault ntv = INativeTokenVault(config.nativeTokenVault);
        if (ntv.tokenAddress(config.baseTokenAssetId) != address(0) || config.baseToken == ETH_TOKEN_ADDRESS) {
            console.log("Token already registered on NTV");
        } else {
            vm.broadcast();
            ntv.registerToken(config.baseToken);
            console.log("Token registered on NTV");
        }
    }

    function registerZKChain() internal {
        Bridgehub bridgehub = Bridgehub(config.bridgehub);
        ChainAdminOwnable admin = ChainAdminOwnable(payable(bridgehub.admin()));
        INativeTokenVault ntv = INativeTokenVault(config.nativeTokenVault);

        // Allocate space for all calls
        uint8 maxCalls = 2;
        IChainAdminOwnable.Call[] memory calls = new IChainAdminOwnable.Call[](maxCalls);

        // Add calls to the array
        uint8 numCalls = 0;
        // Register asset id on Bridgehub if it hasn't been registered yet
        if (!bridgehub.assetIdIsRegistered(config.baseTokenAssetId)) {
            calls[numCalls++] = prepareAddTokenAssetIdCall();
        }
        // Create new chain
        calls[numCalls++] = prepareCreateNewChainCall();

        // Reduce the array size to the actual number of calls
        assembly {
            mstore(calls, numCalls)
        }
        // Multicall to register token asset ID and create new chain
        vm.broadcast(admin.owner());
        admin.multicall(calls, true);
        console.log("ZK Chain registered");

        // Get new diamond proxy address from Bridgehub
        address diamondProxyAddress = bridgehub.getZKChain(config.chainId);
        if (diamondProxyAddress == address(0)) {
            revert("Diamond Proxy address not found");
        }
        output.diamondProxy = diamondProxyAddress;
        console.log("Diamond Proxy deployed at:", diamondProxyAddress);
    }

    function prepareAddTokenAssetIdCall() internal view returns (IChainAdminOwnable.Call memory) {
        Bridgehub bridgehub = Bridgehub(config.bridgehub);
        return IChainAdminOwnable.Call({
            target: config.bridgehub,
            value: 0,
            data: abi.encodeCall(bridgehub.addTokenAssetId, (config.baseTokenAssetId))
        });
    }

    function prepareCreateNewChainCall() internal view returns (IChainAdminOwnable.Call memory) {
        Bridgehub bridgehub = Bridgehub(config.bridgehub);
        bytes memory data = abi.encodeCall(
            bridgehub.createNewChain,
            (
                config.chainId,
                config.chainTypeManagerProxy,
                config.baseTokenAssetId,
                0,  // salt (unused)
                config.chainAdmin,
                abi.encode(config.diamondCutData, config.forceDeployments),
                getFactoryDeps()
            )
        );
        return IChainAdminOwnable.Call({target: config.bridgehub, value: 0, data: data});
    }

    function configureZKChain() internal {
        ValidatorTimelock validatorTimelock = ValidatorTimelock(config.validatorTimelock);
        IZKChain zkChain = IZKChain(output.diamondProxy);
        ChainAdminOwnable chainAdmin = ChainAdminOwnable(payable(config.chainAdmin));

        // Allocate space for all calls
        uint8 maxCalls = 5;
        IChainAdminOwnable.Call[] memory calls = new IChainAdminOwnable.Call[](maxCalls);

        // Add calls to the array
        uint8 numCalls = 0;

        // Set operator
        calls[numCalls++] = IChainAdminOwnable.Call({
            target: config.validatorTimelock,
            value: 0,
            data: abi.encodeCall(validatorTimelock.addValidator, (config.chainId, config.operator))
        });
        // Set blob operator
        calls[numCalls++] = IChainAdminOwnable.Call({
            target: config.validatorTimelock,
            value: 0,
            data: abi.encodeCall(validatorTimelock.addValidator, (config.chainId, config.blobOperator))
        });

        // Set token multipliers
        calls[numCalls++] = IChainAdminOwnable.Call({
            target: output.diamondProxy,
            value: 0,
            data: abi.encodeCall(
                zkChain.setTokenMultiplier,
                (config.baseTokenNominator, config.baseTokenDenominator)
            )
        });

        // Set pubdata mode
        if (config.validiumMode) {
            PubdataPricingMode mode = PubdataPricingMode.Validium;
            calls[numCalls++] = IChainAdminOwnable.Call({
                target: address(output.diamondProxy),
                value: 0,
                data: abi.encodeCall(zkChain.setPubdataPricingMode, (mode))
            });
        }

        // Set DA validator pair
        address l1DaValidator = getL1DAValidator();
        address l2DaValidator = config.expectedL2DAValidatorAddress;
        calls[numCalls++] = IChainAdminOwnable.Call({
            target: address(output.diamondProxy),
            value: 0,
            data: abi.encodeCall(zkChain.setDAValidatorPair, (l1DaValidator, l2DaValidator))
        });

        // Reduce the array size to the actual number of calls
        assembly {
            mstore(calls, numCalls)
        }
        // Multicall to configure new chain
        vm.broadcast(chainAdmin.owner());
        chainAdmin.multicall(calls, true);

        // Set token multiplier setter
        if (config.baseToken != ADDRESS_ONE && chainAdmin.tokenMultiplierSetter() != config.tokenMultiplierSetter) {
            vm.broadcast(chainAdmin.owner());
            chainAdmin.setTokenMultiplierSetter(config.tokenMultiplierSetter);
        }
    }

    function getL1DAValidator() internal view returns (address) {
        if (config.validatorType == DAValidatorType.Rollup) {
            return config.rollupL1DaValidator;
        } else if (config.validatorType == DAValidatorType.NoDA) {
            return config.noDaValidiumL1Validator;
        } else {
            return config.availL1DaValidator;
        }
    }

    function transferChainAdminOwnership() internal {
        ChainAdminOwnable chainAdmin = ChainAdminOwnable(payable(config.chainAdmin));
        if (chainAdmin.owner() == config.finalChainAdminOwner) {
            return;
        }

        // Transfer ownership to new owner
        vm.broadcast(chainAdmin.owner());
        chainAdmin.transferOwnership(config.finalChainAdminOwner);

        // Accept ownership of ChainAdmin
        vm.broadcast(config.finalChainAdminOwner);
        chainAdmin.acceptOwnership();
        console.log("ChainAdmin owner for ", config.chainAdmin, " set to ", config.finalChainAdminOwner);
    }


    function deployL2Contracts() internal {
        // Note, that it is important that the first transaction is for setting the L2 DA validator
        deployL2DaValidator();
        deployMulticall3();
        deployTimestampAsserter();
    }

    function getL2DAValidatorBytecode() internal view returns (bytes memory bytecode) {
        if (config.validatorType == DAValidatorType.Rollup) {
            bytecode = L2ContractsBytecodesLib.readRollupL2DAValidatorBytecode();
        } else if (config.validatorType == DAValidatorType.NoDA) {
            bytecode = L2ContractsBytecodesLib.readNoDAL2DAValidatorBytecode();
        } else if (config.validatorType == DAValidatorType.Avail) {
            bytecode = L2ContractsBytecodesLib.readAvailL2DAValidatorBytecode();
        } else {
            revert("Invalid DA validator type");
        }
    }

    function calculateExpectedL2DAValidatorAddress() internal view returns (address) {
        bytes memory bytecode = getL2DAValidatorBytecode();
        (bytes32 bytecodeHash, bytes memory deployData) = Utils.getDeploymentCalldata("", bytecode, "");
        return Utils.getL2AddressViaCreate2Factory("", bytecodeHash, "");
    }

    function deployL2DaValidator() internal {
        bytes memory bytecode = getL2DAValidatorBytecode();
        output.l2DAValidatorAddress = Utils.deployThroughL1Deterministic({
            bytecode: bytecode,
            constructorargs: bytes(""),
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            chainId: config.chainId,
            bridgehubAddress: config.bridgehub,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
        require(config.expectedL2DAValidatorAddress == output.l2DAValidatorAddress, "L2 DA Validator address mismatch");
        console.log("L2 DA Validator deployed at:", output.l2DAValidatorAddress);
    }

    function deployMulticall3() internal {
        output.l2Multicall3 = Utils.deployThroughL1Deterministic({
            bytecode: L2ContractsBytecodesLib.readMulticall3Bytecode(),
            constructorargs: "",
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            chainId: config.chainId,
            bridgehubAddress: config.bridgehub,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
        console.log("Multicall3 deployed at:", output.l2Multicall3);
    }

    function deployTimestampAsserter() internal {
        output.l2TimestampAsserter = Utils.deployThroughL1Deterministic({
            bytecode: L2ContractsBytecodesLib.readTimestampAsserterBytecode(),
            constructorargs: "",
            create2salt: "",
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            chainId: config.chainId,
            bridgehubAddress: config.bridgehub,
            l1SharedBridgeProxy: config.l1SharedBridgeProxy
        });
        console.log("TimestampAsserter deployed at:", output.l2TimestampAsserter);
    }

    function getFactoryDeps() internal view returns (bytes[] memory) {
        bytes[] memory factoryDeps = new bytes[](4);
        factoryDeps[0] = L2ContractsBytecodesLib.readBeaconProxyBytecode();
        factoryDeps[1] = L2ContractsBytecodesLib.readStandardERC20Bytecode();
        factoryDeps[2] = L2ContractsBytecodesLib.readUpgradeableBeaconBytecode();
        factoryDeps[3] = L2ContractsBytecodesLib.readTransparentUpgradeableProxyBytecodeFromSystemContracts();
        return factoryDeps;
    }

    function saveOutput() internal {
        // L1 contracts:
        vm.serializeAddress("root", "chain_admin_addr", config.chainAdmin);
        vm.serializeAddress("root", "chain_proxy_admin_addr", output.chainProxyAdmin);
        vm.serializeAddress("root", "diamond_proxy_addr", output.diamondProxy);
        // L2 contracts:
        vm.serializeAddress("root", "l2_da_validator_addr", output.l2DAValidatorAddress);
        vm.serializeAddress("root", "l2_multicall3_addr", output.l2Multicall3);
        string memory toml = vm.serializeAddress("root", "l2_timestamp_asserter_addr", output.l2TimestampAsserter);

        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-prepare-mainnet-registration-plan.toml");
        vm.writeToml(toml, path);
    }
}
