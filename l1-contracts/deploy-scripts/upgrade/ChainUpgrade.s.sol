// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Utils, L2_BRIDGEHUB_ADDRESS, L2_ASSET_ROUTER_ADDRESS, L2_NATIVE_TOKEN_VAULT_ADDRESS, L2_MESSAGE_ROOT_ADDRESS} from "../Utils.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {L2ContractsBytecodesLib} from "../L2ContractsBytecodesLib.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {Call} from "contracts/governance/Common.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

interface LegacyChainAdmin {
    function owner() external view returns (address);
}

contract ChainUpgrade is Script {
    using stdToml for string;

    struct ChainConfig {
        address deployerAddress;
        address ownerAddress;
        uint256 chainChainId;
        address chainDiamondProxyAddress;
        bool validiumMode;
        bool permanentRollup;
        // FIXME: From ecosystem, maybe move to a different struct
        address expectedRollupL2DAValidator;
        address expectedL2GatewayUpgrade;
        address expectedValidiumL2DAValidator;
        address permanentRollupRestriction;
        address bridgehubProxyAddress;
        address oldSharedBridgeProxyAddress;
    }

    struct Output {
        address l2DAValidator;
        address accessControlRestriction;
        address chainAdmin;
    }

    address currentChainAdmin;
    ChainConfig config;
    Output output;

    function prepareChain(
        string memory ecosystemInputPath,
        string memory ecosystemOutputPath,
        string memory configPath,
        string memory outputPath
    ) public {
        string memory root = vm.projectRoot();
        ecosystemInputPath = string.concat(root, ecosystemInputPath);
        ecosystemOutputPath = string.concat(root, ecosystemOutputPath);
        configPath = string.concat(root, configPath);
        outputPath = string.concat(root, outputPath);

        initializeConfig(configPath, ecosystemInputPath, ecosystemOutputPath);

        checkCorrectOwnerAddress();
        // Preparation of chain consists of two parts:
        // - Deploying l2 da validator
        // - Deploying new chain admin

        deployNewL2DAValidator();
        deployL2GatewayUpgrade();
        deployNewChainAdmin();
        governanceMoveToNewChainAdmin();

        saveOutput(outputPath);
    }

    function upgradeChain(uint256 oldProtocolVersion, Diamond.DiamondCutData memory upgradeCutData) public {
        Utils.adminExecute(
            output.chainAdmin,
            output.accessControlRestriction,
            config.chainDiamondProxyAddress,
            abi.encodeCall(IAdmin.upgradeChainFromVersion, (oldProtocolVersion, upgradeCutData)),
            0
        );
    }

    function initializeConfig(
        string memory configPath,
        string memory ecosystemInputPath,
        string memory ecosystemOutputPath
    ) internal {
        config.deployerAddress = msg.sender;

        // Grab config from output of l1 deployment
        string memory toml = vm.readFile(configPath);

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml

        config.ownerAddress = toml.readAddress("$.owner_address");
        config.chainChainId = toml.readUint("$.chain.chain_id");
        config.validiumMode = toml.readBool("$.chain.validium_mode");
        config.chainDiamondProxyAddress = toml.readAddress("$.chain.diamond_proxy_address");
        config.permanentRollup = toml.readBool("$.chain.permanent_rollup");

        toml = vm.readFile(ecosystemOutputPath);

        config.expectedRollupL2DAValidator = toml.readAddress("$.contracts_config.expected_rollup_l2_da_validator");
        config.expectedValidiumL2DAValidator = toml.readAddress("$.contracts_config.expected_validium_l2_da_validator");
        config.expectedL2GatewayUpgrade = toml.readAddress("$.contracts_config.expected_l2_gateway_upgrade");
        config.permanentRollupRestriction = toml.readAddress("$.deployed_addresses.permanent_rollup_restriction");

        toml = vm.readFile(ecosystemInputPath);

        config.bridgehubProxyAddress = toml.readAddress("$.contracts.bridgehub_proxy_address");
        config.oldSharedBridgeProxyAddress = toml.readAddress("$.contracts.old_shared_bridge_proxy_address");
    }

    function checkCorrectOwnerAddress() internal {
        currentChainAdmin = address(IZKChain(config.chainDiamondProxyAddress).getAdmin());
        address currentAdminOwner = LegacyChainAdmin(currentChainAdmin).owner();

        require(currentAdminOwner == config.ownerAddress, "Only the owner of the chain admin can call this function");
    }

    function deployNewL2DAValidator() internal {
        address expectedL2DAValidator = Utils.deployThroughL1Deterministic({
            // FIXME: for now this script only works with rollup chains
            bytecode: L2ContractsBytecodesLib.readRollupL2DAValidatorBytecode(),
            constructorargs: hex"",
            create2salt: bytes32(0),
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            chainId: config.chainChainId,
            bridgehubAddress: config.bridgehubProxyAddress,
            l1SharedBridgeProxy: config.oldSharedBridgeProxyAddress
        });
        // FIXME: for now this script only works with rollup chains
        require(expectedL2DAValidator == config.expectedRollupL2DAValidator, "Invalid L2DAValidator address");

        output.l2DAValidator = expectedL2DAValidator;
    }

    function deployL2GatewayUpgrade() internal {
        address expectedGatewayUpgrade = Utils.deployThroughL1Deterministic({
            bytecode: L2ContractsBytecodesLib.readGatewayUpgradeBytecode(),
            constructorargs: hex"",
            create2salt: bytes32(0),
            l2GasLimit: Utils.MAX_PRIORITY_TX_GAS,
            factoryDeps: new bytes[](0),
            chainId: config.chainChainId,
            bridgehubAddress: config.bridgehubProxyAddress,
            l1SharedBridgeProxy: config.oldSharedBridgeProxyAddress
        });
        require(expectedGatewayUpgrade == config.expectedL2GatewayUpgrade, "Invalid L2Gateway address");
    }

    function deployNewChainAdmin() internal {
        AccessControlRestriction accessControlRestriction = new AccessControlRestriction(0, config.ownerAddress);

        address[] memory restrictions;
        if (config.permanentRollup) {
            restrictions = new address[](2);
            restrictions[0] = address(accessControlRestriction);
            restrictions[1] = config.permanentRollupRestriction;
        } else {
            restrictions = new address[](1);
            restrictions[0] = address(accessControlRestriction);
        }

        ChainAdmin newChainAdmin = new ChainAdmin(restrictions);
        output.chainAdmin = address(newChainAdmin);
        output.accessControlRestriction = address(accessControlRestriction);
    }

    /// @dev The caller of this function needs to be the owner of the chain admin
    /// of the
    function governanceMoveToNewChainAdmin() internal {
        // Firstly, we need to call the legacy chain admin to transfer the ownership to the new chain admin
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: config.chainDiamondProxyAddress,
            value: 0,
            data: abi.encodeCall(IAdmin.setPendingAdmin, (output.chainAdmin))
        });

        vm.startBroadcast(config.ownerAddress);
        ChainAdmin(payable(currentChainAdmin)).multicall(calls, true);
        vm.stopBroadcast();

        // Now we need to accept the adminship
        Utils.adminExecute({
            _admin: output.chainAdmin,
            _accessControlRestriction: output.accessControlRestriction,
            _target: config.chainDiamondProxyAddress,
            _data: abi.encodeCall(IAdmin.acceptAdmin, ()),
            _value: 0
        });
    }

    function saveOutput(string memory outputPath) internal {
        vm.serializeAddress("root", "l2_da_validator_addr", output.l2DAValidator);
        vm.serializeAddress("root", "chain_admin_addr", output.chainAdmin);

        string memory toml = vm.serializeAddress("root", "access_control_restriction", output.accessControlRestriction);
        string memory root = vm.projectRoot();
        vm.writeToml(toml, outputPath);
        console.log("Output saved at:", outputPath);
    }
}
