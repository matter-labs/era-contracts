// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ContractsBytecodesLib} from "../utils/bytecode/ContractsBytecodesLib.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {Utils} from "../utils/Utils.sol";
import {L2SharedBridgeLegacyDev} from "contracts/dev-contracts/L2SharedBridgeLegacyDev.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

library L2LegacySharedBridgeTestHelper {
    function calculateL2LegacySharedBridgeProxyAddr(
        address l1Erc20BridgeProxy,
        address l1NullifierProxy,
        address ecosystemL1Governance
    ) internal view returns (address) {
        // During local testing, we will deploy `L2SharedBridgeLegacyDev` to each chain
        // that supports the legacy bridge.

        bytes32 implHash = L2ContractHelper.hashL2Bytecode(
            ContractsBytecodesLib.getCreationCode("L2SharedBridgeLegacyDev")
        );
        address implAddress = Utils.getL2AddressViaCreate2Factory(bytes32(0), implHash, hex"");

        bytes32 proxyHash = L2ContractHelper.hashL2Bytecode(
            ContractsBytecodesLib.getCreationCode("TransparentUpgradeableProxy")
        );

        return
            Utils.getL2AddressViaCreate2Factory(
                bytes32(0),
                proxyHash,
                getLegacySharedBridgeProxyConstructorParams(
                    implAddress,
                    l1Erc20BridgeProxy,
                    l1NullifierProxy,
                    ecosystemL1Governance
                )
            );
    }

    function getLegacySharedBridgeProxyConstructorParams(
        address _implAddress,
        address _l1Erc20BridgeProxy,
        address _l1NullifierProxy,
        address _ecosystemL1Governance
    ) internal view returns (bytes memory) {
        bytes32 beaconProxyBytecodeHash = L2ContractHelper.hashL2Bytecode(
            ContractsBytecodesLib.getCreationCode("BeaconProxy")
        );

        bytes memory initializeData = abi.encodeCall(
            L2SharedBridgeLegacyDev.initializeDevBridge,
            (
                _l1Erc20BridgeProxy,
                // While the variable is named `sharedBridge`, in reality it will have the same
                // address as the nullifier
                _l1NullifierProxy,
                beaconProxyBytecodeHash,
                AddressAliasHelper.applyL1ToL2Alias(_ecosystemL1Governance)
            )
        );

        return abi.encode(_implAddress, AddressAliasHelper.applyL1ToL2Alias(_ecosystemL1Governance), initializeData);
    }

    function calculateTestL2TokenBeaconAddress(
        address l1Erc20BridgeProxy,
        address l1NullifierProxy,
        address ecosystemL1Governance
    ) internal view returns (address tokenBeaconAddress, bytes32 tokenBeaconProxyBytecodeHash) {
        address l2SharedBridgeAddress = calculateL2LegacySharedBridgeProxyAddr(
            l1Erc20BridgeProxy,
            l1NullifierProxy,
            ecosystemL1Governance
        );

        bytes32 bridgedL2ERC20Hash = L2ContractHelper.hashL2Bytecode(
            ContractsBytecodesLib.getCreationCode("BridgedStandardERC20")
        );
        address bridgeL2ERC20ImplAddress = L2ContractHelper.computeCreate2Address(
            l2SharedBridgeAddress,
            bytes32(0),
            bridgedL2ERC20Hash,
            keccak256(hex"")
        );

        bytes32 tokenBeaconBytecodeHash = L2ContractHelper.hashL2Bytecode(
            ContractsBytecodesLib.getCreationCode("UpgradeableBeacon")
        );
        tokenBeaconProxyBytecodeHash = L2ContractHelper.hashL2Bytecode(
            ContractsBytecodesLib.getCreationCode("BeaconProxy")
        );
        tokenBeaconAddress = L2ContractHelper.computeCreate2Address(
            l2SharedBridgeAddress,
            bytes32(0),
            tokenBeaconBytecodeHash,
            keccak256(abi.encode(bridgeL2ERC20ImplAddress))
        );
    }
}
