// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @notice `getChainId()` is a Foundry cheatcode missing from the vendored forge-std.
/// @dev Save the chain id through it before `vm.chainId`: an optimizer may treat `block.chainid` as constant
/// within a transaction and read CHAINID again at the restore, after the cheatcode changed it.
interface IVmChainId {
    function getChainId() external view returns (uint256);
}
