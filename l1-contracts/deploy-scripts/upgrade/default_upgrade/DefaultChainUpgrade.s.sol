// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Utils} from "../../utils/Utils.sol";

import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";

import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {ChainTypeManagerBase} from "../../../contracts/state-transition/ChainTypeManagerBase.sol";

contract DefaultChainUpgrade is Script {
    using stdToml for string;

    struct ChainConfig {
        address deployerAddress;
        uint256 chainChainId;
        address chainDiamondProxyAddress;
        address bridgehubProxyAddress;
    }

    address currentChainAdmin;
    ChainConfig config;

    function prepareChain(string memory permanentValuesInputPath, string memory configPath) public {
        string memory root = vm.projectRoot();
        configPath = string.concat(root, configPath);
        permanentValuesInputPath = string.concat(root, permanentValuesInputPath);

        initializeConfig(permanentValuesInputPath, configPath);

        // This script does nothing, it only checks that the provided inputs are correct.
        // It is just a wrapper to easily call `upgradeChain`
    }

    function run(
        address ctm,
        uint256 chainChainId
    ) public virtual {
        IChainTypeManager ctm = IChainTypeManager(ctm);
        address chainDiamondProxyAddress = ctm.getZKChain(chainChainId);
        (uint256 major,uint256  minor, uint256  patch) = ctm.getSemverProtocolVersion();
        uint256 newProtocolVersionSemVer = SemVer.packSemVer(major, minor, patch);
    }

    function getUpgradeCutData(uint256 protocolVersion, IChainTypeManager ctm) public returns (Diamond.DiamondCutData memory upgradeCutData) {
        uint256 blockUpgrade = ctm.upgradeCutDataBlock(protocolVersion);

        // Listen event NewUpgradeCutHash from block blockupgrade
        // Pretend i have calldata from tx_hash
//        bytes32 txHash;

        bytes memory tx_calldata;

        // try to decode
        (Diamond.DiamondCutData calldata _cutData,
            uint256 _oldProtocolVersion,
            uint256 _oldProtocolVersionDeadline,
            uint256 _newProtocolVersion) = abi.decode(
            tx_calldata,
            ChainTypeManagerBase.setNewVersionUpgrade
        );

        // if not success


    }


    function upgradeChain(address chainDiamondProxyAddress, uint256 oldProtocolVersion, Diamond.DiamondCutData memory upgradeCutData) public {
        Utils.adminExecute(
            IZKChain(chainDiamondProxyAddress).getAdmin(),
            address(0),
            chainDiamondProxyAddress,
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

    function initializeConfig(string memory permanentValuesInputPath, string memory configPath) internal {
        config.deployerAddress = msg.sender;

        // Grab config from output of l1 deployment
        string memory toml = vm.readFile(configPath);
        string memory permanentValuesInputToml = vm.readFile(permanentValuesInputPath);

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml

        config.chainChainId = permanentValuesInputToml.readUint("$.chain.chain_id");
        config.bridgehubProxyAddress = permanentValuesInputToml.readAddress("$.contracts.bridgehub_proxy_address");

        config.chainDiamondProxyAddress = L1Bridgehub(config.bridgehubProxyAddress).getZKChain(config.chainChainId);
    }
}
