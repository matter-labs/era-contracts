// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

import {ContractsBytecodesLib} from "./ContractsBytecodesLib.sol";
import {Utils} from "./Utils.sol";

contract PrepareChainRegistrationPlan is Script {
    using stdToml for string;

    address internal constant DETERMINISTIC_CREATE2_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint8 internal constant MAX_MULTICALL_CALLS = 20;

    enum DAValidatorType {
        Rollup,
        NoDA,
        Avail
    }

    struct Input {
        // Ecosystem config
        address bridgehub;
        address chainTypeManager;
        bytes diamondCutData;
        bytes forceDeploymentsData;
        // Chain config
        uint256 chainId;
        DAValidatorType daValidatorType;
        bool isPermanentRollup;
        address[] operators;
        address tokenMultiplierSetter;
        address baseToken;
        uint128 baseTokenNominator;
        uint128 baseTokenDenominator;
        address tempChainAdminOwner;
        address finalChainAdminOwner;
        address chainAdmin;
        bytes32 chainAdminSalt;
        // DA config
        address rollupL1DaValidator;
        address noDaValidiumL1Validator;
        address availL1DaValidator;
    }

    struct Derived {
        address nativeTokenVault;
        address assetRouter;
        address validatorTimelock;
        address ecosystemAdmin;
        address ecosystemAdminOwner;
        bytes32 baseTokenAssetId;
        address expectedL2DAValidatorAddress;
    }

    struct Output {
        // L1 contracts
        address chainAdmin;
        address diamondProxy;
    }

    Input internal input;
    Derived internal derived;
    Output internal output;

    function run() public {
        initialize();

        deployChainAdmin();

        registerTokenOnNTV();
        registerZKChain();
        configureZKChain();

        transferChainAdminOwnership();

        saveOutput();
    }

    function initialize() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-prepare-chain-registration-plan.toml");
        string memory toml = vm.readFile(path);

        // Ecosystem config
        input.bridgehub = toml.readAddress("$.ecosystem.bridgehub_proxy_addr");
        input.chainTypeManager = toml.readAddress("$.ecosystem.chain_type_manager_proxy_addr");
        input.diamondCutData = toml.readBytes("$.ecosystem.diamond_cut_data");
        input.forceDeploymentsData = toml.readBytes("$.ecosystem.force_deployments_data");

        // Chain config
        input.chainId = toml.readUint("$.chain.chain_id");
        input.daValidatorType = DAValidatorType(toml.readUint("$.chain.da_validator_type"));
        input.isPermanentRollup = toml.readBool("$.chain.is_permanent_rollup");
        input.operators = toml.readAddressArray("$.chain.operator_addrs");
        input.tokenMultiplierSetter = toml.readAddress("$.chain.token_multiplier_setter_addr");
        input.baseToken = toml.readAddress("$.chain.base_token_addr");
        input.baseTokenNominator = uint128(toml.readUint("$.chain.base_token_nominator"));
        input.baseTokenDenominator = uint128(toml.readUint("$.chain.base_token_denominator"));
        input.chainAdmin = toml.readAddress("$.chain.chain_admin_addr");
        input.tempChainAdminOwner = toml.readAddress("$.chain.temp_chain_admin_owner_addr");
        input.finalChainAdminOwner = toml.readAddress("$.chain.final_chain_admin_owner_addr");
        if (vm.keyExistsToml(toml, "$.chain.chain_admin_salt")) {
            input.chainAdminSalt = toml.readBytes32("$.chain.chain_admin_salt");
        }

        // DA config
        input.rollupL1DaValidator = toml.readAddress("$.da.rollup_l1_da_validator_addr");
        input.noDaValidiumL1Validator = toml.readAddress("$.da.no_da_validium_l1_validator_addr");
        input.availL1DaValidator = toml.readAddress("$.da.avail_l1_da_validator_addr");

        // Validate inputs
        validateInputConfig();

        // Derive
        IBridgehub bridgehub = IBridgehub(input.bridgehub);
        ChainTypeManager ctm = ChainTypeManager(input.chainTypeManager);
        ChainAdminOwnable ecosystemAdmin = ChainAdminOwnable(payable(bridgehub.admin()));
        L1AssetRouter assetRouter = L1AssetRouter(bridgehub.assetRouter());
        derived.assetRouter = address(assetRouter);
        derived.nativeTokenVault = address(assetRouter.nativeTokenVault());
        derived.validatorTimelock = ctm.validatorTimelockPostV29();
        derived.ecosystemAdmin = address(ecosystemAdmin);
        derived.ecosystemAdminOwner = ecosystemAdmin.owner();
        derived.baseTokenAssetId = deriveBaseTokenAssetId();
        derived.expectedL2DAValidatorAddress = calculateExpectedL2DAValidatorAddress();
    }

    function validateInputConfig() internal view {
        require(!input.isPermanentRollup || input.daValidatorType == DAValidatorType.Rollup,
            "isPermanentRollup must be true only for rollup"
        );
        // Validate base token
        require(input.baseToken != address(0), "Base token address is not set");
        if (input.baseToken != ETH_TOKEN_ADDRESS && input.baseToken.code.length == 0) {
            revert("Base token address is not a contract");
        }
    }

    function deriveBaseTokenAssetId() internal view returns (bytes32) {
        INativeTokenVault ntv = INativeTokenVault(derived.nativeTokenVault);
        bytes32 baseTokenAssetId = ntv.assetId(input.baseToken);
        // If it hasn't been registered already with ntv
        if (baseTokenAssetId == bytes32(0)) {
            baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, input.baseToken);
        }
        return baseTokenAssetId;
    }

    function registerTokenOnNTV() internal {
        INativeTokenVault ntv = INativeTokenVault(derived.nativeTokenVault);
        if (ntv.tokenAddress(derived.baseTokenAssetId) != address(0) || input.baseToken == ETH_TOKEN_ADDRESS) {
            console.log("Base token already registered on NTV");
        } else {
            vm.broadcast(input.tempChainAdminOwner);
            ntv.registerToken(input.baseToken);
        }
        console.log("Base token asset ID:", vm.toString(derived.baseTokenAssetId));
    }

    function registerZKChain() internal {
        IBridgehub bridgehub = IBridgehub(input.bridgehub);
        ChainAdminOwnable ecosystemAdmin = ChainAdminOwnable(payable(bridgehub.admin()));
        INativeTokenVault ntv = INativeTokenVault(derived.nativeTokenVault);

        // Allocate space for all calls
        IChainAdminOwnable.Call[] memory calls = new IChainAdminOwnable.Call[](MAX_MULTICALL_CALLS);

        // Add calls to the array
        uint8 numCalls = 0;
        // Register asset id on Bridgehub if it hasn't been registered yet
        if (!bridgehub.assetIdIsRegistered(derived.baseTokenAssetId)) {
            calls[numCalls++] = prepareAddTokenAssetIdCall();
        }
        // Create new chain
        calls[numCalls++] = prepareCreateNewChainCall();

        // Reduce the array size to the actual number of calls
        assembly {
            mstore(calls, numCalls)
        }
        // Multicall to register token asset ID and create new chain
        vm.broadcast(ecosystemAdmin.owner());
        ecosystemAdmin.multicall(calls, true);

        // Get new diamond proxy address from Bridgehub
        address diamondProxyAddress = bridgehub.getZKChain(input.chainId);
        require(diamondProxyAddress != address(0), "Diamond Proxy address not found");
        output.diamondProxy = diamondProxyAddress;
        console.log("Diamond Proxy deployed at:", diamondProxyAddress);
    }

    function prepareAddTokenAssetIdCall() internal view returns (IChainAdminOwnable.Call memory) {
        IBridgehub bridgehub = IBridgehub(input.bridgehub);
        return
            IChainAdminOwnable.Call({
                target: input.bridgehub,
                value: 0,
                data: abi.encodeCall(bridgehub.addTokenAssetId, (derived.baseTokenAssetId))
            });
    }

    function prepareCreateNewChainCall() internal view returns (IChainAdminOwnable.Call memory) {
        IBridgehub bridgehub = IBridgehub(input.bridgehub);
        bytes memory data = abi.encodeCall(
            bridgehub.createNewChain,
            (
                input.chainId,
                input.chainTypeManager,
                derived.baseTokenAssetId,
                0, // salt (unused)
                output.chainAdmin,
                abi.encode(input.diamondCutData, input.forceDeploymentsData),
                getFactoryDeps()
            )
        );
        return IChainAdminOwnable.Call({target: input.bridgehub, value: 0, data: data});
    }

    function prepareAddValidatorCall(address _validator) internal view returns (IChainAdminOwnable.Call memory) {
        ValidatorTimelock validatorTimelock = ValidatorTimelock(derived.validatorTimelock);
        return IChainAdminOwnable.Call({
            target: derived.validatorTimelock,
            value: 0,
            data: abi.encodeCall(validatorTimelock.addValidatorForChainId, (input.chainId, _validator))
        });
    }

    function configureZKChain() internal {
        IZKChain zkChain = IZKChain(output.diamondProxy);
        ChainAdminOwnable chainAdmin = ChainAdminOwnable(payable(output.chainAdmin));

        // Allocate space for all calls
        IChainAdminOwnable.Call[] memory calls = new IChainAdminOwnable.Call[](MAX_MULTICALL_CALLS);

        // Add calls to the array
        uint8 numCalls = 0;

        // Add operators to the validator timelock
        for (uint256 i = 0; i < input.operators.length; i++) {
            calls[numCalls++] = prepareAddValidatorCall(input.operators[i]);
        }

        // Set token multipliers
        calls[numCalls++] = IChainAdminOwnable.Call({
            target: output.diamondProxy,
            value: 0,
            data: abi.encodeCall(zkChain.setTokenMultiplier, (input.baseTokenNominator, input.baseTokenDenominator))
        });

        // Set pubdata mode
        if (input.daValidatorType != DAValidatorType.Rollup) {
            PubdataPricingMode mode = PubdataPricingMode.Validium;
            calls[numCalls++] = IChainAdminOwnable.Call({
                target: address(output.diamondProxy),
                value: 0,
                data: abi.encodeCall(zkChain.setPubdataPricingMode, (mode))
            });
        }

        // Set DA validator pair
        address l1DaValidator = getL1DAValidator();
        address l2DaValidator = derived.expectedL2DAValidatorAddress;
        calls[numCalls++] = IChainAdminOwnable.Call({
            target: address(output.diamondProxy),
            value: 0,
            data: abi.encodeCall(zkChain.setDAValidatorPair, (l1DaValidator, l2DaValidator))
        });

        // Make permanent rollup
        if (input.isPermanentRollup) {
            calls[numCalls++] = IChainAdminOwnable.Call({
                target: address(output.diamondProxy),
                value: 0,
                data: abi.encodeCall(zkChain.makePermanentRollup, ())
            });
        }

        // Reduce the array size to the actual number of calls
        assembly {
            mstore(calls, numCalls)
        }
        // Multicall to configure new chain
        vm.broadcast(chainAdmin.owner());
        chainAdmin.multicall(calls, true);

        // Set token multiplier setter
        if (input.baseToken != ETH_TOKEN_ADDRESS && chainAdmin.tokenMultiplierSetter() != input.tokenMultiplierSetter) {
            vm.broadcast(chainAdmin.owner());
            chainAdmin.setTokenMultiplierSetter(input.tokenMultiplierSetter);
        }
    }

    function getL1DAValidator() internal view returns (address) {
        if (input.daValidatorType == DAValidatorType.Rollup) {
            return input.rollupL1DaValidator;
        } else if (input.daValidatorType == DAValidatorType.NoDA) {
            return input.noDaValidiumL1Validator;
        } else if (input.daValidatorType == DAValidatorType.Avail) {
            return input.availL1DaValidator;
        } else {
            revert("Invalid DA validator type");
        }
    }

    function transferChainAdminOwnership() internal {
        ChainAdminOwnable chainAdmin = ChainAdminOwnable(payable(output.chainAdmin));
        if (chainAdmin.owner() == input.finalChainAdminOwner) {
            return;
        }

        // Transfer ownership to new owner
        vm.broadcast(chainAdmin.owner());
        chainAdmin.transferOwnership(input.finalChainAdminOwner);

        // Accept ownership of ChainAdmin
        // vm.broadcast(input.finalChainAdminOwner);
        // chainAdmin.acceptOwnership();
    }

    function getL2DAValidatorBytecode() internal view returns (bytes memory bytecode) {
        if (input.daValidatorType == DAValidatorType.Rollup) {
            bytecode = ContractsBytecodesLib.getCreationCode("RollupL2DAValidator");
        } else if (input.daValidatorType == DAValidatorType.NoDA) {
            bytecode = ContractsBytecodesLib.getCreationCode("ValidiumL2DAValidator");
        } else if (input.daValidatorType == DAValidatorType.Avail) {
            bytecode = ContractsBytecodesLib.getCreationCode("AvailL2DAValidator");
        } else {
            revert("Invalid DA validator type");
        }
    }

    function calculateExpectedL2DAValidatorAddress() internal view returns (address) {
        bytes memory bytecode = getL2DAValidatorBytecode();
        (bytes32 bytecodeHash, bytes memory deployData) = Utils.getDeploymentCalldata("", bytecode, "");
        return Utils.getL2AddressViaCreate2Factory("", bytecodeHash, "");
    }

    function getFactoryDeps() internal view returns (bytes[] memory) {
        bytes[] memory factoryDeps = new bytes[](6);
        factoryDeps[0] = Utils.readFoundryDeployedBytecodeL1("L2Bridgehub.sol", "L2Bridgehub");
        factoryDeps[1] = Utils.readFoundryDeployedBytecodeL1("L2AssetRouter.sol", "L2AssetRouter");
        factoryDeps[2] = Utils.readFoundryDeployedBytecodeL1("L2NativeTokenVaultZKOS.sol", "L2NativeTokenVaultZKOS");
        factoryDeps[3] = Utils.readFoundryDeployedBytecodeL1("L2MessageRoot.sol", "L2MessageRoot");
        factoryDeps[4] = Utils.readFoundryDeployedBytecodeL1("UpgradeableBeaconDeployer.sol", "UpgradeableBeaconDeployer");
        factoryDeps[5] = Utils.readFoundryDeployedBytecodeL1("L2ChainAssetHandler.sol", "L2ChainAssetHandler");
        console.log("=== Bytecode hashes for factoryDeps ===");
        console.log("[!] Compare against evmDeployedBytecodeHash in AllContractsHashes.json");
        for (uint256 i = 0; i < factoryDeps.length; i++) {
            bytes memory bytecode = factoryDeps[i];
            bytes32 bytecodeHash = keccak256(bytecode);
            console.log("EVM deployed bytecode hash for factoryDeps [", vm.toString(i), "]:", vm.toString(bytecodeHash));
        }
        console.log("================");
        return factoryDeps;
    }

    // Exactly one of chain_admin_addr or chain_admin_salt must be provided:
    // * If address is provided, it must be already deployed
    // * If salt is provided, it must be used to deploy a NEW ChainAdmin
    // * Otherwise, revert
    function deployChainAdmin() internal {
         if (input.chainAdmin != address(0) && input.chainAdminSalt == bytes32(0)) {
            // Only address is provided
            if (input.chainAdmin.code.length == 0) {
                revert("ChainAdmin is not deployed at provided address");
            }
            output.chainAdmin = input.chainAdmin;
            console.log("Using ChainAdmin at:", input.chainAdmin);
        } else if (input.chainAdmin == address(0) && input.chainAdminSalt != bytes32(0)) {
            // Only salt is provided
            bytes memory constructorArgs = abi.encode(input.tempChainAdminOwner, input.tokenMultiplierSetter);
            bytes memory bytecode = abi.encodePacked(type(ChainAdminOwnable).creationCode, constructorArgs);
            address expectedAddress = vm.computeCreate2Address(input.chainAdminSalt, keccak256(bytecode), DETERMINISTIC_CREATE2_ADDRESS);
            if (expectedAddress.code.length > 0) {
                revert("ChainAdmin is already deployed at expected address with provided salt");
            }
            // Deploy ChainAdmin
            console.log("ChainAdmin owner:", input.tempChainAdminOwner);
            console.log("ChainAdmin constructor args:", vm.toString(constructorArgs));
            vm.broadcast(input.tempChainAdminOwner);
            (bool success,) = DETERMINISTIC_CREATE2_ADDRESS.call{gas: 20_000_000}(abi.encodePacked(input.chainAdminSalt, bytecode));
            require(success, "Failed to deploy ChainAdmin");
            console.log("ChainAdmin deployed at:", expectedAddress);
            output.chainAdmin = expectedAddress;
        } else {
            revert("Only one of chain_admin_addr or chain_admin_salt must be provided");
        }
   }


    function saveOutput() internal {
        string memory json;
        // L1 contracts:
        json = vm.serializeAddress("root", "chain_admin_addr", output.chainAdmin);
        json = vm.serializeAddress("root", "diamond_proxy_addr", output.diamondProxy);
        // Save output
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-prepare-chain-registration-plan.toml");
        vm.writeToml(json, path);
    }
}
