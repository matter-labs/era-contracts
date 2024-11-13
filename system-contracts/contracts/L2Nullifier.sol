// SPDX-License-Identifier: MIT
// todo delete file
pragma solidity 0.8.24;

import {IL2Nullifier} from "./interfaces/IL2Nullifier.sol";
// import {ISystemContract} from "./interfaces/ISystemContract.sol";
import {BOOTLOADER_FORMAL_ADDRESS} from "./Constants.sol";
// import {IMailbox} from "./interfaces/IMailbox.sol";
import {Unauthorized} from "./SystemContractErrors.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Nullifer contract for L2->L2 txs.
 * @dev
 */
contract L2Nullifier is IL2Nullifier {
    // /// @notice The balances of the users.
    // mapping(bytes32 txHash => bool alreadyExecuted) internal alreadyExecuted;

    // function markAsExecuted(bytes32 txHash) external {
    //     // if (msg.sender != BOOTLOADER_FORMAL_ADDRESS) {
    //     //     revert Unauthorized(msg.sender);
    //     // }
    //     // // solhint-disable-next-line gas-custom-errors
    //     // require(!alreadyExecuted[txHash], "L2N: Already executed");
    //     // alreadyExecuted[txHash] = true;
    // }
}
