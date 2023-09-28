// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// solhint-disable max-line-length

import {Test} from "forge-std/Test.sol";
import {DiamondCutTestContract} from "../../../../../cache/solpp-generated-contracts/dev-contracts/test/DiamondCutTestContract.sol";
import {GettersFacet} from "../../../../../cache/solpp-generated-contracts/zksync/facets/Getters.sol";

// solhint-enable max-line-length

contract DiamondCutTest is Test {
    DiamondCutTestContract internal diamondCutTestContract;
    GettersFacet internal gettersFacet;

    function getGettersSelectors() public view returns (bytes4[] memory) {
        bytes4[] memory selectors = new bytes4[](35);
        selectors[0] = gettersFacet.getVerifier.selector;
        selectors[1] = gettersFacet.getGovernor.selector;
        selectors[2] = gettersFacet.getPendingGovernor.selector;
        selectors[3] = gettersFacet.getTotalBlocksCommitted.selector;
        selectors[4] = gettersFacet.getTotalBlocksVerified.selector;
        selectors[5] = gettersFacet.getTotalBlocksExecuted.selector;
        selectors[6] = gettersFacet.getTotalPriorityTxs.selector;
        selectors[7] = gettersFacet.getFirstUnprocessedPriorityTx.selector;
        selectors[8] = gettersFacet.getPriorityQueueSize.selector;
        selectors[9] = gettersFacet.priorityQueueFrontOperation.selector;
        selectors[10] = gettersFacet.isValidator.selector;
        selectors[11] = gettersFacet.l2LogsRootHash.selector;
        selectors[12] = gettersFacet.storedBatchHash.selector;
        selectors[13] = gettersFacet.getL2BootloaderBytecodeHash.selector;
        selectors[14] = gettersFacet.getL2DefaultAccountBytecodeHash.selector;
        selectors[15] = gettersFacet.getVerifierParams.selector;
        selectors[16] = gettersFacet.isDiamondStorageFrozen.selector;
        selectors[17] = gettersFacet.getSecurityCouncil.selector;
        selectors[18] = gettersFacet.getUpgradeProposalState.selector;
        selectors[19] = gettersFacet.getProposedUpgradeHash.selector;
        selectors[20] = gettersFacet.getProposedUpgradeTimestamp.selector;
        selectors[21] = gettersFacet.getCurrentProposalId.selector;
        selectors[22] = gettersFacet.isApprovedBySecurityCouncil.selector;
        selectors[23] = gettersFacet.getPriorityTxMaxGasLimit.selector;
        selectors[24] = gettersFacet.getAllowList.selector;
        selectors[25] = gettersFacet.isEthWithdrawalFinalized.selector;
        selectors[26] = gettersFacet.facets.selector;
        selectors[27] = gettersFacet.facetFunctionSelectors.selector;
        selectors[28] = gettersFacet.facetAddresses.selector;
        selectors[29] = gettersFacet.facetAddress.selector;
        selectors[30] = gettersFacet.isFunctionFreezable.selector;
        selectors[31] = gettersFacet.isFacetFreezable.selector;
        selectors[32] = gettersFacet.getTotalBatchesCommitted.selector;
        selectors[33] = gettersFacet.getTotalBatchesVerified.selector;
        selectors[34] = gettersFacet.getTotalBatchesExecuted.selector;
        return selectors;
    }
}
