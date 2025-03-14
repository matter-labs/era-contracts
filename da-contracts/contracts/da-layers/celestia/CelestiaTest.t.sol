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
            memory operatorDAInput = hex"0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000002a000000000000000000000000000000000000000000000000000000000000003e000000000000000000000000000000000000000000000000000000000000022e100000000000000000000000000000000000000000000000000000000004dcb6bf333ae5d5fe3dd3f468dbf4b326153c346189e80cdd7f51ed9cad43f8b5064270000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000930000000000000000000000000000000000000000000000000000000000000258000000000000000000000000000000000000000000000000000000000000000a4da157c3c1a71365c658bbd731703ffe9b20f79df6f5cb3c7d4b0f687b6ff71e22b90e49e97f4e748d93e29a0327479201b9ef070be6ebf5c8e17e260e18c3374a60acf42e6c613c3991ce3b1ced7dd3edb308401d128fd9d56eb0f49c2ecd52539727352e6b578d4ea8ba6050592ec4fd1c4cc926f2526d8d84ae10633389a22f64c9df1a69d3b758562bbe08b734da118518227dd0dfb14dd6d888b678bf3e92b638b0b2bb1abfe243957c5a88c4601ef35655056869d2a1fd1909e5cb8042b13eafae292aecc3d6910d4c86bc6f2e3455e72405076f6770c52cb5bb34f034a61a2fc4ad5a050f3f9dff116631428564c375e4fc4d2879e669016360fcf6b32da606cc28b2bfbe8bc598bd61b3bce08e90defeaed1247e41ab0993c7d816c9a46ceff907d66f359a2ff0155600c805e6ff5537b8e26e90d6c14b1e4e6d8f28000000000000000000000000000000000000000000000000000000000000010411b6a09d172a77acb398b42c4fc292e0823b227a0ae97bb728165e3b8a8f4cbe0edec395056971b59c8978ad0ed1f439d59c8b75b3d01a6ca914287f919dd68ea3e3e77707cf9227551d1b88702b5a0a34ecf825b3e4e60555503d6eb587b749134a0fb52cb72751936fb095f382f9ee1cead7a29fccfb54d483a2c3bbc77462a9da8bb820d22297f5ca91ffbfd89f4cda454a11b563caac6b830194c7f42d1a7d9639b71ad0d1482333a0c48232d053a93d6e8326c426e10ee9cad91715b61e99afaae8146f8dd76c4cb70383e45856541e1b585b4b9a4c0aa7af2913ea7a7b8d34129b086c4a632ad3fcb09fbc41df41009754f94e23ebc654c5f2de9fc559a91467340000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000409a0bc3cbc1740336f5c737edaa5f7158fcf1d7a0caca958d332ea0c339621e05f333ae5d5fe3dd3f468dbf4b326153c346189e80cdd7f51ed9cad43f8b506427";

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


        CelestiaZKStackInput memory decodedInput = abi.decode(operatorDAInput, (CelestiaZKStackInput));
        (bytes32 eqKeccakHash, bytes32 eqDataRoot) = abi.decode(decodedInput.publicValues, (bytes32, bytes32));

        console.log("eqKeccakHash", vm.toString(eqKeccakHash));
        console.log("eqDataRoot", vm.toString(eqDataRoot));

        // Log input data length
        console.log("Input data length:", operatorDAInput.length);

        // Test with real contracts - this will produce a stack trace when it reverts
        L1DAValidatorOutput memory output = validator.checkDA(0, 0, eqKeccakHash, operatorDAInput, MAX_BLOBS_SUPPORTED);

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
