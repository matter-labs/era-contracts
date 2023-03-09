// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./libraries/EfficientCall.sol";
import {SystemContractHelper, ISystemContract} from "./libraries/SystemContractHelper.sol";
import {MSG_VALUE_SIMULATOR_IS_SYSTEM_BIT, ETH_TOKEN_SYSTEM_CONTRACT, MAX_MSG_VALUE} from "./Constants.sol";

/**
 * @author Matter Labs
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

    fallback(bytes calldata _data) external payable onlySystemCall returns (bytes memory) {
        (uint256 value, bool isSystemCall, address to) = _getAbiParams();

        if (value != 0) {
            (bool success, ) = address(ETH_TOKEN_SYSTEM_CONTRACT).call(
                abi.encodeCall(ETH_TOKEN_SYSTEM_CONTRACT.transferFromTo, (msg.sender, to, value))
            );

            // If the transfer of ETH fails, we do the most Ethereum-like behaviour in such situation: revert(0,0)
            if(!success) {
                assembly {
                    revert(0,0)
                }
            }
        }

        if(value > MAX_MSG_VALUE) {
            // The if above should never be true, since noone should be able to have 
            // MAX_MSG_VALUE wei of ether. However, if it does happen for some reason,
            // we will revert(0,0).
            // Note, that we use raw revert here instead of `panic` to emulate behaviour close to 
            // the EVM's one, i.e. returndata should be empty.
            assembly {
                return(0,0)
            }
        }

        // For the next call this `msg.value` will be used.
        SystemContractHelper.setValueForNextFarCall(uint128(value));

        return EfficientCall.mimicCall(gasleft(), to, _data, msg.sender, false, isSystemCall);
    }
}
