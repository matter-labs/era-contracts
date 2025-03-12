// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Utils, L2_BRIDGEHUB_ADDRESS, L2_ASSET_ROUTER_ADDRESS, L2_NATIVE_TOKEN_VAULT_ADDRESS, L2_MESSAGE_ROOT_ADDRESS} from "../Utils.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {L2ContractsBytecodesLib} from "../L2ContractsBytecodesLib.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {Call as GovernanceCall} from "contracts/governance/Common.sol"; // renamed to avoid conflict
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {MulticallWithGas} from "./MulticallWithGas.sol";

/// @notice Script intended to help us finalize the governance upgrade
contract FinalizeUpgrade is Script {
    using stdToml for string;

    function initChains(address bridgehub, uint256[] calldata chains) external {
        // We do not change this method
        for (uint256 i = 0; i < chains.length; ++i) {
            Bridgehub bh = Bridgehub(bridgehub);

            if (bh.baseTokenAssetId(chains[i]) == bytes32(0)) {
                vm.broadcast();
                Bridgehub(bridgehub).registerLegacyChain(chains[i]);
            }
        }
    }

    function initTokens(
        address payable l1NativeTokenVault,
        address[] calldata tokens,
        uint256[] calldata chains
    ) external {
        // We do not change this method
        L1NativeTokenVault vault = L1NativeTokenVault(l1NativeTokenVault);
        address nullifier = address(vault.L1_NULLIFIER());

        for (uint256 i = 0; i < tokens.length; i++) {
            if (vault.assetId(tokens[i]) == bytes32(0)) {
                if (tokens[i] != ETH_TOKEN_ADDRESS) {
                    uint256 balance = IERC20(tokens[i]).balanceOf(nullifier);
                    if (balance != 0) {
                        vm.broadcast();
                        vault.transferFundsFromSharedBridge(tokens[i]);
                    } else {
                        vm.broadcast();
                        vault.registerToken(tokens[i]);
                    }
                } else {
                    vm.broadcast();
                    vault.registerEthToken();

                    uint256 balance = address(nullifier).balance;
                    if (balance != 0) {
                        vm.broadcast();
                        vault.transferFundsFromSharedBridge(tokens[i]);
                    }
                }
            }

            for (uint256 j = 0; j < chains.length; j++) {
                vm.broadcast();
                vault.updateChainBalancesFromSharedBridge(tokens[i], chains[j]);
            }
        }
    }

    uint256 constant GAS_PER_TX = 500_000; // Adjust as needed
    uint256 constant MAX_CALLS_PER_BATCH = 15; // Adjust as needed

    // Helper function to flush calls to aggregator
    function flushBatch(MulticallWithGas _aggregator, MulticallWithGas.Call[] memory _calls, uint256 _count) internal {
        if (_count == 0) {
            return; // nothing to flush
        }
        // Create a smaller array of exactly _count size
        MulticallWithGas.Call[] memory batch = new MulticallWithGas.Call[](_count);
        for (uint256 k = 0; k < _count; k++) {
            batch[k] = _calls[k];
        }

        // We can do a single broadcast for the entire batch
        vm.broadcast();
        _aggregator.aggregate{gas: _count * GAS_PER_TX + 1_000_000}(batch, false);
    }

    // Helper function to add a call to our current calls buffer
    function addCall(
        MulticallWithGas.Call[] memory _calls,
        uint256 _callIndex,
        address _to,
        bytes memory _data
    ) internal returns (uint256) {
        _calls[_callIndex] = MulticallWithGas.Call({to: _to, gasLimit: GAS_PER_TX, data: _data});

        return _callIndex + 1; // increment the pointer
    }

    /// @notice Combines the logic of `initChains` and `initTokens`, but
    ///         uses MulticallWithGas to batch these calls in chunks.
    ///
    /// @param bridgehub Address of the Bridgehub contract
    /// @param l1NativeTokenVault Address of the L1NativeTokenVault contract
    /// @param tokens Array of token addresses to initialize
    /// @param chains Array of chain IDs to register & update balances
    function finalizeInit(
        MulticallWithGas aggregator,
        address bridgehub,
        address payable l1NativeTokenVault,
        address[] calldata tokens,
        uint256[] calldata chains
    ) external {
        // We'll build up an array of aggregator calls in memory.
        // Because memory arrays in Solidity are fixed-length once created,
        // we'll do an approach that increments a pointer until we hit the max,
        // then flushes to the aggregator.

        MulticallWithGas.Call[] memory calls = new MulticallWithGas.Call[](MAX_CALLS_PER_BATCH);
        uint256 callIndex = 0;

        // ---------------------------------------------------
        // 1. Combine logic of initChains
        // ---------------------------------------------------
        for (uint256 i = 0; i < chains.length; i++) {
            Bridgehub bh = Bridgehub(bridgehub);
            if (bh.baseTokenAssetId(chains[i]) == bytes32(0)) {
                // Register legacy chain if needed
                bytes memory data = abi.encodeWithSelector(Bridgehub.registerLegacyChain.selector, chains[i]);

                // Add call to aggregator calls array
                callIndex = addCall(calls, callIndex, bridgehub, data);

                // If we've hit max calls, flush
                if (callIndex == MAX_CALLS_PER_BATCH) {
                    flushBatch(aggregator, calls, callIndex);
                    callIndex = 0;
                }
            }
        }

        // ---------------------------------------------------
        // 2. Combine logic of initTokens
        // ---------------------------------------------------
        L1NativeTokenVault vault = L1NativeTokenVault(l1NativeTokenVault);
        address nullifier = address(vault.L1_NULLIFIER());

        for (uint256 i = 0; i < tokens.length; i++) {
            // Check if token is already registered
            if (vault.assetId(tokens[i]) == bytes32(0)) {
                // If not, we either register or transfer funds
                if (tokens[i] != ETH_TOKEN_ADDRESS) {
                    uint256 balance = IERC20(tokens[i]).balanceOf(nullifier);
                    if (balance != 0) {
                        // aggregator call: vault.transferFundsFromSharedBridge(tokens[i])
                        bytes memory data = abi.encodeWithSelector(
                            vault.transferFundsFromSharedBridge.selector,
                            tokens[i]
                        );
                        callIndex = addCall(calls, callIndex, l1NativeTokenVault, data);
                    } else {
                        // aggregator call: vault.registerToken(tokens[i])
                        bytes memory data = abi.encodeWithSelector(vault.registerToken.selector, tokens[i]);
                        callIndex = addCall(calls, callIndex, l1NativeTokenVault, data);
                    }
                } else {
                    // aggregator call: vault.registerEthToken()
                    {
                        bytes memory data = abi.encodeWithSelector(vault.registerEthToken.selector);
                        callIndex = addCall(calls, callIndex, l1NativeTokenVault, data);
                    }

                    if (callIndex == MAX_CALLS_PER_BATCH) {
                        flushBatch(aggregator, calls, callIndex);
                        callIndex = 0;
                    }

                    uint256 balance = address(nullifier).balance;
                    if (balance != 0) {
                        // aggregator call: vault.transferFundsFromSharedBridge(ETH_TOKEN_ADDRESS)
                        bytes memory data = abi.encodeWithSelector(
                            vault.transferFundsFromSharedBridge.selector,
                            tokens[i]
                        );
                        callIndex = addCall(calls, callIndex, l1NativeTokenVault, data);
                    }
                }

                // Flush if needed
                if (callIndex == MAX_CALLS_PER_BATCH) {
                    flushBatch(aggregator, calls, callIndex);
                    callIndex = 0;
                }
            }

            // For every (token, chain) combination, aggregator call: updateChainBalancesFromSharedBridge
            for (uint256 j = 0; j < chains.length; j++) {
                if (L1Nullifier(nullifier).chainBalance(chains[j], tokens[i]) == 0) {
                    continue;
                }

                bytes memory data = abi.encodeWithSelector(
                    vault.updateChainBalancesFromSharedBridge.selector,
                    tokens[i],
                    chains[j]
                );
                callIndex = addCall(calls, callIndex, l1NativeTokenVault, data);

                if (callIndex == MAX_CALLS_PER_BATCH) {
                    flushBatch(aggregator, calls, callIndex);
                    callIndex = 0;
                }
            }
        }

        // ---------------------------------------------------
        // 3. Final flush if there's anything left in the buffer
        // ---------------------------------------------------
        flushBatch(aggregator, calls, callIndex);

        console.log("Batched calls successfully sent via MulticallWithGas.");
    }
}
