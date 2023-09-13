// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (proxy/Proxy.sol)

pragma solidity ^0.8.13;

import "./BridgeheadBase.sol";

// import "../BridgeheadChain.sol";

contract Router is ReentrancyGuard, BridgeheadBase {
    // NOTE all functions that are callable from the router need to have chainId as their first
    // parameter, even if it is not used.

    /**
     * @dev Delegates the current call to `chain`.
     *
     * This function does not return to its internal call site, it will return directly to the external caller.
     */
    function _call(address chainAddress) internal virtual {
        assembly {
            // Copy msg.data. We take full control of memory in this inline assembly
            // block because it will not return to Solidity code. We overwrite the
            // Solidity scratch pad at memory position 0.
            calldatacopy(0, 0, calldatasize())

            // Call the chain.
            // out and outsize are 0 because we don't know the size yet.
            // KL todo Important! remove callvalue, and thread the value as a parameter
            let result := call(gas(), chainAddress, callvalue(), 0, calldatasize(), 0, 0)

            // Copy the returned data.
            returndatacopy(0, 0, returndatasize())

            switch result
            // delegatecall returns 0 on error.
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    /**
     * @dev This is a virtual function that should be overridden so it returns the address to which the fallback function
     * and {_fallback} should delegate.
     */
    function _findChain() internal view virtual returns (address) {
        uint256 chainId;
        assembly {
            chainId := calldataload(4)
        }
        address contractAddress = bridgeheadStorage.chainContract[chainId];
        require(contractAddress != address(0), "Chain not found in bridgehead router");
        return contractAddress;
        // return address(0);
    }

    /**
     * @dev Delegates the current call to the address returned by `_findChain()`.
     *
     * This function does not return to its internal call site, it will return directly to the external caller.
     */
    function _fallback() internal virtual {
        _call(_findChain());
    }

    /**
     * @dev Fallback function that delegates calls to the address returned by `_findChain()`. Will run if no other
     * function in the contract matches the call data.
     */
    fallback() external payable virtual {
        _fallback();
    }

    receive() external payable virtual {
        revert();
    }
}
