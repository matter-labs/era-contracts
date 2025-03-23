// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {TransactionHelper} from "../libraries/TransactionHelper.sol";
import {IInteropAccount} from "../interfaces/IInteropAccount.sol";
import {BASE_TOKEN_SYSTEM_CONTRACT, L2_INTEROP_ACCOUNT_ADDR, L2_MESSAGE_VERIFICATION, ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT, DEPLOYER_SYSTEM_CONTRACT} from "../Constants.sol";
import {InteropCall, InteropBundle, MessageInclusionProof, L2Message, BUNDLE_IDENTIFIER} from "../libraries/Messaging.sol";

error MessageNotIncluded();
error BundleAlreadyExecuted(bytes32 bundleHash);

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract that handles the interop bundles.
 */
contract DummyInteropHandler {
    bytes32 public bytecodeHash;

    /// @notice The balances of the users.
    mapping(bytes32 bundleHash => bool bundleExecuted) public bundleExecuted;

    function setInteropAccountBytecode() public {
        bytecodeHash = ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.getRawCodeHash(L2_INTEROP_ACCOUNT_ADDR);
    }

    function executeBundle(bytes memory _bundle, MessageInclusionProof memory _proof, bool _skipEmptyCalldata) public {
        _proof.message.data = bytes.concat(BUNDLE_IDENTIFIER, _bundle);
        bool isIncluded = L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared(
            _proof.chainId,
            _proof.l1BatchNumber,
            _proof.l2MessageIndex,
            _proof.message,
            _proof.proof
        );
        if (!isIncluded) {
            revert MessageNotIncluded();
        }
        bytes32 bundleHash = keccak256(
            abi.encode(_proof.chainId, _proof.l1BatchNumber, _proof.l2MessageIndex, _bundle)
        );
        if (bundleExecuted[bundleHash]) {
            revert BundleAlreadyExecuted(bundleHash);
        }
        bundleExecuted[bundleHash] = true;

        InteropBundle memory interopBundle = abi.decode(_bundle, (InteropBundle));
        InteropCall memory baseTokenCall = interopBundle.calls[0];

        for (uint256 i = 1; i < interopBundle.calls.length; i++) {
            InteropCall memory interopCall = interopBundle.calls[i];
            // if (_skipEmptyCalldata && interopCall.data.length == 0) {
            //     // kl todo: we skip calls in the account validation phase for now, as empty contracts cannot be called.
            //     BASE_TOKEN_SYSTEM_CONTRACT.mint(interopCall.to, interopCall.value);
            //     continue;
            // }

            address accountAddress = getAliasedAccount(interopCall.from, _proof.chainId);
            IInteropAccount account = IInteropAccount(payable(accountAddress)); // kl todo add chainId
            uint256 codeSize;
            assembly {
                codeSize := extcodesize(accountAddress)
            }
            if (codeSize == 0) {
                // kl todo use create3.
                address deployedAccount = deployInteropAccount(interopCall.from, _proof.chainId);
                require(address(account) == deployedAccount, "calculated address incorrect");
            }

            BASE_TOKEN_SYSTEM_CONTRACT.mint(address(account), interopCall.value);
            account.forwardFromIC(interopCall.to, interopCall.value, interopCall.data);
        }
    }

    function deployInteropAccount(address _sender, uint256 _chainId) public returns (address) {
        // kl todo: use figure out deployment mode.
        // return new InteropAccount{
        //     salt: keccak256(abi.encode(interopCall.from, _proof.chainId))
        // }();
        return DEPLOYER_SYSTEM_CONTRACT.create2(keccak256(abi.encode(_sender, _chainId)), bytecodeHash, abi.encode());
    }

    function getAliasedAccount(address _sender, uint256 _chainId) public view returns (address) {
        return
            DEPLOYER_SYSTEM_CONTRACT.getNewAddressCreate2(
                address(this),
                bytecodeHash,
                keccak256(abi.encode(_sender, _chainId)),
                abi.encode()
            );
    }
}
