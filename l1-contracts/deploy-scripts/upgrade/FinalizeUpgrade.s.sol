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

import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

/// @notice Script intended to help us finalize the governance upgrade
contract FinalizeUpgrade is Script {
    using stdToml for string;

    string constant FINALIZE_UPGRADE_CONFIG_PATH = "/script-config/gateway-finalize-upgrade.toml";

    struct Config {
        address bridgehub;
        address l1NativeTokenVault;
    }

    Config config;

    function initChains(address bridgehub, uint256[] calldata chains) external {
        // TODO: we can optimize it to be done in mutlicall, does not matter

        for (uint256 i = 0; i < chains.length; ++i) {
            Bridgehub bh = Bridgehub(bridgehub);

            if (bh.baseTokenAssetId(chains[i]) == bytes32(0)) {
                vm.broadcast();
                Bridgehub(bridgehub).setLegacyBaseTokenAssetId(chains[i]);
            }

            if (bh.getZKChain(chains[i]) == address(0)) {
                vm.broadcast();
                Bridgehub(bridgehub).setLegacyChainAddress(chains[i]);
            }
        }
    }

    function initTokens(
        address payable l1NativeTokenVault,
        address[] calldata tokens,
        uint256[] calldata chains
    ) external {
        // TODO: we can optimize it to be done in mutlicall, does not matter

        L1NativeTokenVault vault = L1NativeTokenVault(l1NativeTokenVault);
        address nullifier = address(vault.L1_NULLIFIER());

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 tokenBalance;
            if (tokens[i] != ETH_TOKEN_ADDRESS) {
                uint256 balance = IERC20(tokens[i]).balanceOf(nullifier);
                if (balance != 0) {
                    vm.broadcast();
                    vault.transferFundsFromSharedBridge(tokens[i]);
                }

                vm.broadcast();
                vault.registerToken(tokens[i]);
            } else {
                vm.broadcast();
                vault.registerEthToken();
            }

            // TODO: we need to reduce complexity of this one
            for (uint256 j = 0; j < chains.length; j++) {
                vm.broadcast();
                vault.updateChainBalancesFromSharedBridge(tokens[i], chains[j]);
            }
        }
    }
}
