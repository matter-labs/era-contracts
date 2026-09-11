// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISystemContractDeployer} from "../l2-system/zksync-os/interfaces/ISystemContractDeployer.sol";

/// @title MockContractDeployer
/// @notice Mock for the ZKsync OS contract-deployer system contract (address 0x8006).
/// @dev In production, `ContractDeployer.setBytecodeDetailsEVM` registers bytecode
/// at arbitrary addresses through a system hook. On Anvil EVM this is impossible from
/// within a contract, so the test infrastructure pre-deploys all needed bytecodes via
/// anvil_setCode *before* relaying the upgrade tx, and this mock no-ops the call so the
/// chain does not revert.
///
/// The mock implements the production interface — so the compiler itself pins the mock
/// to the real deployer's ABI — and has deliberately no fallback: a caller using a stale
/// or unexpected selector reverts loudly instead of silently "succeeding", so ABI drift
/// between the harness and the production deployer surfaces immediately.
contract MockContractDeployer is ISystemContractDeployer {
    /// @inheritdoc ISystemContractDeployer
    /// @dev No-op: bytecode placement is handled via anvil_setCode in the test harness.
    function setBytecodeDetailsEVM(address, bytes32, uint32, bytes32) external override {}
}
