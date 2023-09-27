// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../zksync/interfaces/IZkSync.sol";
import "../../vendor/AddressAliasHelper.sol";
import "../../common/libraries/L2ContractHelper.sol";
import {L2_DEPLOYER_SYSTEM_CONTRACT_ADDR} from "../../common/L2ContractAddresses.sol";
import "../../common/interfaces/IL2ContractDeployer.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev A helper library for initializing L2 bridges in zkSync L2 network.
library BridgeInitializationHelper {
    /// @dev The L2 gas limit for requesting L1 -> L2 transaction of deploying L2 bridge instance.
    /// @dev It is big enough to deploy any contract, so we can use the same value for all bridges.
    /// NOTE: this constant will be accurately calculated in the future.
    uint256 constant DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT = $(DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT);

    /// @dev The default l2GasPricePerPubdata to be used in bridges.
    uint256 constant REQUIRED_L2_GAS_PRICE_PER_PUBDATA = $(REQUIRED_L2_GAS_PRICE_PER_PUBDATA);

    /// @notice Requests L2 transaction that will deploy a contract with a given bytecode hash and constructor data.
    /// NOTE: it is always used to deploy via create2 with ZERO salt
    /// @param _zkSync The address of the zkSync contract
    /// @param _deployTransactionFee The fee that will be paid for the L1 -> L2 transaction
    /// @param _bytecodeHash The hash of the bytecode of the contract to be deployed
    /// @param _constructorData The data to be passed to the contract constructor
    /// @param _factoryDeps A list of raw bytecodes that are needed for deployment
    function requestDeployTransaction(
        IZkSync _zkSync,
        uint256 _deployTransactionFee,
        bytes32 _bytecodeHash,
        bytes memory _constructorData,
        bytes[] memory _factoryDeps
    ) internal returns (address deployedAddress) {
        bytes memory deployCalldata = abi.encodeCall(
            IL2ContractDeployer.create2,
            (bytes32(0), _bytecodeHash, _constructorData)
        );
        _zkSync.requestL2Transaction{value: _deployTransactionFee}(
            L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
            0,
            deployCalldata,
            DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _factoryDeps,
            msg.sender
        );

        deployedAddress = L2ContractHelper.computeCreate2Address(
            // Apply the alias to the address of the bridge contract, to get the `msg.sender` in L2.
            AddressAliasHelper.applyL1ToL2Alias(address(this)),
            bytes32(0), // Zero salt
            _bytecodeHash,
            keccak256(_constructorData)
        );
    }
}
