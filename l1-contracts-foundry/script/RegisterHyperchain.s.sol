// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {Governance} from "contracts/governance/Governance.sol";

contract RegisterHyperchainScript is Script {
    using stdToml for string;

    address constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
    bytes32 constant STATE_TRANSITION_NEW_CHAIN_HASH = keccak256("NewHyperchain(uint256,address)");

    struct Config {
        address deployerAddress;
        address ownerAddress;
        uint256 hyperchainChainId;
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
    }

    Config config;

    function run() public {
        console.log("Deploying Hyperchain");

        initializeConfig();

        deployGovernance();
        checkTokenAddress();
        registerTokenOnBridgehub();
        registerHyperchain();
        addValidators();
        configureZkSyncStateTransition();
        setPendingAdmin();

        saveOutput();
    }

    // This function should be called by the owner to accept the admin role
    function acceptAdmin() public {
        console.log("Accept admin Hyperchain");
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/accept-admin.toml");
        string memory toml = vm.readFile(path);
        address diamondProxy = toml.readAddress("$.diamond_proxy_addr");
        IZkSyncHyperchain zkSyncStateTransition = IZkSyncHyperchain(diamondProxy);
        vm.broadcast();
        zkSyncStateTransition.acceptAdmin();
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

        config.hyperchainChainId = toml.readUint("$.hyperchain.hyperchain_chain_id");
        config.bridgehubCreateNewChainSalt = toml.readUint("$.hyperchain.bridgehub_create_new_chain_salt");
        config.baseToken = toml.readAddress("$.hyperchain.base_token_addr");
        config.validiumMode = toml.readBool("$.hyperchain.validium_mode");
        config.validatorSenderOperatorCommitEth = toml.readAddress("$.hyperchain.validator_sender_operator_commit_eth");
        config.validatorSenderOperatorBlobsEth = toml.readAddress("$.hyperchain.validator_sender_operator_blobs_eth");
        config.baseTokenGasPriceMultiplierNominator = uint128(
            toml.readUint("$.hyperchain.base_token_gas_price_multiplier_nominator")
        );
        config.baseTokenGasPriceMultiplierDenominator = uint128(
            toml.readUint("$.hyperchain.base_token_gas_price_multiplier_denominator")
        );
        config.governanceMinDelay = uint256(toml.readUint("$.hyperchain.governance_min_delay"));
        config.governanceSecurityCouncilAddress = toml.readAddress("$.hyperchain.governance_security_council_address");
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

        if (bridgehub.tokenIsRegistered(config.baseToken)) {
            console.log("Token already registered on Bridgehub");
        } else {
            vm.broadcast();
            bridgehub.addToken(config.baseToken);
            console.log("Token registered on Bridgehub");
        }
    }

    function deployGovernance() internal {
        Governance governance = new Governance(
            config.ownerAddress,
            config.governanceSecurityCouncilAddress,
            config.governanceMinDelay
        );
        console.log("Governance deployed at:", address(governance));
        config.governance = address(governance);
    }

    function registerHyperchain() internal {
        IBridgehub bridgehub = IBridgehub(config.bridgehub);

        vm.broadcast();
        vm.recordLogs();
        bridgehub.createNewChain({
            _chainId: config.hyperchainChainId,
            _stateTransitionManager: config.stateTransitionProxy,
            _baseToken: config.baseToken,
            _salt: config.bridgehubCreateNewChainSalt,
            _admin: msg.sender,
            _initData: config.diamondCutData
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
        validatorTimelock.addValidator(config.hyperchainChainId, config.validatorSenderOperatorCommitEth);
        validatorTimelock.addValidator(config.hyperchainChainId, config.validatorSenderOperatorBlobsEth);
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

        // TODO: support validium mode when available
        // if (config.contractsMode) {
        //     zkSyncStateTransition.setValidiumMode(PubdataPricingMode.Validium);
        // }

        vm.stopBroadcast();
        console.log("ZkSync State Transition configured");
    }

    function setPendingAdmin() internal {
        IZkSyncHyperchain hyperchain = IZkSyncHyperchain(config.newDiamondProxy);

        vm.broadcast();
        hyperchain.setPendingAdmin(config.governance);
        console.log("Owner set");
    }

    function saveOutput() internal {
        string memory toml = vm.serializeAddress("root", "diamond_proxy_addr", config.newDiamondProxy);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-out/output-register-hyperchain.toml");
        vm.writeToml(toml, path);
    }
}
