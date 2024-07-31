// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {Utils} from "./Utils.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";

contract RegisterHyperchainScript is Script {
    using stdToml for string;

    address constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
    bytes32 constant STATE_TRANSITION_NEW_CHAIN_HASH = keccak256("NewHyperchain(uint256,address)");

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
        address stateTransitionProxy;
        address validatorTimelock;
        bytes diamondCutData;
        address governanceSecurityCouncilAddress;
        uint256 governanceMinDelay;
        address newDiamondProxy;
        address governance;
        address chainAdmin;
    }

    Config config;

    function run() public {
        console.log("Deploying Hyperchain");

        initializeConfig();

        deployGovernance();
        deployChainAdmin();
        checkTokenAddress();
        registerTokenOnBridgehub();
        registerHyperchain();
        addValidators();
        configureZkSyncStateTransition();
        setPendingAdmin();

        saveOutput();
    }

    function initializeConfig() internal {
        // Grab config from output of l1 deployment
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/register-hyperchain.toml");
        string memory toml = vm.readFile(path);

        config.deployerAddress = msg.sender;

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.ownerAddress = toml.readAddress("$.owner_address");

        config.bridgehub = toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr");
        config.stateTransitionProxy = toml.readAddress(
            "$.deployed_addresses.state_transition.state_transition_proxy_addr"
        );
        config.validatorTimelock = toml.readAddress("$.deployed_addresses.validator_timelock_addr");

        config.diamondCutData = toml.readBytes("$.contracts_config.diamond_cut_data");

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

    function registerTokenOnBridgehub() internal {
        IBridgehub bridgehub = IBridgehub(config.bridgehub);
        Ownable ownable = Ownable(config.bridgehub);

        if (bridgehub.tokenIsRegistered(config.baseToken)) {
            console.log("Token already registered on Bridgehub");
        } else {
            bytes memory data = abi.encodeCall(bridgehub.addToken, (config.baseToken));
            Utils.executeUpgrade({
                _governor: ownable.owner(),
                _salt: bytes32(config.bridgehubCreateNewChainSalt),
                _target: config.bridgehub,
                _data: data,
                _value: 0,
                _delay: 0
            });
            console.log("Token registered on Bridgehub");
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
        ChainAdmin chainAdmin = new ChainAdmin(config.ownerAddress, address(0));
        console.log("ChainAdmin deployed at:", address(chainAdmin));
        config.chainAdmin = address(chainAdmin);
    }

    function registerHyperchain() internal {
        IBridgehub bridgehub = IBridgehub(config.bridgehub);
        Ownable ownable = Ownable(config.bridgehub);

        vm.recordLogs();
        bytes memory data = abi.encodeCall(
            bridgehub.createNewChain,
            (
                config.chainChainId,
                config.stateTransitionProxy,
                config.baseToken,
                config.bridgehubCreateNewChainSalt,
                msg.sender,
                config.diamondCutData
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
        console.log("Hyperchain registered");

        // Get new diamond proxy address from emitted events
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address diamondProxyAddress;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == STATE_TRANSITION_NEW_CHAIN_HASH) {
                diamondProxyAddress = address(uint160(uint256(logs[i].topics[2])));
                break;
            }
        }
        if (diamondProxyAddress == address(0)) {
            revert("Diamond proxy address not found");
        }
        config.newDiamondProxy = diamondProxyAddress;
        console.log("Hyperchain diamond proxy deployed at:", diamondProxyAddress);
    }

    function addValidators() internal {
        ValidatorTimelock validatorTimelock = ValidatorTimelock(config.validatorTimelock);

        vm.startBroadcast();
        validatorTimelock.addValidator(config.chainChainId, config.validatorSenderOperatorCommitEth);
        validatorTimelock.addValidator(config.chainChainId, config.validatorSenderOperatorBlobsEth);
        vm.stopBroadcast();

        console.log("Validators added");
    }

    function configureZkSyncStateTransition() internal {
        IZkSyncHyperchain hyperchain = IZkSyncHyperchain(config.newDiamondProxy);

        vm.startBroadcast();
        hyperchain.setTokenMultiplier(
            config.baseTokenGasPriceMultiplierNominator,
            config.baseTokenGasPriceMultiplierDenominator
        );

        if (config.validiumMode) {
            hyperchain.setPubdataPricingMode(PubdataPricingMode.Validium);
        }

        vm.stopBroadcast();
        console.log("ZkSync State Transition configured");
    }

    function setPendingAdmin() internal {
        IZkSyncHyperchain hyperchain = IZkSyncHyperchain(config.newDiamondProxy);

        vm.broadcast();
        hyperchain.setPendingAdmin(config.chainAdmin);
        console.log("Owner for ", config.newDiamondProxy, "set to", config.chainAdmin);
    }

    function saveOutput() internal {
        vm.serializeAddress("root", "diamond_proxy_addr", config.newDiamondProxy);
        vm.serializeAddress("root", "chain_admin_addr", config.chainAdmin);
        string memory toml = vm.serializeAddress("root", "governance_addr", config.governance);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-register-hyperchain.toml");
        vm.writeToml(toml, path);
    }
}
