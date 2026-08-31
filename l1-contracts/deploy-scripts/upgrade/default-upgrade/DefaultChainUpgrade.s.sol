// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// TODO(EVM-1644): LEGACY UPGRADE PROCESS — remove once the registry-driven upgrade process
// (contracts/upgrades/registry: CTMUpgradeExecutor / EcosystemUpgradeExecutor +
// release/transition registries) has fully replaced off-chain governance-calldata generation. Kept for the
// current (v31) upgrade, which still ships hand-composed stage0/1/2 calls.

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {Utils} from "../../utils/Utils.sol";

import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {Call} from "contracts/governance/Common.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

import {GetDiamondCutData} from "../../utils/GetDiamondCutData.sol";
import {UpgradeChainCall} from "deploy-scripts/utils/UpgradeChainCall.sol";

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

    function upgradeChain(Diamond.DiamondCutData memory diamondCutData) public virtual {
        bytes memory callData = UpgradeChainCall.encode(
            config.chainDiamondProxyAddress,
            config.oldProtocolVersion,
            diamondCutData
        );

        Utils.adminExecute(
            IZKChain(config.chainDiamondProxyAddress).getAdmin(),
            address(0),
            config.chainDiamondProxyAddress,
            callData,
            0
        );
    }

    function setUpgradeTimestamp(uint256 timestamp) public {
        address admin = IZKChain(config.chainDiamondProxyAddress).getAdmin();
        address serverNotifier = IChainTypeManager(config.ctm).serverNotifierAddress();

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: serverNotifier,
            value: 0,
            data: abi.encodeCall(ServerNotifier.setUpgradeTimestamp, (config.chainChainId, timestamp))
        });

        Utils.adminExecuteCalls(admin, address(0), calls);
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
