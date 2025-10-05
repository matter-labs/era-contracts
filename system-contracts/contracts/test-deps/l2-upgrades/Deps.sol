// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

uint160 constant SYSTEM_CONTRACTS_OFFSET = 0x8000; // 2^15
address constant L2_DEPLOYER_SYSTEM_CONTRACT_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x06);
address constant L2_FORCE_DEPLOYER_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x07);
address constant L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x0b);

address constant GW_ASSET_TRACKER_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x0f);
address constant L2_ASSET_TRACKER_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x0e);
address constant L2_ASSET_ROUTER_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x03);
address constant L2_BRIDGEHUB_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x02);
address constant L2_CHAIN_ASSET_HANDLER_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x0a);
address constant L2_DEPLOYER_SYSTEM_CONTRACT_ADDR = address(SYSTEM_CONTRACTS_OFFSET + 0x06);
address constant L2_MESSAGE_ROOT_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x05);
address constant L2_NATIVE_TOKEN_VAULT_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x04);
address constant L2_NTV_BEACON_DEPLOYER_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x0b);
address constant L2_WRAPPED_BASE_TOKEN_IMPL_ADDR = address(BUILT_IN_CONTRACTS_OFFSET + 0x07);


error Unauthorized(address sender);
error AddressHasNoCode(address addr);
error InvalidChainId();
