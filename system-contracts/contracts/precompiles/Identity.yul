// SPDX-License-Identifier: MIT

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract used to support legacy MCOPY operations
 * @dev It simply returns the calldata.
 */
 object "Identity" {
    code {
        return(0, 0)
    }
    object "Identity_deployed" {
        code {            
            ////////////////////////////////////////////////////////////////
            //                      FALLBACK
            ////////////////////////////////////////////////////////////////

            let size := calldatasize()
            calldatacopy(0, 0, size)
            return(0, size)
        }
    }
}
