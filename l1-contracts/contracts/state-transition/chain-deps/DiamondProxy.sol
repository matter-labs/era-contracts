// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Diamond} from "../libraries/Diamond.sol";

/// @title Diamond Proxy Contract (EIP-2535)
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract DiamondProxy {
    constructor(uint256 _chainId, Diamond.DiamondCutData memory _diamondCut) {
        // Check that the contract is deployed on the expected chain.
        // Thus, the contract deployed by the same Create2 factory on the different chain will have different addresses!
        require(_chainId == block.chainid, "pr");
        Diamond.diamondCut(_diamondCut);
    }

    /// @dev 1. Find the facet for the function that is called.
    /// @dev 2. Delegate the execution to the found facet via `delegatecall`.
    fallback() external payable {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();
        // Check whether the data contains a "full" selector or it is empty.
        // Required because Diamond proxy finds a facet by function signature,
        // which is not defined for data length in range [1, 3].
        require(msg.data.length >= 4 || msg.data.length == 0, "Ut");
        // Get facet from function selector
        Diamond.SelectorToFacet memory facet = diamondStorage.selectorToFacet[msg.sig];
        address facetAddress = facet.facetAddress;

        require(facetAddress != address(0), "F"); // Proxy has no facet for this selector
        require(!diamondStorage.isFrozen || !facet.isFreezable, "q1"); // Facet is frozen

        assembly {
            // The pointer to the free memory slot
            let ptr := mload(0x40)
            // Copy function signature and arguments from calldata at zero position into memory at pointer position
            calldatacopy(ptr, 0, calldatasize())
            // Delegatecall method of the implementation contract returns 0 on error
            let result := delegatecall(gas(), facetAddress, ptr, calldatasize(), 0, 0)
            // Get the size of the last return data
            let size := returndatasize()
            // Copy the size length of bytes from return data at zero position to pointer position
            returndatacopy(ptr, 0, size)
            // Depending on the result value
            switch result
            case 0 {
                // End execution and revert state changes
                revert(ptr, size)
            }
            default {
                // Return data with length of size at pointers position
                return(ptr, size)
            }
        }
    }
}
