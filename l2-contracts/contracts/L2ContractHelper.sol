// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Smart contract for sending arbitrary length messages to L1
 * @dev by default ZkSync can send fixed-length messages on L1.
 * A fixed length message has 4 parameters `senderAddress`, `isService`, `key`, `value`,
 * the first one is taken from the context, the other three are chosen by the sender.
 * @dev To send a variable-length message we use this trick:
 * - This system contract accepts an arbitrary length message and sends a fixed length message with
 * parameters `senderAddress == this`, `isService == true`, `key == msg.sender`, `value == keccak256(message)`.
 * - The contract on L1 accepts all sent messages and if the message came from this system contract
 * it requires that the preimage of `value` be provided.
 */
interface IL2Messenger {
    /// @notice Sends an arbitrary length message to L1.
    /// @param _message The variable length message to be sent to L1.
    /// @return Returns the keccak256 hashed value of the message.
    function sendToL1(bytes memory _message) external returns (bytes32);
}

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Interface for the contract that is used to deploy contracts on L2.
 */
interface IContractDeployer {
    /// @notice A struct that describes a forced deployment on an address.
    /// @param bytecodeHash The bytecode hash to put on an address.
    /// @param newAddress The address on which to deploy the bytecodehash to.
    /// @param callConstructor Whether to run the constructor on the force deployment.
    /// @param value The `msg.value` with which to initialize a contract.
    /// @param input The constructor calldata.
    struct ForceDeployment {
        bytes32 bytecodeHash;
        address newAddress;
        bool callConstructor;
        uint256 value;
        bytes input;
    }

    /// @notice This method is to be used only during an upgrade to set bytecodes on specific addresses.
    /// @param _deployParams A set of parameters describing force deployment.
    function forceDeployOnAddresses(ForceDeployment[] calldata _deployParams) external payable;

    /// @notice Creates a new contract at a determined address using the `CREATE2` salt on L2
    /// @param _salt a unique value to create the deterministic address of the new contract
    /// @param _bytecodeHash the bytecodehash of the new contract to be deployed
    /// @param _input the calldata to be sent to the constructor of the new contract
    function create2(bytes32 _salt, bytes32 _bytecodeHash, bytes calldata _input) external returns (address);
}

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Interface for the contract that is used to simulate ETH on L2.
 */
interface IBaseToken {
    /// @notice Allows the withdrawal of ETH to a given L1 receiver along with an additional message.
    /// @param _l1Receiver The address on L1 to receive the withdrawn ETH.
    /// @param _additionalData Additional message or data to be sent alongside the withdrawal.
    function withdrawWithMessage(address _l1Receiver, bytes memory _additionalData) external payable;
}

uint160 constant SYSTEM_CONTRACTS_OFFSET = 0x8000; // 2^15

address constant BOOTLOADER_ADDRESS = address(SYSTEM_CONTRACTS_OFFSET + 0x01);
address constant MSG_VALUE_SYSTEM_CONTRACT = address(SYSTEM_CONTRACTS_OFFSET + 0x09);
address constant DEPLOYER_SYSTEM_CONTRACT = address(SYSTEM_CONTRACTS_OFFSET + 0x06);

IL2Messenger constant L2_MESSENGER = IL2Messenger(address(SYSTEM_CONTRACTS_OFFSET + 0x08));

IBaseToken constant L2_BASE_TOKEN_ADDRESS = IBaseToken(address(SYSTEM_CONTRACTS_OFFSET + 0x0a));

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Helper library for working with L2 contracts on L1.
 */
library L2ContractHelper {
    /// @dev The prefix used to create CREATE2 addresses.
    bytes32 private constant CREATE2_PREFIX = keccak256("zksyncCreate2");

    /// @notice Sends L2 -> L1 arbitrary-long message through the system contract messenger.
    /// @param _message Data to be sent to L1.
    /// @return keccak256 hash of the sent message.
    function sendMessageToL1(bytes memory _message) internal returns (bytes32) {
        return L2_MESSENGER.sendToL1(_message);
    }

    /// @notice Computes the create2 address for a Layer 2 contract.
    /// @param _sender The address of the contract creator.
    /// @param _salt The salt value to use in the create2 address computation.
    /// @param _bytecodeHash The contract bytecode hash.
    /// @param _constructorInputHash The keccak256 hash of the constructor input data.
    /// @return The create2 address of the contract.
    /// NOTE: L2 create2 derivation is different from L1 derivation!
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
}

/// @notice Structure used to represent a zkSync transaction.
struct Transaction {
    // The type of the transaction.
    uint256 txType;
    // The caller.
    uint256 from;
    // The callee.
    uint256 to;
    // The gasLimit to pass with the transaction.
    // It has the same meaning as Ethereum's gasLimit.
    uint256 gasLimit;
    // The maximum amount of gas the user is willing to pay for a byte of pubdata.
    uint256 gasPerPubdataByteLimit;
    // The maximum fee per gas that the user is willing to pay.
    // It is akin to EIP1559's maxFeePerGas.
    uint256 maxFeePerGas;
    // The maximum priority fee per gas that the user is willing to pay.
    // It is akin to EIP1559's maxPriorityFeePerGas.
    uint256 maxPriorityFeePerGas;
    // The transaction's paymaster. If there is no paymaster, it is equal to 0.
    uint256 paymaster;
    // The nonce of the transaction.
    uint256 nonce;
    // The value to pass with the transaction.
    uint256 value;
    // In the future, we might want to add some
    // new fields to the struct. The `txData` struct
    // is to be passed to account and any changes to its structure
    // would mean a breaking change to these accounts. In order to prevent this,
    // we should keep some fields as "reserved".
    // It is also recommended that their length is fixed, since
    // it would allow easier proof integration (in case we will need
    // some special circuit for preprocessing transactions).
    uint256[4] reserved;
    // The transaction's calldata.
    bytes data;
    // The signature of the transaction.
    bytes signature;
    // The properly formatted hashes of bytecodes that must be published on L1
    // with the inclusion of this transaction. Note, that a bytecode has been published
    // before, the user won't pay fees for its republishing.
    bytes32[] factoryDeps;
    // The input to the paymaster.
    bytes paymasterInput;
    // Reserved dynamic type for the future use-case. Using it should be avoided,
    // But it is still here, just in case we want to enable some additional functionality.
    bytes reservedDynamic;
}
