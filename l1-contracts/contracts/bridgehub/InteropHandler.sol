// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

// import {IAccount, ACCOUNT_VALIDATION_SUCCESS_MAGIC} from "./interfaces/IAccount.sol";
// import {Utils} from "./libraries/Utils.sol";
import {Transaction} from "../common/l2-helpers/L2ContractHelper.sol";
import {IAccountCodeStorage} from "../common/l2-helpers/IAccountCodeStorage.sol";
// import {SystemContractsCaller} from "./libraries/SystemContractsCaller.sol";
// import {IAccount} from "./interfaces/IAccount.sol";
import {InteropAccount} from "./InteropAccount.sol";
// import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
// import {DefaultAccount} from "./DefaultAccount.sol";
// import {EfficientCall} from "./libraries/EfficientCall.sol";
import {BASE_TOKEN_SYSTEM_CONTRACT, L2_ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT, L2_INTEROP_ACCOUNT_ADDR, L2_MESSAGE_VERIFICATION, ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT} from "../common/l2-helpers/L2ContractAddresses.sol";
import {L2ContractHelper} from "../common/l2-helpers/L2ContractHelper.sol";
import {IInteropHandler} from "./IInteropHandler.sol";
import {InteropCall, InteropBundle, MessageInclusionProof, L2Message, L2Log} from "../common/Messaging.sol";
import {L2_MESSAGE_ROOT_STORAGE_ADDRESS} from "../common/l2-helpers/L2ContractAddresses.sol";
import {MessageHashing, ProofVerificationResult} from "../common/libraries/MessageHashing.sol";

enum BytecodeError {
    Version,
    NumberOfWords,
    Length,
    WordsMustBeOdd
}

event PaymasterBundleExecuted(address indexed where);
event DataBytesExecuted(bytes data);
event Bytes32(bytes32 indexed data);
event Number(uint256 indexed number);
event Address(address indexed _address);

error MessageNotIncluded();
event L2MessageVerification(uint256 chainId, uint256 index, bytes32 batchRoot);

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract that handles the interop bundles.
 */
contract InteropHandler is IInteropHandler {
    bytes32 public bytecodeHash;
    event TxIsIncluded(bool isIncluded);

    /// @notice The balances of the users.
    mapping(bytes32 txHash => bool alreadyExecuted) internal alreadyExecuted;

    function markAsExecuted(bytes32 txHash) external {
        // if (msg.sender != BOOTLOADER_FORMAL_ADDRESS) {
        //     revert Unauthorized(msg.sender);
        // }
        // // solhint-disable-next-line gas-custom-errors
        // require(!alreadyExecuted[txHash], "L2N: Already executed");
        // alreadyExecuted[txHash] = true;
    }

    function setInteropAccountBytecode() public {
        bytecodeHash = ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.getRawCodeHash(L2_INTEROP_ACCOUNT_ADDR);
    }

    function executeBundle(bytes memory _bundle, MessageInclusionProof memory _proof, bool _skipEmptyCalldata) public {
        _proof.message.data = _bundle;
        bool isIncluded = L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared(
            _proof.chainId,
            _proof.l1BatchNumber,
            _proof.l2MessageIndex,
            _proof.message,
            _proof.proof
        );
        if (!isIncluded) {
            // revert MessageNotIncluded();
        }
        emit TxIsIncluded(isIncluded);
        // kl todo store nullifier here

        InteropBundle memory interopBundle = abi.decode(_bundle, (InteropBundle));
        InteropCall memory baseTokenCall = interopBundle.calls[0];

        BASE_TOKEN_SYSTEM_CONTRACT.mint(address(this), baseTokenCall.value + 100000000000000000000);
        BASE_TOKEN_SYSTEM_CONTRACT.mint(msg.sender, baseTokenCall.value + 100000000000000000000); // todo

        for (uint256 i = 1; i < interopBundle.calls.length; i++) {
            InteropCall memory interopCall = interopBundle.calls[i];
            if (_skipEmptyCalldata && interopCall.data.length == 0) {
                // kl todo: we skip calls in the account validation phase for now, as empty contracts cannot be called.
                BASE_TOKEN_SYSTEM_CONTRACT.mint(interopCall.to, interopCall.value);
                continue;
            }
            BASE_TOKEN_SYSTEM_CONTRACT.mint(address(this), interopCall.value);

            address accountAddress = getAliasedAccount(interopCall.from, _proof.chainId);
            InteropAccount account = InteropAccount(payable(accountAddress)); // kl todo add chainId
            uint256 codeSize;
            assembly {
                codeSize := extcodesize(accountAddress)
            }
            if (codeSize == 0) {
                InteropAccount deployedAccount = new InteropAccount{
                    salt: keccak256(abi.encode(interopCall.from, _proof.chainId))
                }();
                require(address(account) == address(deployedAccount), "calculated address incorrect");
            }

            account.forwardFromIC{value: interopCall.value}(interopCall.to, interopCall.data);
        }
    }

    function getAliasedAccount(address _sender, uint256 _chainId) public view returns (address) {
        bytes32 constructorInputHash = keccak256(abi.encode()); // todo add constructor params.
        return
            L2ContractHelper.computeCreate2Address(
                address(this),
                keccak256(abi.encode(_sender, _chainId)),
                bytecodeHash,
                constructorInputHash
            );
    }
}
