// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {Utils} from "../../utils/Utils.sol";

import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";

import {GetDiamondCutData} from "../../utils/GetDiamondCutData.sol";

contract DefaultChainUpgrade is Script {
    struct ChainConfig {
        uint256 chainChainId;
        address chainDiamondProxyAddress;
        address ctm;
        uint256 oldProtocolVersion;
        address bridgehubProxyAddress;
    }

    address currentChainAdmin;
    ChainConfig config;

    function getChainConfig() public view returns (ChainConfig memory) {
        return config;
    }

    function prepareChain(uint256 chainId, string memory permanentValuesInputPath) public {
        chainId;
        permanentValuesInputPath;
        revert("DefaultChainUpgrade.prepareChain(..., permanent-values path) is deprecated. Use prepareChainWithBridgehub(...)");
    }

    function prepareChainWithBridgehub(uint256 chainId, address bridgehubProxyAddress) public {
        config.chainChainId = chainId;
        config.bridgehubProxyAddress = bridgehubProxyAddress;
        require(config.bridgehubProxyAddress != address(0), "bridgehub proxy is zero");

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
        // Chains on protocol version < v31 use the old 2-param upgradeChainFromVersion(uint256, DiamondCutData).
        // The 3-param version with the leading address was introduced in v31.
        uint256 oldMinor = (config.oldProtocolVersion >> 32) & 0xFFFF;
        bytes memory callData;
        if (oldMinor < 31) {
            callData = abi.encodeWithSelector(
                bytes4(0xfc57565f), // upgradeChainFromVersion(uint256,DiamondCutData)
                config.oldProtocolVersion,
                diamondCutData
            );
        } else {
            callData = abi.encodeCall(
                IAdmin.upgradeChainFromVersion,
                (config.chainDiamondProxyAddress, config.oldProtocolVersion, diamondCutData)
            );
        }

        Utils.adminExecute(
            IZKChain(config.chainDiamondProxyAddress).getAdmin(),
            address(0),
            config.chainDiamondProxyAddress,
            callData,
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
