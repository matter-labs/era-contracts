// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

abstract contract VerifierCaller {
    /**
     * @notice Calls the verifier function with given params
     * @param verifier address     - Address of the verifier contract
     * @param hash bytes32         - Signed data hash
     * @param rs bytes32[2]        - Signature array for the r and s values
     * @param pubKey bytes32[2]    - Public key coordinates array for the x and y values
     * @return - bool - Return the success of the verification
     */
    function callVerifier(
        address verifier,
        bytes32 hash,
        bytes32[2] memory rs,
        bytes32[2] memory pubKey
    ) internal view returns (bool) {
        /**
         * Prepare the input format
         * input[  0: 32] = signed data hash
         * input[ 32: 64] = signature r
         * input[ 64: 96] = signature s
         * input[ 96:128] = public key x
         * input[128:160] = public key y
         */
        bytes memory input = abi.encodePacked(
            hash,
            rs[0],
            rs[1],
            pubKey[0],
            pubKey[1]
        );

        // Make a call to verify the signature
        (bool success, bytes memory data) = verifier.staticcall(input);

        uint256 returnValue;
        // Return true if the call was successful and the return value is 1
        if (success && data.length > 0) {
            assembly {
                returnValue := mload(add(data, 0x20))
            }
            return returnValue == 1;
        }

        // Otherwise return false for the unsucessful calls and invalid signatures
        return false;
    }
}
