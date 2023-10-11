// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./ChainBase.sol";
import {EMPTY_STRING_KECCAK} from "../../common/Config.sol";
import "../chain-interfaces/IChainExecutor.sol";
import "../../common/libraries/UncheckedMath.sol";
// import "../../common/libraries/UnsafeBytes.sol";
import "../../common/libraries/L2ContractHelper.sol";
import {L2_BOOTLOADER_ADDRESS, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR,
     L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR} from "../../common/L2ContractAddresses.sol";

/// @title zkSync Executor contract capable of processing events emitted in the zkSync protocol.
/// @author Matter Labs
contract ChainExecutor is IChainExecutor, ChainBase {
    using UncheckedMath for uint256;

    /// @notice Commit batch
    function executeBlocks() external override nonReentrant {}
}
