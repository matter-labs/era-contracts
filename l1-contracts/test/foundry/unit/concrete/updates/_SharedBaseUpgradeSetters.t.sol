// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ZkSyncHyperchainBase} from "contracts/state-transition/chain-deps/facets/ZkSyncHyperchainBase.sol";

contract BaseUpgradeSetters is Test, ZkSyncHyperchainBase {
    function setL2SystemContractsUpgradeTxHash(bytes32 _l2SystemContractsUpgradeTxHash) public {
        s.l2SystemContractsUpgradeTxHash = _l2SystemContractsUpgradeTxHash;
    }

    function setL2SystemContractsUpgradeBatchNumber(uint256 _l2SystemContractsUpgradeBatchNumber) public {
        s.l2SystemContractsUpgradeBatchNumber = _l2SystemContractsUpgradeBatchNumber;
    }

    function setPriorityTxMaxGasLimit(uint256 _priorityTxMaxGasLimit) public {
        s.priorityTxMaxGasLimit = _priorityTxMaxGasLimit;
    }

    function setPriorityTxMaxPubdata(uint32 _priorityTxMaxPubdata) public {
        s.feeParams.priorityTxMaxPubdata = _priorityTxMaxPubdata;
    }

    function setProtocolVersion(uint256 _protocolVersion) public {
        s.protocolVersion = _protocolVersion;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
