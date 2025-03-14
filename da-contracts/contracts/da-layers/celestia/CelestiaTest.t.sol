// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../../../lib/forge-std/src/Test.sol";
import "../../../lib/forge-std/src/console.sol";
import "./CelestiaL1DAValidator.sol";
import "../../IL1DAValidator.sol";

contract CelestiaL1DAValidatorTest is Test {
    CelestiaL1DAValidator public validator;

    // Test variables
    uint256 public constant MAX_BLOBS_SUPPORTED = 1;

    // Fork-related variables
    uint256 public mainnetFork;
    string public MAINNET_RPC_URL;
    bool public forksInitialized;

    function setUp() public {
        // Get the RPC URL from environment variable
        try vm.envString("MAINNET_RPC_URL") returns (string memory url) {
            MAINNET_RPC_URL = url;
            console.log("Using MAINNET_RPC_URL:", MAINNET_RPC_URL);

            // Create a fork of mainnet
            mainnetFork = vm.createFork(MAINNET_RPC_URL);
            vm.selectFork(mainnetFork);
            forksInitialized = true;

            console.log("Testing against mainnet fork at block:", block.number);
        } catch {
            console.log("MAINNET_RPC_URL not set. Mock testing only.");
            forksInitialized = false;
        }

        // Deploy the validator contract
        validator = new CelestiaL1DAValidator();
    }

    function _createValidInput() internal pure returns (bytes memory) {
        // Use the specific bytes provided by the user
        bytes
            memory operatorDAInput = hex"0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000002a000000000000000000000000000000000000000000000000000000000000003e000000000000000000000000000000000000000000000000000000000000022e100000000004dcb64000000000000000000000000000000000000000000000000cf87c1a24c46c8cd012904ead26c4fec36385bdbf81f4fdcad4c1d77ab2bfba600000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000060000000000000008c0000000000000000000000000000000000000000000000000000000000000258000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000aaef5c2ab4c32d6b6ac8b4806223da31e9ec4741c6e4446fb14fbcc9517a99c46157b06ccd330a5474eace72688f067a2def76d5075bf692aa78f585fbfdbfb6acc97e880c342911b0f3b9e2865b5cdc8597091676394bc3250925dd282b08a53ce89a8b3a3ba8eedbb9976a2a937b28a855f106dc61c3ebaacce15e3b7dac02163d5e4e1487214c7b94f9747736d23277f46c0cec5b0ad8bac7a37080d79774192b638b0b2bb1abfe243957c5a88c4601ef35655056869d2a1fd1909e5cb8042b13eafae292aecc3d6910d4c86bc6f2e3455e72405076f6770c52cb5bb34f034a61a2fc4ad5a050f3f9dff116631428564c375e4fc4d2879e669016360fcf6b32da606cc28b2bfbe8bc598bd61b3bce08e90defeaed1247e41ab0993c7d816c9a46ceff907d66f359a2ff0155600c805e6ff5537b8e26e90d6c14b1e4e6d8f28000000000000000000000000000000000000000000000000000000000000010411b6a09d1fd7b9a7c3675d651797507642566e8759c8236c315990d45ca8f4db075d88961d196ae900a38886c11c84e1d376d764a46466eb89a31dfaa221a20f43bbf9661dd902b56b9bdfacc8bf582af8bed44e2c57dacfb2cc2235dc0329d50b86b19a2433e5229e617ef4124b1f3e6b15d82427267c52d52dd6dd7309189519d9e7a216b2bda01883b03ac7fc29be93b9be88dfe03e0049e6eca11d5d1b4364fc2f8e26918df647af7ddb10bf6c0e8889d14b02b9000cce04e401aba2f7765e30c4c4073dcd8429c036857b07269f71f2d8649799c89da4a0beadd44d7d257788b96b14698bb960c12b9187719a1b88ae4388867deac5db0f9e080b68c8fb817374cd000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000040b21ffed339787f57da036f0ac93d948d4ab8566efd98e8350655a5edbe99feaecf87c1a24c46c8cd012904ead26c4fec36385bdbf81f4fdcad4c1d77ab2bfba6";

        return operatorDAInput;
    }

    function testAgainstRealContracts() public {
        // Skip test if fork is not available
        if (!forksInitialized) {
            console.log("Skipping real contract test - MAINNET_RPC_URL not set");
            return;
        }

        // Make sure we're using the fork
        vm.selectFork(mainnetFork);

        // Get the actual contract addresses
        address sp1VerifierAddress = validator.SP1_GROTH_16_VERIFIER();
        address blobstreamAddress = validator.BLOBSTREAM();

        console.log("SP1 Verifier address:", sp1VerifierAddress);
        console.log("Blobstream address:", blobstreamAddress);

        // Check that the contract exists (has code)
        uint256 sp1VerifierCodeSize = sp1VerifierAddress.code.length;
        uint256 blobstreamCodeSize = blobstreamAddress.code.length;

        console.log("SP1 Verifier code size:", sp1VerifierCodeSize);
        console.log("Blobstream code size:", blobstreamCodeSize);

        // Require that contracts have code
        require(sp1VerifierCodeSize > 0, "SP1 Verifier contract has no code");
        require(blobstreamCodeSize > 0, "Blobstream contract has no code");

        // Prepare input data
        bytes memory operatorDAInput = _createValidInput();

        // Log input data length
        console.log("Input data length:", operatorDAInput.length);

        // Test with real contracts - this will produce a stack trace when it reverts
        L1DAValidatorOutput memory output = validator.checkDA(0, 0, bytes32(0), operatorDAInput, MAX_BLOBS_SUPPORTED);

        // If we get here, the call succeeded (which would be unexpected)
        console.log("Call succeeded with real contracts!");
        console.log("State diff hash:", uint256(output.stateDiffHash));
    }

    // function testWithLowLevelCall() public {
    //     // Skip test if fork is not available
    //     if (!forksInitialized) {
    //         console.log("Skipping low-level call test - MAINNET_RPC_URL not set");
    //         return;
    //     }

    //     // Make sure we're using the fork
    //     vm.selectFork(mainnetFork);

    //     // Prepare input data
    //     bytes memory operatorDAInput = _createValidInput();

    //     // Create the calldata for checkDA
    //     bytes memory callData = abi.encodeWithSelector(
    //         validator.checkDA.selector,
    //         0,
    //         0,
    //         bytes32(0),
    //         operatorDAInput,
    //         MAX_BLOBS_SUPPORTED
    //     );

    //     // Log the call data for debugging
    //     console.log("Call data length:", callData.length);

    //     // Do a low-level staticcall (doesn't modify state)
    //     (bool success, bytes memory returnData) = address(validator).staticcall(callData);

    //     console.log("Call succeeded:", success);
    //     if (!success) {
    //         console.log("Return data length:", returnData.length);
    //         if (returnData.length > 0) {
    //             console.log("Return data (hex):");
    //             console.logBytes(returnData);

    //             // Try to extract error message if it's a standard revert with string
    //             if (returnData.length >= 4) {
    //                 // Skip the first 4 bytes (function selector) and try to decode as a string
    //                 bytes memory strippedData = new bytes(returnData.length - 4);
    //                 for (uint i = 4; i < returnData.length; i++) {
    //                     strippedData[i - 4] = returnData[i];
    //                 }

    //                 // Try to decode the error
    //                 bytes4 selector = bytes4(returnData[0]) |
    //                     (bytes4(returnData[1]) >> 8) |
    //                     (bytes4(returnData[2]) >> 16) |
    //                     (bytes4(returnData[3]) >> 24);
    //                 console.log("Error selector:", uint32(selector));

    //                 // We can't use try/catch with built-in functions, so we'll do our best to handle potential string errors
    //                 if (selector == bytes4(keccak256("Error(string)"))) {
    //                     // It's likely a standard error string
    //                     string memory reason = abi.decode(strippedData, (string));
    //                     console.log("Revert reason:", reason);
    //                 }
    //             }
    //         } else {
    //             console.log("No return data");
    //         }
    //     }

    //     // Test with assert so we get the trace
    //     assertTrue(false, "Forcing failure to see trace");
    // }
}
