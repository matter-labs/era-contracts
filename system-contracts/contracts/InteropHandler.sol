// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// import {IAccount, ACCOUNT_VALIDATION_SUCCESS_MAGIC} from "./interfaces/IAccount.sol";
import {Utils} from "./libraries/Utils.sol";
import {TransactionHelper, Transaction} from "./libraries/TransactionHelper.sol";
import {IAccountCodeStorage} from "./interfaces/IAccountCodeStorage.sol";
// import {SystemContractsCaller} from "./libraries/SystemContractsCaller.sol";
import {IAccount} from "./interfaces/IAccount.sol";
import {InteropAccount} from "./InteropAccount.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {DefaultAccount} from "./DefaultAccount.sol";
import {EfficientCall} from "./libraries/EfficientCall.sol";
import {BASE_TOKEN_SYSTEM_CONTRACT, INTEROP_HANDLER_SYSTEM_CONTRACT, ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT} from "./Constants.sol";

import {IInteropHandler, InteropCall, InteropBundle} from "./interfaces/IInteropHandler.sol";


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

error MalformedBytecode(BytecodeError);
error LengthIsNotDivisibleBy32(uint256 length);

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract that handles the interop bundles.
 */
contract InteropHandler is IInteropHandler {
    address public constant L2_INTEROP_HANDLER = address(INTEROP_HANDLER_SYSTEM_CONTRACT);
    address public constant L2_BASE_TOKEN = address(BASE_TOKEN_SYSTEM_CONTRACT);

    uint256 public feeCounter;
    uint256 public interopCounter;
    bytes32 public bytecodeHash;
    uint256 public salt;

    function setInteropAccountBytecode() public {
        salt++;
        InteropAccount deployedAccount = new InteropAccount{salt: bytes32(uint256(uint160(salt)))}();
        IAccountCodeStorage codeStorage = IAccountCodeStorage(address(uint160(0x0000000000000000000000000000000000008002)));
        bytecodeHash = codeStorage.getRawCodeHash(address(uint160(0x0000000000000000000000000000000000011013)));
    }

    function executePaymasterBundle(Transaction calldata _transaction) external {
        feeCounter++;
        (bytes memory paymasterBundle, ) = abi.decode(_transaction.data, (bytes, bytes));
        // (, bytes memory paymasterProof) = abi.decode(_transaction.signature);
        // // todo verify signature = merkleProof.
        InteropBundle memory interopBundle = abi.decode(paymasterBundle, (InteropBundle));
        InteropCall memory baseTokenCall = interopBundle.calls[0];

        // require(interopCall.to == address(BASE_TOKEN_SYSTEM_CONTRACT), "InteropHandler: Invalid interop call");
        BASE_TOKEN_SYSTEM_CONTRACT.mint(address(this), baseTokenCall.value);
        BASE_TOKEN_SYSTEM_CONTRACT.mint(msg.sender, baseTokenCall.value);
        // require(msg.sender == baseTokenCall.from, "InteropHandler: Invalid sender"); // todo add aliasing here.
        // require(success, "InteropHandler: Interop call failed");

        // executeInteropBundle(paymasterBundle, paymasterProof)
        // emit PaymasterBundleExecuted(baseTokenCall.to);
        // BASE_TOKEN_SYSTEM_CONTRACT.mint(address(this), baseTokenCall.value);
        // BASE_TOKEN_SYSTEM_CONTRACT.mint(address(this), 10000000);

        // BASE_TOKEN_SYSTEM_CONTRACT.mint(msg.sender, baseTokenCall.value);
    }

    function executeInteropBundle(Transaction calldata _transaction) external {
        interopCounter++;
        // todo verify signature.
        (, bytes memory executionBundle) = abi.decode(_transaction.data, (bytes, bytes));
        // // (bytes memory executionBundle, ) = abi.decode(_transaction.data, (bytes, bytes));

        // bytes memory actualBytes = abi.decode(executionBundle, (bytes));
        InteropBundle memory interopBundle = abi.decode(executionBundle, (InteropBundle));
        InteropCall memory baseTokenCall = interopBundle.calls[0];

        emit Number(interopBundle.calls.length);
        BASE_TOKEN_SYSTEM_CONTRACT.mint(address(this), baseTokenCall.value);
        for (uint256 i = 1; i < interopBundle.calls.length; i++) {
            InteropCall memory interopCall = interopBundle.calls[i];
            emit Number(i);

            BASE_TOKEN_SYSTEM_CONTRACT.mint(address(this), interopCall.value);
            // BASE_TOKEN_SYSTEM_CONTRACT.mint(address(this), 100);
            // IAccount(applyL1ToL2Alias(interopCall.from)).hello();
            emit Address(interopCall.from);

            address accountAddress = aliasAccount(interopCall.from);
            emit Address(accountAddress);
            InteropAccount account = InteropAccount(accountAddress);
            uint256 codeSize;
            assembly {
                codeSize := extcodesize(accountAddress)
            } 
            // = accountAddress.codesize();
            emit Number(codeSize);
            if (codeSize == 0) {
                emit Number(257);
                InteropAccount deployedAccount = new InteropAccount{salt: bytes32(uint256(uint160(interopCall.from)))}();
                require(address(account)== address(deployedAccount), "calculated address incorrect");
            }

            // emit Address(address(account));
            // emit Address()
            // account.hello{value: 0}();
            account.forwardFromIC{value: interopCall.value}(
                interopCall.to,
                interopCall.data
            );
            // IAccount(applyL1ToL2Alias)
            // IAccount(applyL1ToL2Alias(interopCall.from)).hello(//interopCall.value}(
            //     // interopCall.to,
            //     // interopCall.data
            // );
            // IAccount(applyL1ToL2Alias(interopCall.from)).forwardFromIC{value: 0}(//interopCall.value}(
            //     interopCall.to,
            //     interopCall.data
            // );
        }
    }

    // uint160 private constant offset = uint160(0x1111000000000000000000000000000000001111);

    // /// @notice Utility function converts the address that submitted a tx
    // /// to the inbox on L1 to the msg.sender viewed on L2
    // /// @param l1Address the address in the L1 that triggered the tx to L2
    // /// @return l2Address L2 address as viewed in msg.sender
    // function applyL1ToL2Alias(address l1Address) internal pure returns (address l2Address) {
    //     unchecked {
    //         l2Address = address(uint160(l1Address) + offset);
    //     }
    // }

    /// @dev The prefix used to create CREATE2 addresses.
    bytes32 private constant CREATE2_PREFIX = keccak256("zksyncCreate2");

    function aliasAccount(address fromAsSalt) public view returns (address) {
        bytes32 constructorInputHash = keccak256(abi.encode()); // todo add constructor params.
        // bytes32 bytecodeHash = ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.getRawCodeHash(address(uint160(0x0000000000000000000000000000000000011013)));
        return 
            computeCreate2Address(
                address(this),
                bytes32(uint256(uint160(fromAsSalt))),
                bytecodeHash,
                constructorInputHash
            );
    }

    function computeCreate2Address(
        address _sender,
        bytes32 _salt,
        bytes32 _bytecodeHash,
        bytes32 _constructorInputHash
    ) internal pure returns (address) {
        bytes32 senderBytes = bytes32(uint256(uint160(_sender)));
        bytes32 data = keccak256(
            // solhint-disable-next-line func-named-parameters
            bytes.concat(CREATE2_PREFIX, senderBytes, _salt, _bytecodeHash, _constructorInputHash)
        );

        return address(uint160(uint256(data)));
    }

    function hashL2Bytecode(bytes memory _bytecode) internal pure returns (bytes32 hashedBytecode) {
        // Note that the length of the bytecode must be provided in 32-byte words.
        if (_bytecode.length % 32 != 0) {
            revert LengthIsNotDivisibleBy32(_bytecode.length);
        }

        uint256 bytecodeLenInWords = _bytecode.length / 32;
        // bytecode length must be less than 2^16 words
        if (bytecodeLenInWords >= 2 ** 16) {
            revert MalformedBytecode(BytecodeError.NumberOfWords);
        }
        // bytecode length in words must be odd
        if (bytecodeLenInWords % 2 == 0) {
            revert MalformedBytecode(BytecodeError.WordsMustBeOdd);
        }
        hashedBytecode = sha256(_bytecode) & 0x00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        // Setting the version of the hash
        hashedBytecode = (hashedBytecode | bytes32(uint256(1 << 248)));
        // Setting the length
        hashedBytecode = hashedBytecode | bytes32(bytecodeLenInWords << 224);
    }

    // bytes memory returnData = this.mimicCall(
    //     gasleft(),
    //     interopCall.to,
    //     interopCall.data,
    //     interopCall.from,
    //     false,
    //     false,
    //     interopCall.value
    // );

    // function mimicCall(
    //     uint256 _gas,
    //     address _address,
    //     bytes calldata _data,
    //     address _whoToMimic,
    //     bool _isConstructor,
    //     bool _isSystem,
    //     uint256 _value
    // ) external returns (bytes memory returnData) {
    //     // For the next call this `msg.value` will be used.
    //     SystemContractHelper.setValueForNextFarCall(Utils.safeCastToU128(_value));
    //     returnData = EfficientCall.mimicCall(gasleft(), _address, _data, _whoToMimic, _isConstructor, _isSystem);
    // }
}
