// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {Utils} from "./Utils.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

contract RegisterZKChainScript is Script {
    using stdToml for string;

    address internal constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
    bytes32 internal constant STATE_TRANSITION_NEW_CHAIN_HASH = keccak256("NewZKChain(uint256,address)");

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
        address nativeTokenVault;
        address stateTransitionProxy;
        address validatorTimelock;
        bytes diamondCutData;
        bytes forceDeployments;
        address governanceSecurityCouncilAddress;
        uint256 governanceMinDelay;
        address newDiamondProxy;
        address governance;
        address chainAdmin;
    }

    Config internal config;

    function run() public {
        console.log("Deploying ZKChain");

        initializeConfig();

        deployGovernance();
        deployChainAdmin();
        checkTokenAddress();
        registerAssetIdOnBridgehub();
        registerTokenOnNTV();
        registerZKChain();
        addValidators();
        configureZkSyncStateTransition();
        setPendingAdmin();

        saveOutput();
    }

    function initializeConfig() internal {
        // Grab config from output of l1 deployment
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, vm.envString("L1_OUTPUT")); //"/script-config/register-zkChain.toml");
        string memory toml = vm.readFile(path);

        config.deployerAddress = msg.sender;

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml

        config.bridgehub = toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr");
        config.stateTransitionProxy = toml.readAddress(
            "$.deployed_addresses.state_transition.state_transition_proxy_addr"
        );
        config.validatorTimelock = toml.readAddress("$.deployed_addresses.validator_timelock_addr");
        // config.bridgehubGovernance = toml.readAddress("$.deployed_addresses.governance_addr");
        config.nativeTokenVault = toml.readAddress("$.deployed_addresses.native_token_vault_addr");
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

    function registerAssetIdOnBridgehub() internal {
        IBridgehub bridgehub = IBridgehub(config.bridgehub);
        Ownable ownable = Ownable(config.bridgehub);
        bytes32 baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, config.baseToken);

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
        // Ownable ownable = Ownable(config.nativeTokenVault);
        bytes32 baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, config.baseToken);
        config.baseTokenAssetId = baseTokenAssetId;
        if (ntv.tokenAddress(baseTokenAssetId) != address(0) || config.baseToken == ETH_TOKEN_ADDRESS) {
            console.log("Token already registered on NTV");
        } else {
            // bytes memory data = abi.encodeCall(ntv.registerToken, (config.baseToken));
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
        config.governance = address(governance);
    }

    function deployChainAdmin() internal {
        vm.broadcast();
        AccessControlRestriction restriction = new AccessControlRestriction(0, config.ownerAddress);

        address[] memory restrictions = new address[](1);
        restrictions[0] = address(restriction);

        vm.broadcast();
        ChainAdmin chainAdmin = new ChainAdmin(restrictions);
        config.chainAdmin = address(chainAdmin);
    }

    function registerZKChain() internal {
        IBridgehub bridgehub = IBridgehub(config.bridgehub);
        Ownable ownable = Ownable(config.bridgehub);

        vm.recordLogs();
        bytes memory data = abi.encodeCall(
            bridgehub.createNewChain,
            (
                config.chainChainId,
                config.stateTransitionProxy,
                config.baseTokenAssetId,
                config.bridgehubCreateNewChainSalt,
                msg.sender,
                abi.encode(config.diamondCutData, config.forceDeployments),
                new bytes[](0)
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
        config.newDiamondProxy = diamondProxyAddress;
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
        IZKChain zkChain = IZKChain(config.newDiamondProxy);

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
        IZKChain zkChain = IZKChain(config.newDiamondProxy);

        vm.startBroadcast(msg.sender);
        zkChain.setPendingAdmin(config.chainAdmin);
        vm.stopBroadcast();
        console.log("Owner for ", config.newDiamondProxy, "set to", config.chainAdmin);
    }

    function saveOutput() internal {
        vm.serializeAddress("root", "diamond_proxy_addr", config.newDiamondProxy);
        vm.serializeAddress("root", "chain_admin_addr", config.chainAdmin);
        string memory toml = vm.serializeAddress("root", "governance_addr", config.governance);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-register-zkChain.toml");
        vm.writeToml(toml, path);
        console.log("Output saved at:", path);
    }
}
