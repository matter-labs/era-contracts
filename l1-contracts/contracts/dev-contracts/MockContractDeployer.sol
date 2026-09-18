// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockContractDeployer
/// @notice Mock for the ZK-VM ContractDeployer system contract (address 0x8006).
/// @dev In production (zkVM), ContractDeployer.forceDeployOnAddresses deploys
/// bytecode at arbitrary addresses.  On Anvil EVM this is impossible from
/// within a contract, so the test infrastructure pre-deploys all needed
/// bytecodes via anvil_setCode *before* relaying the upgrade tx and this
/// mock simply no-ops so the call chain does not revert.
contract MockContractDeployer {
    fallback() external payable {
        // No-op: force deployments are handled via anvil_setCode in the test harness
    }

    receive() external payable {}
}
