// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// TODO(EVM-1644): LEGACY UPGRADE PROCESS — remove once the registry-driven upgrade process
// (contracts/upgrades/registry: CTMUpgradeExecutor / EcosystemUpgradeExecutor +
// release/transition registries) has fully replaced off-chain governance-calldata generation. Kept for the
// v34 bootstrap edge, which still ships script-composed stage0/1/2 calls.

// solhint-disable gas-custom-errors

import {Script} from "forge-std/Script.sol";
import {Utils} from "../../utils/Utils.sol";

import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

import {UpgradeChainCall} from "deploy-scripts/utils/UpgradeChainCall.sol";

contract DefaultChainUpgrade is Script {
    struct ChainConfig {
        uint256 chainChainId;
        address chainDiamondProxyAddress;
        uint256 oldProtocolVersion;
        address bridgehubProxyAddress;
    }

    ChainConfig config;

    function prepareChainWithBridgehub(uint256 chainId, address bridgehubProxyAddress) public {
        config.chainChainId = chainId;
        config.bridgehubProxyAddress = bridgehubProxyAddress;
        require(config.bridgehubProxyAddress != address(0), "bridgehub proxy is zero");

        address ctm = L1Bridgehub(config.bridgehubProxyAddress).chainTypeManager(config.chainChainId);
        setupConfigFromOnchain(ctm, config.chainChainId);

        // This script does nothing, it only checks that the provided inputs are correct.
        // It is just a wrapper to easily call `upgradeChain`
    }

    /// @notice The legacy per-chain call: the chain is HANDED the cut it must execute.
    function upgradeChain(Diamond.DiamondCutData memory diamondCutData) public virtual {
        _adminExecuteOnChain(
            UpgradeChainCall.encode(config.chainDiamondProxyAddress, config.oldProtocolVersion, diamondCutData)
        );
    }

    function _adminExecuteOnChain(bytes memory _callData) private {
        Utils.adminExecute(
            IZKChain(config.chainDiamondProxyAddress).getAdmin(),
            address(0),
            config.chainDiamondProxyAddress,
            _callData,
            0
        );
    }

    function setupConfigFromOnchain(address ctm, uint256 chainChainId) public {
        config.chainChainId = chainChainId;
        IChainTypeManager chainTypeManager = IChainTypeManager(ctm);
        config.bridgehubProxyAddress = chainTypeManager.BRIDGE_HUB();
        config.chainDiamondProxyAddress = chainTypeManager.getZKChain(chainChainId);
        IZKChain chain = IZKChain(config.chainDiamondProxyAddress);
        config.oldProtocolVersion = chain.getProtocolVersion();
    }
}
