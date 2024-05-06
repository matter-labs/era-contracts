// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";

import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";

library Utils {
    // Cheatcodes address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    // Create2Factory deterministic bytecode.
    // https://github.com/Arachnid/deterministic-deployment-proxy
    bytes internal constant CREATE2_FACTORY_BYTECODE =
        hex"604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    Vm internal constant vm = Vm(VM_ADDRESS);

    /**
     * @dev Get all selectors from the bytecode.
     *
     * Selectors are extracted by calling `cast selectors <bytecode>` from foundry.
     * Then, the result is parsed to extract the selectors, removing
     * the `getName()` selector if existing.
     */
    function getAllSelectors(bytes memory bytecode) internal returns (bytes4[] memory) {
        string[] memory input = new string[](3);
        input[0] = "cast";
        input[1] = "selectors";
        input[2] = vm.toString(bytecode);
        bytes memory result = vm.ffi(input);
        string memory stringResult = string(abi.encodePacked(result));

        // Extract selectors from the result
        string[] memory parts = vm.split(stringResult, "\n");
        bytes4[] memory selectors = new bytes4[](parts.length);
        for (uint256 i = 0; i < parts.length; i++) {
            bytes memory part = bytes(parts[i]);
            bytes memory extractedSelector = new bytes(10);
            // Selector length 10 is 0x + 4 bytes
            for (uint256 j = 0; j < 10; j++) {
                extractedSelector[j] = part[j];
            }
            bytes4 selector = bytes4(vm.parseBytes(string(extractedSelector)));
            selectors[i] = selector;
        }

        // Remove `getName()` selector if existing
        bool hasGetName = false;
        for (uint256 i = 0; i < selectors.length; i++) {
            if (selectors[i] == bytes4(keccak256("getName()"))) {
                selectors[i] = selectors[selectors.length - 1];
                hasGetName = true;
                break;
            }
        }
        if (hasGetName) {
            bytes4[] memory newSelectors = new bytes4[](selectors.length - 1);
            for (uint256 i = 0; i < selectors.length - 1; i++) {
                newSelectors[i] = selectors[i];
            }
            return newSelectors;
        }

        return selectors;
    }

    function getAdminSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = AdminFacet.setPendingAdmin.selector;
        selectors[1] = AdminFacet.acceptAdmin.selector;
        selectors[2] = AdminFacet.setValidator.selector;
        selectors[3] = AdminFacet.setPorterAvailability.selector;
        selectors[4] = AdminFacet.setPriorityTxMaxGasLimit.selector;
        selectors[5] = AdminFacet.changeFeeParams.selector;
        selectors[6] = AdminFacet.setTokenMultiplier.selector;
        selectors[7] = AdminFacet.upgradeChainFromVersion.selector;
        selectors[8] = AdminFacet.executeUpgrade.selector;
        selectors[9] = AdminFacet.freezeDiamond.selector;
        selectors[10] = AdminFacet.unfreezeDiamond.selector;
        return selectors;
    }

    function getExecutorSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = ExecutorFacet.commitBatches.selector;
        selectors[1] = ExecutorFacet.proveBatches.selector;
        selectors[2] = ExecutorFacet.executeBatches.selector;
        selectors[3] = ExecutorFacet.revertBatches.selector;
        return selectors;
    }

    function getGettersSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](29);
        selectors[0] = GettersFacet.getVerifier.selector;
        selectors[1] = GettersFacet.getAdmin.selector;
        selectors[2] = GettersFacet.getPendingAdmin.selector;
        selectors[3] = GettersFacet.getTotalBlocksCommitted.selector;
        selectors[4] = GettersFacet.getTotalBlocksVerified.selector;
        selectors[5] = GettersFacet.getTotalBlocksExecuted.selector;
        selectors[6] = GettersFacet.getTotalPriorityTxs.selector;
        selectors[7] = GettersFacet.getFirstUnprocessedPriorityTx.selector;
        selectors[8] = GettersFacet.getPriorityQueueSize.selector;
        selectors[9] = GettersFacet.priorityQueueFrontOperation.selector;
        selectors[10] = GettersFacet.isValidator.selector;
        selectors[11] = GettersFacet.l2LogsRootHash.selector;
        selectors[12] = GettersFacet.storedBatchHash.selector;
        selectors[13] = GettersFacet.getL2BootloaderBytecodeHash.selector;
        selectors[14] = GettersFacet.getL2DefaultAccountBytecodeHash.selector;
        selectors[15] = GettersFacet.getVerifierParams.selector;
        selectors[16] = GettersFacet.isDiamondStorageFrozen.selector;
        selectors[17] = GettersFacet.getPriorityTxMaxGasLimit.selector;
        selectors[18] = GettersFacet.isEthWithdrawalFinalized.selector;
        selectors[19] = GettersFacet.facets.selector;
        selectors[20] = GettersFacet.facetFunctionSelectors.selector;
        selectors[21] = GettersFacet.facetAddresses.selector;
        selectors[22] = GettersFacet.facetAddress.selector;
        selectors[23] = GettersFacet.isFunctionFreezable.selector;
        selectors[24] = GettersFacet.isFacetFreezable.selector;
        selectors[25] = GettersFacet.getTotalBatchesCommitted.selector;
        selectors[26] = GettersFacet.getTotalBatchesVerified.selector;
        selectors[27] = GettersFacet.getTotalBatchesExecuted.selector;
        selectors[28] = GettersFacet.getL2SystemContractsUpgradeTxHash.selector;
        return selectors;
    }

    function getMailboxSelectors() public pure returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = MailboxFacet.proveL2MessageInclusion.selector;
        selectors[1] = MailboxFacet.proveL2LogInclusion.selector;
        selectors[2] = MailboxFacet.proveL1ToL2TransactionStatus.selector;
        selectors[3] = MailboxFacet.finalizeEthWithdrawal.selector;
        selectors[4] = MailboxFacet.requestL2Transaction.selector;
        selectors[5] = MailboxFacet.bridgehubRequestL2Transaction.selector;
        selectors[6] = MailboxFacet.l2TransactionBaseCost.selector;
        return selectors;
    }

    /**
     * @dev Extract an address from bytes.
     */
    function bytesToAddress(bytes memory bys) internal pure returns (address addr) {
        assembly {
            addr := mload(add(bys, 20))
        }
    }

    /**
     * @dev Extract a uint256 from bytes.
     */
    function bytesToUint256(bytes memory bys) internal pure returns (uint256 value) {
        // Add left padding to 32 bytes if needed
        if (bys.length < 32) {
            bytes memory padded = new bytes(32);
            for (uint256 i = 0; i < bys.length; i++) {
                padded[i + 32 - bys.length] = bys[i];
            }
            bys = padded;
        }

        assembly {
            value := mload(add(bys, 0x20))
        }
    }

    /**
     * @dev Returns the bytecode hash of the batch bootloader.
     */
    function getBatchBootloaderBytecodeHash() internal view returns (bytes memory) {
        return vm.readFileBinary("../../../system-contracts/bootloader/build/artifacts/proved_batch.yul.zbin");
    }

    /**
     * @dev Returns the bytecode of a given system contract.
     */
    function readSystemContractsBytecode(string memory filename) internal view returns (bytes memory) {
        string memory file = vm.readFile(
            // solhint-disable-next-line func-named-parameters
            string.concat(
                "../system-contracts/artifacts-zk/contracts-preprocessed/", filename, ".sol/", filename, ".json"
            )
        );
        bytes memory bytecode = vm.parseJson(file, "$.bytecode");
        return bytecode;
    }

    /**
     * @dev Deploy a Create2Factory contract.
     */
    function deployCreate2Factory() internal returns (address) {
        address child;
        bytes memory bytecode = CREATE2_FACTORY_BYTECODE;
        vm.startBroadcast();
        assembly {
            child := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        vm.stopBroadcast();
        require(child != address(0), "Failed to deploy Create2Factory");
        require(child.code.length > 0, "Failed to deploy Create2Factory");
        return child;
    }

    /**
     * @dev Deploys contract using CREATE2.
     */
    function deployViaCreate2(bytes memory _bytecode, bytes32 _salt, address _factory) internal returns (address) {
        if (_bytecode.length == 0) {
            revert("Bytecode is not set");
        }
        address contractAddress = vm.computeCreate2Address(_salt, keccak256(_bytecode), _factory);
        if (contractAddress.code.length != 0) {
            return contractAddress;
        }

        vm.broadcast();
        (bool success, bytes memory data) = _factory.call(abi.encodePacked(_salt, _bytecode));
        contractAddress = Utils.bytesToAddress(data);

        if (!success || contractAddress == address(0) || contractAddress.code.length == 0) {
            revert("Failed to deploy contract via create2");
        }

        return contractAddress;
    }
}
