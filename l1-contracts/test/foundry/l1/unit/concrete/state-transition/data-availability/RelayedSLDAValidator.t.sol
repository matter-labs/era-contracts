// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Utils} from "../../Utils/Utils.sol";
import {RelayedSLDAValidator} from "contracts/state-transition/data-availability/RelayedSLDAValidator.sol";
import {L1DAValidatorOutput, PubdataSource} from "contracts/state-transition/chain-interfaces/IL1DAValidator.sol";
import {L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IL1Messenger} from "contracts/common/interfaces/IL1Messenger.sol";
import {L2_BRIDGEHUB_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {PubdataInputTooSmall, L1DAValidatorInvalidSender} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {InvalidPubdataSource} from "contracts/state-transition/L1StateTransitionErrors.sol";

contract RelayedSLDAValidatorTest is Test {
    uint256 constant CHAIN_ID = 193;
    address constant CHAIN_ADDRESS = address(0x1234);
    RelayedSLDAValidator daValidator;

    function setUp() public {
        daValidator = new RelayedSLDAValidator();
        vm.etch(address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR), abi.encode(address(daValidator)));
        vm.mockCall(
            address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR),
            abi.encodeWithSelector(IL1Messenger.sendToL1.selector),
            abi.encode(bytes32(0))
        );
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehub.getZKChain.selector, (CHAIN_ID)),
            abi.encode(CHAIN_ADDRESS)
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                        RelayedSLDAValidator::checkDA
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_InvalidPubdataSource() public {
        bytes32 stateDiffHash = Utils.randomBytes32("stateDiffHash");
        bytes32 fullPubdataHash = Utils.randomBytes32("fullPubdataHash");
        uint8 blobsProvided = 1;
        uint256 maxBlobsSupported = 6;
        bytes32 blobLinearHash = Utils.randomBytes32("blobLinearHash");

        bytes memory daInput = abi.encodePacked(stateDiffHash, fullPubdataHash, blobsProvided, blobLinearHash);
        bytes memory l1DaInput = "verifydonttrust";

        bytes32 l2DAValidatorOutputHash = keccak256(daInput);

        bytes memory operatorDAInput = abi.encodePacked(daInput, l1DaInput);

        vm.prank(CHAIN_ADDRESS);
        // 118 is ascii encoding for `v`
        vm.expectRevert(abi.encodeWithSelector(InvalidPubdataSource.selector, 118));
        daValidator.checkDA(CHAIN_ID, 0, l2DAValidatorOutputHash, operatorDAInput, maxBlobsSupported);
    }

    function test_revertWhen_PubdataInputTooSmall() public {
        bytes memory pubdata = "verifydont";
        console.logBytes(pubdata);

        bytes32 stateDiffHash = Utils.randomBytes32("stateDiffHash");
        uint8 blobsProvided = 1;
        uint256 maxBlobsSupported = 6;
        bytes32 blobLinearHash = Utils.randomBytes32("blobLinearHash");
        uint8 pubdataSource = uint8(PubdataSource.Calldata);
        bytes memory l1DaInput = "verifydonttrust";
        bytes32 fullPubdataHash = keccak256(pubdata);

        bytes memory daInput = abi.encodePacked(stateDiffHash, fullPubdataHash, blobsProvided, blobLinearHash);

        bytes32 l2DAValidatorOutputHash = keccak256(daInput);

        bytes memory operatorDAInput = abi.encodePacked(daInput, pubdataSource, l1DaInput);

        vm.prank(CHAIN_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(PubdataInputTooSmall.selector, 15, 32));
        daValidator.checkDA(CHAIN_ID, 0, l2DAValidatorOutputHash, operatorDAInput, maxBlobsSupported);
    }

    function test_revertWhenInvalidSender() public {
        bytes memory pubdata = "verifydont";
        console.logBytes(pubdata);

        bytes32 stateDiffHash = Utils.randomBytes32("stateDiffHash");
        uint8 blobsProvided = 1;
        uint256 maxBlobsSupported = 6;
        bytes32 blobLinearHash = Utils.randomBytes32("blobLinearHash");
        uint8 pubdataSource = uint8(PubdataSource.Calldata);
        bytes memory l1DaInput = "verifydonttrust";
        bytes32 fullPubdataHash = keccak256(pubdata);

        bytes memory daInput = abi.encodePacked(stateDiffHash, fullPubdataHash, blobsProvided, blobLinearHash);

        bytes32 l2DAValidatorOutputHash = keccak256(daInput);

        bytes memory operatorDAInput = abi.encodePacked(daInput, pubdataSource, l1DaInput);

        vm.expectRevert(abi.encodeWithSelector(L1DAValidatorInvalidSender.selector, address(this)));
        daValidator.checkDA(CHAIN_ID, 0, l2DAValidatorOutputHash, operatorDAInput, maxBlobsSupported);
    }

    function test_checkDA() public {
        bytes memory pubdata = "verifydont";
        console.logBytes(pubdata);

        bytes32 stateDiffHash = Utils.randomBytes32("stateDiffHash");
        uint8 blobsProvided = 1;
        uint256 maxBlobsSupported = 6;
        bytes32 blobLinearHash = Utils.randomBytes32("blobLinearHash");
        uint8 pubdataSource = uint8(PubdataSource.Calldata);
        bytes memory l1DaInput = "verifydonttrustzkistheendgamemagicmoonmath";
        bytes32 fullPubdataHash = keccak256(pubdata);

        bytes memory daInput = abi.encodePacked(stateDiffHash, fullPubdataHash, blobsProvided, blobLinearHash);

        bytes32 l2DAValidatorOutputHash = keccak256(daInput);

        bytes memory operatorDAInput = abi.encodePacked(daInput, pubdataSource, l1DaInput);

        vm.prank(CHAIN_ADDRESS);
        L1DAValidatorOutput memory output = daValidator.checkDA(
            CHAIN_ID,
            0,
            l2DAValidatorOutputHash,
            operatorDAInput,
            maxBlobsSupported
        );
        assertEq(output.stateDiffHash, stateDiffHash, "stateDiffHash");
        assertEq(output.blobsLinearHashes.length, maxBlobsSupported, "blobsLinearHashesLength");
        assertEq(output.blobsOpeningCommitments.length, maxBlobsSupported, "blobsOpeningCommitmentsLength");
    }
}
