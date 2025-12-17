// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Utils} from "../../utils/Utils.sol";

import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {ChainTypeManagerBase} from "../../../contracts/state-transition/ChainTypeManagerBase.sol";
import {GetDiamondCutData} from "../../utils/GetDiamondCutData.sol";

contract DefaultChainUpgrade is Script {
    using stdToml for string;

    struct ChainConfig {
        uint256 chainChainId;
        address chainDiamondProxyAddress;
        address ctm;
        uint256 oldProtocolVersion;
        address bridgehubProxyAddress;
    }

    address currentChainAdmin;
    ChainConfig config;

    function prepareChain(uint256 chainId, string memory permanentValuesInputPath) public {
        string memory root = vm.projectRoot();
        permanentValuesInputPath = string.concat(root, permanentValuesInputPath);

        // Grab config from output of l1 deployment
        string memory permanentValuesInputToml = vm.readFile(permanentValuesInputPath);

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml

        config.chainChainId = chainId;
        config.bridgehubProxyAddress = permanentValuesInputToml.readAddress("$.core_contracts.bridgehub_proxy_addr");

        address ctm = L1Bridgehub(config.bridgehubProxyAddress).chainTypeManager(config.chainChainId);
        setupConfigFromOnchain(ctm, config.chainChainId);

        // This script does nothing, it only checks that the provided inputs are correct.
        // It is just a wrapper to easily call `upgradeChain`
    }

    function run(address ctm, uint256 chainChainId) public virtual {
        setupConfigFromOnchain(ctm, chainChainId);
        Diamond.DiamondCutData memory diamondCutData = GetDiamondCutData.getDiamondCutData(
            ctm,
            config.oldProtocolVersion
        );
        upgradeChain(diamondCutData);
    }

    function upgradeChain(Diamond.DiamondCutData memory diamondCutData) public {
        Utils.adminExecute(
            IZKChain(config.chainDiamondProxyAddress).getAdmin(),
            address(0),
            config.chainDiamondProxyAddress,
            abi.encodeCall(IAdmin.upgradeChainFromVersion, (config.oldProtocolVersion, diamondCutData)),
            0
        );
    }

    function setUpgradeTimestamp(uint256 newProtocolVersion, uint256 timestamp) public {
        address admin = IZKChain(config.chainDiamondProxyAddress).getAdmin();
        address adminOwner = Ownable(admin).owner();

        vm.startBroadcast(adminOwner);
        IChainAdminOwnable(admin).setUpgradeTimestamp(newProtocolVersion, timestamp);
    }

    function executeUpgrade(address ctm, uint256 chainChainId) public {
        IChainTypeManager chainTypeManager = IChainTypeManager(ctm);
        config.chainDiamondProxyAddress = chainTypeManager.getZKChain(chainChainId);
        IZKChain chain = IZKChain(config.chainDiamondProxyAddress);
        uint256 oldProtocolVersion = chain.getProtocolVersion();
        Diamond.DiamondCutData memory diamondCutData = GetDiamondCutData.getDiamondCutData(ctm, oldProtocolVersion);
        chain.executeUpgrade(diamondCutData);
    }

    function setupConfigFromOnchain(address ctm, uint256 chainChainId) public {
        config.ctm = ctm;
        config.chainChainId = chainChainId;
        IChainTypeManager chainTypeManager = IChainTypeManager(ctm);
        config.bridgehubProxyAddress = chainTypeManager.BRIDGE_HUB();
        config.chainDiamondProxyAddress = chainTypeManager.getZKChain(chainChainId);
        IZKChain chain = IZKChain(config.chainDiamondProxyAddress);
        config.oldProtocolVersion = chain.getProtocolVersion();
    }
}
