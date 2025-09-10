// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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

import {L1Bridgehub} from "contracts/bridgehub/L1Bridgehub.sol";
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
            L1Bridgehub bh = L1Bridgehub(bridgehub);

            if (bh.baseTokenAssetId(chains[i]) == bytes32(0)) {
                vm.broadcast();
                L1Bridgehub(bridgehub).registerLegacyChain(chains[i]);
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

    function saturatingSub(uint256 x, uint256 y) internal pure returns (uint256) {
        if (x < y) {
            return 0;
        } else {
            return x - y;
        }
    }

    struct FinalizeInitParams {
        MulticallWithGas aggregator;
        address bridgehub;
        address payable l1NativeTokenVault;
        address[] tokens;
        uint256[] chains;
        address[] pairToken;
        uint256[] pairChainId;
    }

    function finalizeInitInner(FinalizeInitParams memory params) internal {
        // We'll build up an array of aggregator calls in memory.
        // Because memory arrays in Solidity are fixed-length once created,
        // we'll do an approach that increments a pointer until we hit the max,
        // then flushes to the aggregator.

        MulticallWithGas.Call[] memory calls = new MulticallWithGas.Call[](MAX_CALLS_PER_BATCH);
        uint256 callIndex = 0;

        // Preventing stack too deep error
        {
            console.log(
                "Total number of items to process: ",
                params.tokens.length + params.chains.length + params.pairToken.length
            );
            console.log("Tokens: ", params.tokens.length);
            console.log("Chains: ", params.chains.length);
            console.log("Pairs: ", params.pairToken.length);
            uint256 currentPosition = vm.envUint("START_SEGMENT");
            uint256 currentEnd = vm.envUint("END_SEGMENT");

            console.log("Processing the following segment :");
            console.log("Start: ", currentPosition);
            console.log("End: ", currentEnd);

            // ---------------------------------------------------
            // 1. Combine logic of initChains
            // ---------------------------------------------------
            for (uint256 i = currentPosition; i < params.chains.length && i < currentEnd; i++) {
                L1Bridgehub bh = L1Bridgehub(params.bridgehub);
                console.log("Processing chain: ", params.chains[i]);
                if (bh.baseTokenAssetId(params.chains[i]) == bytes32(0)) {
                    // Register legacy chain if needed
                    bytes memory data = abi.encodeWithSelector(
                        L1Bridgehub.registerLegacyChain.selector,
                        params.chains[i]
                    );

                    // Add call to aggregator calls array
                    callIndex = addCall(calls, callIndex, params.bridgehub, data);

                    // If we've hit max calls, flush
                    if (callIndex == MAX_CALLS_PER_BATCH) {
                        flushBatch(params.aggregator, calls, callIndex);
                        callIndex = 0;
                    }
                }
            }

            currentPosition = saturatingSub(currentPosition, params.chains.length);
            currentEnd = saturatingSub(currentEnd, params.chains.length);

            // ---------------------------------------------------
            // 2. Combine logic of initTokens
            // ---------------------------------------------------
            L1NativeTokenVault vault = L1NativeTokenVault(params.l1NativeTokenVault);
            address nullifier = address(vault.L1_NULLIFIER());

            for (uint256 i = currentPosition; i < params.tokens.length && i < currentEnd; i++) {
                console.log("Processing token: ", params.tokens[i]);

                // Check if token is already registered
                if (vault.assetId(params.tokens[i]) == bytes32(0)) {
                    // If not, we either register or transfer funds
                    if (params.tokens[i] != ETH_TOKEN_ADDRESS) {
                        uint256 balance = IERC20(params.tokens[i]).balanceOf(nullifier);
                        if (balance != 0) {
                            // aggregator call: vault.transferFundsFromSharedBridge(tokens[i])
                            bytes memory data = abi.encodeWithSelector(
                                vault.transferFundsFromSharedBridge.selector,
                                params.tokens[i]
                            );
                            callIndex = addCall(calls, callIndex, params.l1NativeTokenVault, data);
                        } else {
                            // aggregator call: vault.registerToken(tokens[i])
                            bytes memory data = abi.encodeWithSelector(vault.registerToken.selector, params.tokens[i]);
                            callIndex = addCall(calls, callIndex, params.l1NativeTokenVault, data);
                        }
                    } else {
                        // aggregator call: vault.registerEthToken()
                        {
                            bytes memory data = abi.encodeWithSelector(vault.registerEthToken.selector);
                            callIndex = addCall(calls, callIndex, params.l1NativeTokenVault, data);
                        }

                        if (callIndex == MAX_CALLS_PER_BATCH) {
                            flushBatch(params.aggregator, calls, callIndex);
                            callIndex = 0;
                        }

                        uint256 balance = address(nullifier).balance;
                        if (balance != 0) {
                            // aggregator call: vault.transferFundsFromSharedBridge(ETH_TOKEN_ADDRESS)
                            bytes memory data = abi.encodeWithSelector(
                                vault.transferFundsFromSharedBridge.selector,
                                params.tokens[i]
                            );
                            callIndex = addCall(calls, callIndex, params.l1NativeTokenVault, data);
                        }
                    }

                    // Flush if needed
                    if (callIndex == MAX_CALLS_PER_BATCH) {
                        flushBatch(params.aggregator, calls, callIndex);
                        callIndex = 0;
                    }
                }
            }

            currentPosition = saturatingSub(currentPosition, params.tokens.length);
            currentEnd = saturatingSub(currentEnd, params.tokens.length);

            for (uint256 i = currentPosition; i < params.pairToken.length && i < currentEnd; i++) {
                uint256 chain = params.pairChainId[i];
                address token = params.pairToken[i];

                console.log("Processing pair: ");
                console.log("\tChain: ", chain);
                console.log("\tToken: ", token);

                if (L1Nullifier(nullifier).chainBalance(chain, token) == 0) {
                    continue;
                }

                bytes memory data = abi.encodeWithSelector(
                    vault.updateChainBalancesFromSharedBridge.selector,
                    token,
                    chain
                );
                callIndex = addCall(calls, callIndex, params.l1NativeTokenVault, data);

                if (callIndex == MAX_CALLS_PER_BATCH) {
                    flushBatch(params.aggregator, calls, callIndex);
                    callIndex = 0;
                }
            }
        }

        // ---------------------------------------------------
        // 3. Final flush if there's anything left in the buffer
        // ---------------------------------------------------
        flushBatch(params.aggregator, calls, callIndex);

        console.log("Batched calls successfully sent via MulticallWithGas.");
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
        uint256[] calldata chains,
        address[] calldata pairToken,
        uint256[] calldata pairChainId
    ) external {
        // Using an inner function to prevent "stack too deep" error.
        // I do not use struct rightaway as it makes it harder to encode the input
        // via rust-rs.
        finalizeInitInner(
            FinalizeInitParams({
                aggregator: aggregator,
                bridgehub: bridgehub,
                l1NativeTokenVault: l1NativeTokenVault,
                tokens: tokens,
                chains: chains,
                pairToken: pairToken,
                pairChainId: pairChainId
            })
        );
    }
}
