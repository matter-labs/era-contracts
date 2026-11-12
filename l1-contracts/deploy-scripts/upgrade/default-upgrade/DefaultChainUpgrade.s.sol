// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {Utils} from "../../utils/Utils.sol";

import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";

import {UpgradeChainCall} from "deploy-scripts/utils/UpgradeChainCall.sol";

contract DefaultChainUpgrade is Script {
    struct ChainConfig {
        uint256 chainChainId;
        address chainDiamondProxyAddress;
        uint256 oldProtocolVersion;
        address bridgehubProxyAddress;
    }

    ChainConfig internal config;

    function prepareChainWithBridgehub(uint256 chainId, address bridgehubProxyAddress) public {
        config.chainChainId = chainId;
        config.bridgehubProxyAddress = bridgehubProxyAddress;
        require(config.bridgehubProxyAddress != address(0), "bridgehub proxy is zero");

        address ctm = L1Bridgehub(config.bridgehubProxyAddress).chainTypeManager(config.chainChainId);
        setupConfigFromOnchain(ctm, config.chainChainId);

        // This script does nothing, it only checks that the provided inputs are correct.
        // It is just a wrapper to easily call `upgradeChain`
    }

    /// @notice The per-chain call, by the chain's admin: the chain reads the cut its CTM committed.
    function upgradeChain() public virtual {
        _adminExecuteOnChain(UpgradeChainCall.encode(config.chainDiamondProxyAddress, config.oldProtocolVersion));
    }

    function _adminExecuteOnChain(bytes memory _callData) private {
        Utils.adminExecute({
            _admin: IZKChain(config.chainDiamondProxyAddress).getAdmin(),
            _accessControlRestriction: address(0),
            _target: config.chainDiamondProxyAddress,
            _data: _callData,
            _value: 0
        });
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
