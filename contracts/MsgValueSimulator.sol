// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./libraries/Utils.sol";
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
    /// @notice The gas cost for paying for the computational part of gas while making the eth transfer.
    uint256 constant public TOKEN_TRANSFER_COMPUTATION_GAS_COST = 8000;

    /// @notice The maximal gas cost for the decommitment of the callee contract. Note, that on zkSync,
    /// the whenever a contract is called the cost of decommitment of the bytecode is charged. This cost is 
    /// proportional to the size of the bytecode of the callee. If the bytecode has been already decommitted in the 
    /// current batch, then the decommitment will be refunded in-place. Note, however, that the user must still have
    /// enough funds for the decommitment.
    uint256 constant public DECOMMIT_OVERHEAD_COST = 64000;

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

    /// @notice Calculate the amount of gas needed for performing changing eth balances of the sender and receiver when the storage is cold.
    /// @return The gas cost for paying to the pubdata while making the eth transfer.
    function _getTokenTransferPubdataCost() internal view returns (uint256) {
        // Get the cost of 1 pubdata byte in L2 gas
        uint256 meta = SystemContractHelper.getZkSyncMetaBytes();
        uint256 pricePerPubdataByteInGas = SystemContractHelper.getGasPerPubdataByteFromMeta(meta);

        // 2 storage slot, each hash 32 bytes of key and 32 bytes of the value.
        // Note, that while in theory the balance of the sender is either empty or already edited (i.e. will not cost 64 bytes), 
        // it is better to keep the 64 number here to be future-proof against malicious validators. 
        return pricePerPubdataByteInGas * 64 * 2;
    }

    fallback(bytes calldata _data) external onlySystemCall returns (bytes memory) {
        // Save the gas before the start of the call.
        uint256 gasBefore = gasleft();
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

        // Calculate the spent gas for the transferring ether.
        uint256 gasSpent = gasBefore - gasleft();
        uint256 totalExpectedTransferGasCost = _getTokenTransferPubdataCost() + TOKEN_TRANSFER_COMPUTATION_GAS_COST;
        // The amount of gas that was reserved for the token transferring but is unspent
        uint256 unspendGas = totalExpectedTransferGasCost > gasSpent ? totalExpectedTransferGasCost - gasSpent : 0;

        // Note: reducing DECOMMIT_OVERHEAD_COST. The `DECOMMIT_OVERHEAD_COST` is guaranteed to be provided to the msg value simulator
        return EfficientCall.mimicCall(gasleft() - unspendGas - DECOMMIT_OVERHEAD_COST, to, _data, msg.sender, false, isSystemCall);
    }
}
