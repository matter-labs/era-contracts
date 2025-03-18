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
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";
import {Call} from "contracts/governance/Common.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";

contract ChainUpgrade is Script {
    using stdToml for string;

    struct ChainConfig {
        address deployerAddress;
        uint256 chainChainId;
        address chainDiamondProxyAddress;
        address bridgehubProxyAddress;
    }

    address currentChainAdmin;
    ChainConfig config;

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

        // This script does nothing, it only checks that the provided inputs are correct.
        // It is just a wrapper to easily call `upgradeChain`
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
            IZKChain(config.chainDiamondProxyAddress).getAdmin(),
            address(0),
            config.chainDiamondProxyAddress,
            abi.encodeCall(IAdmin.upgradeChainFromVersion, (oldProtocolVersion, upgradeCutData)),
            0
        );
    }

    function setUpgradeTimestamp(uint256 newProtocolVersion, uint256 timestamp) public {
        address admin = IZKChain(config.chainDiamondProxyAddress).getAdmin();
        address adminOwner = Ownable(admin).owner();

        vm.startBroadcast(adminOwner);
        IChainAdminOwnable(admin).setUpgradeTimestamp(newProtocolVersion, timestamp);
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

        config.chainChainId = toml.readUint("$.chain.chain_id");

        toml = vm.readFile(ecosystemInputPath);
        config.bridgehubProxyAddress = toml.readAddress("$.contracts.bridgehub_proxy_address");

        config.chainDiamondProxyAddress = Bridgehub(config.bridgehubProxyAddress).getHyperchain(config.chainChainId);
    }
}
