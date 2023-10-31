// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "./libraries/Utils.sol";
import "./libraries/EfficientCall.sol";
import "./interfaces/ISystemContract.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {MSG_VALUE_SIMULATOR_IS_SYSTEM_BIT, ETH_TOKEN_SYSTEM_CONTRACT} from "./Constants.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract responsible for simulating transactions with `msg.value` inside zkEVM.
 * @dev It accepts value and whether the call should be system in the first extraAbi param and
 * the address to call in the second extraAbi param, transfers the funds and uses `mimicCall` to continue the
 * call with the same msg.sender.
 */
contract MsgValueSimulator is ISystemContract {
    /// @notice Extract value, isSystemCall and to from the extraAbi params.
    /// @dev The contract accepts value, the callee and whether the call should a system one via its ABI params.
    /// @dev The first ABI param contains the value in the [0..127] bits. The 128th contains
    /// the flag whether or not the call should be a system one.
    /// The second ABI params contains the callee.
    function _getAbiParams() internal view returns (uint256 value, bool isSystemCall, address to) {
        value = SystemContractHelper.getExtraAbiData(0);
        uint256 addressAsUint = SystemContractHelper.getExtraAbiData(1);
        uint256 mask = SystemContractHelper.getExtraAbiData(2);

        isSystemCall = (mask & MSG_VALUE_SIMULATOR_IS_SYSTEM_BIT) != 0;

        to = address(uint160(addressAsUint));
    }

    fallback(bytes calldata _data) external onlySystemCall returns (bytes memory) {
        (uint256 value, bool isSystemCall, address to) = _getAbiParams();

        // Prevent mimic call to the MsgValueSimulator to prevent an unexpected change of callee.
        require(to != address(this), "MsgValueSimulator calls itself");

        if (value != 0) {
            (bool success, ) = address(ETH_TOKEN_SYSTEM_CONTRACT).call(
                abi.encodeCall(ETH_TOKEN_SYSTEM_CONTRACT.transferFromTo, (msg.sender, to, value))
            );

            // If the transfer of ETH fails, we do the most Ethereum-like behaviour in such situation: revert(0,0)
            if (!success) {
                assembly {
                    revert(0, 0)
                }
            }
        }

        // For the next call this `msg.value` will be used.
        SystemContractHelper.setValueForNextFarCall(Utils.safeCastToU128(value));

        return EfficientCall.mimicCall(gasleft(), to, _data, msg.sender, false, isSystemCall);
    }
}
