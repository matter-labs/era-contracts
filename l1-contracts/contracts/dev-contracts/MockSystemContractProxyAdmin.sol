// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockSystemContractProxyAdmin
/// @notice Mock for the ZKsyncOS SystemContractProxyAdmin (address 0x1000c).
/// @dev In production (ZKsyncOS), SystemContractProxyAdmin.upgrade() calls
/// proxy.upgradeTo(impl) to point SystemContractProxy to a new implementation.
/// On Anvil EVM, the system contract addresses hold EVM implementation bytecodes
/// directly (not SystemContractProxy bytecodes), so the upgrade() call must be
/// a no-op to preserve the pre-deployed EVM bytecodes at those addresses.
contract MockSystemContractProxyAdmin {
    fallback() external payable {
        // No-op: proxy upgrades are handled via anvil_setCode in the test harness
    }

    receive() external payable {}
}
