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
        bool permanentRollup;
        // FIXME: From ecosystem, maybe move to a different struct
        address bridgehubProxyAddress;
        address oldSharedBridgeProxyAddress;
    }

    struct Output {
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

        // Deploying of the new chain admin is not strictly needed
        // but our existing tooling relies on the new impl of chain admin
        deployNewChainAdmin();
        governanceMoveToNewChainAdmin();

        // This script does nothing, it only checks that the provided inputs are correct.
        // It is just a wrapper to easily call `upgradeChain`

        saveOutput(outputPath);
    }

    function run() public {
        // TODO: maybe make it read from 1 exact input file,
        // for now doing it this way is just faster

        prepareChain(
            "/script-config/gateway-upgrade-ecosystem.toml",
            "/script-out/gateway-upgrade-ecosystem.toml",
            "/script-config/gateway-upgrade-chain.toml",
            "/script-out/gateway-upgrade-chain.toml"
        );
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
        config.chainDiamondProxyAddress = toml.readAddress("$.chain.diamond_proxy_address");
        config.permanentRollup = toml.readBool("$.chain.permanent_rollup");

        toml = vm.readFile(ecosystemInputPath);

        config.bridgehubProxyAddress = toml.readAddress("$.contracts.bridgehub_proxy_address");
        config.oldSharedBridgeProxyAddress = toml.readAddress("$.contracts.old_shared_bridge_proxy_address");
    }

    function checkCorrectOwnerAddress() internal {
        currentChainAdmin = address(IZKChain(config.chainDiamondProxyAddress).getAdmin());
        address currentAdminOwner = LegacyChainAdmin(currentChainAdmin).owner();

        require(currentAdminOwner == config.ownerAddress, "Only the owner of the chain admin can call this function");
    }

    function deployNewChainAdmin() internal {
        vm.broadcast(config.ownerAddress);
        AccessControlRestriction accessControlRestriction = new AccessControlRestriction(0, config.ownerAddress);

        address[] memory restrictions;
        restrictions = new address[](1);
        restrictions[0] = address(accessControlRestriction);

        vm.broadcast(config.ownerAddress);
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
        vm.serializeAddress("root", "chain_admin_addr", output.chainAdmin);

        string memory toml = vm.serializeAddress("root", "access_control_restriction", output.accessControlRestriction);
        string memory root = vm.projectRoot();
        vm.writeToml(toml, outputPath);
        console.log("Output saved at:", outputPath);
    }
}
