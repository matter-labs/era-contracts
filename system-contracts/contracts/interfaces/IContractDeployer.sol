// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/// @notice A struct that describes a forced deployment on an address
struct ForceDeployment {
    // The bytecode hash to put on an address. Hash and length parts are ignored in case of EVM deployment with constructor.
    bytes32 bytecodeHash;
    // The address on which to deploy the bytecodehash to
    address newAddress;
    // Whether to run the constructor on the force deployment.
    bool callConstructor;
    // The value with which to initialize a contract
    uint256 value;
    // The constructor calldata
    bytes input;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Interface of the contract deployer contract -- a system contract responsible for deploying other contracts.
interface IContractDeployer {
    /// @notice Defines the version of the account abstraction protocol
    /// that a contract claims to follow.
    /// - `None` means that the account is just a contract and it should never be interacted
    /// with as a custom account
    /// - `Version1` means that the account follows the first version of the account abstraction protocol
    enum AccountAbstractionVersion {
        None,
        Version1
    }

    /// @notice Defines the nonce ordering used by the account
    /// - `KeyedSequential` means that it is expected that the nonces are monotonic and increment by 1
    /// at a time for each key (nonces are split 192:64 bits into nonceKey:nonceValue parts, as proposed by EIP-4337).
    /// - `Arbitrary` ordering is deprecated.
    /// @dev This ordering is more of a suggestion to the operator on how the AA expects its transactions
    /// to be processed and is not considered as a system invariant.
    enum AccountNonceOrdering {
        KeyedSequential,
        __DEPRECATED_Arbitrary
    }

    /// @notice Defines what types of bytecode are allowed to be deployed on this chain
    /// - `EraVm` means that only native contracts can be deployed
    /// - `EraVmAndEVM` means that native contracts and EVM contracts can be deployed
    enum AllowedBytecodeTypes {
        EraVm,
        EraVmAndEVM
    }

    /// @notice Information about an account contract.
    /// @dev For EOA and simple contracts (i.e. not accounts) this has default value,
    /// which corresponds to `AccountAbstractionVersion.None`.and `AccountNonceOrdering.KeyedSequential`.
    struct AccountInfo {
        AccountAbstractionVersion supportedAAVersion;
        AccountNonceOrdering nonceOrdering;
    }

    /// @notice Emitted when a contract is deployed.
    /// @param deployerAddress The address of the deployer.
    /// @param bytecodeHash The formatted hash of the bytecode that was deployed.
    /// @param contractAddress The address of the newly deployed contract.
    event ContractDeployed(
        address indexed deployerAddress,
        bytes32 indexed bytecodeHash,
        address indexed contractAddress
    );

    /// @notice Emitted when account's nonce ordering is updated.
    /// Since currently only `KeyedSequential` ordering is supported and updating is not possible,
    /// the event is not emitted and is reserved for future use when updating becomes possible.
    /// @param accountAddress The address of the account.
    /// @param nonceOrdering The new nonce ordering of the account.
    event AccountNonceOrderingUpdated(address indexed accountAddress, AccountNonceOrdering nonceOrdering);

    /// @notice Emitted when account's AA version is updated.
    /// @param accountAddress The address of the contract.
    /// @param aaVersion The new AA version of the contract.
    event AccountVersionUpdated(address indexed accountAddress, AccountAbstractionVersion aaVersion);

    /// @notice Emitted when the allowed bytecode types mode is updated (e.g. from `EraVm` to `EraVmAndEVM`).
    /// @param mode The new allowed bytecode types mode.
    event AllowedBytecodeTypesModeUpdated(AllowedBytecodeTypes mode);

    /// @notice Returns what types of bytecode are allowed to be deployed on this chain.
    /// @return mode The allowed bytecode types mode.
    function allowedBytecodeTypesToDeploy() external view returns (AllowedBytecodeTypes mode);

    /// @notice Calculates the address of a deployed contract via create2
    /// @param _sender The account that deploys the contract.
    /// @param _bytecodeHash The correctly formatted hash of the bytecode.
    /// @param _salt The create2 salt.
    /// @param _input The constructor data.
    /// @return newAddress The derived address of the account.
    function getNewAddressCreate2(
        address _sender,
        bytes32 _bytecodeHash,
        bytes32 _salt,
        bytes calldata _input
    ) external view returns (address newAddress);

    /// @notice Calculates the address of a deployed contract via create
    /// @param _sender The account that deploys the contract.
    /// @param _senderNonce The deploy nonce of the sender's account.
    /// @return newAddress The derived address of the contract.
    function getNewAddressCreate(address _sender, uint256 _senderNonce) external pure returns (address newAddress);

    /// @notice Deploys a contract with similar address derivation rules to the EVM's `CREATE2` opcode.
    /// @param _salt The CREATE2 salt
    /// @param _bytecodeHash The correctly formatted hash of the bytecode.
    /// @param _input The constructor calldata
    /// @return newAddress The derived address of the contract.
    function create2(
        bytes32 _salt,
        bytes32 _bytecodeHash,
        bytes calldata _input
    ) external payable returns (address newAddress);

    /// @notice Deploys a contract account with similar address derivation rules to the EVM's `CREATE2` opcode.
    /// @param _salt The CREATE2 salt
    /// @param _bytecodeHash The correctly formatted hash of the bytecode.
    /// @param _input The constructor calldata.
    /// @param _aaVersion The account abstraction version to use.
    /// @return newAddress The derived address of the contract.
    /// @dev this method may be callable only in system mode,
    /// that is checked in the `createAccount` by `onlySystemCall` modifier.
    function create2Account(
        bytes32 _salt,
        bytes32 _bytecodeHash,
        bytes calldata _input,
        AccountAbstractionVersion _aaVersion
    ) external payable returns (address newAddress);

    /// @notice Deploys a contract with similar address derivation rules to the EVM's `CREATE` opcode.
    /// @param _salt A 32-byte salt.
    /// @param _bytecodeHash The correctly formatted hash of the bytecode.
    /// @param _input The constructor calldata
    /// @return newAddress The derived address of the contract.
    /// @dev Although this method accepts salt as one of its parameters.
    /// It is not used anywhere and is needed simply for the consistency for the compiler
    /// Note: this method may be callable only in system mode,
    /// that is checked in the `createAccount` by `onlySystemCall` modifier.
    function create(
        bytes32 _salt,
        bytes32 _bytecodeHash,
        bytes calldata _input
    ) external payable returns (address newAddress);

    /// @notice Deploys a contract account with similar address derivation rules to the EVM's `CREATE` opcode.
    /// @param _bytecodeHash The correctly formatted hash of the bytecode.
    /// @param _input The constructor calldata.
    /// @param _aaVersion The account abstraction version to use.
    /// @return newAddress The derived address of the contract.
    /// @dev This method also accepts salt as one of its parameters.
    /// It is not used anywhere and it needed simply for the consistency for the compiler
    function createAccount(
        bytes32, // salt
        bytes32 _bytecodeHash,
        bytes calldata _input,
        AccountAbstractionVersion _aaVersion
    ) external payable returns (address newAddress);

    /// @notice Returns information about a certain account.
    /// @param _address The address of the account.
    /// @return info The information about the account (AA version and nonce ordering).
    function getAccountInfo(address _address) external view returns (AccountInfo memory info);

    /// @notice Returns the account abstraction version if `_address` is a deployed contract.
    /// Returns the latest supported account abstraction version if `_address` is an EOA.
    /// @param _address The address of the account.
    /// @return The account abstraction version of the account. In particular, `Version1` for EOAs, `None` for non-account contracts. .
    function extendedAccountVersion(address _address) external view returns (AccountAbstractionVersion);

    /// @notice Update the used version of the account.
    /// @param _version The new version of the AA protocol to use.
    /// @dev Note that it allows changes from account to non-account and vice versa.
    function updateAccountVersion(AccountAbstractionVersion _version) external;

    /// @notice Updates the nonce ordering of the account. Since only `KeyedSequential` ordering
    /// is supported, currently this method always reverts.
    function updateNonceOrdering(AccountNonceOrdering) external;

    /// @notice This method is to be used only during an upgrade to set bytecodes on specific addresses.
    /// @dev We do not require `onlySystemCall` here, since the method is accessible only
    /// by `FORCE_DEPLOYER`.
    /// @param _deployments The list of forced deployments to be done.
    function forceDeployOnAddresses(ForceDeployment[] calldata _deployments) external payable;

    /// @notice Deploys an EVM contract using address derivation of EVM's `CREATE` opcode.
    /// @dev Note: this method may be callable only in system mode.
    /// @param _initCode The init code for the contract.
    /// @return evmGasUsed The amount of EVM gas used.
    /// @return newAddress The address of created contract.
    function createEVM(bytes calldata _initCode) external payable returns (uint256 evmGasUsed, address newAddress);

    /// @notice Deploys an EVM contract using address derivation of EVM's `CREATE2` opcode.
    /// @dev Note: this method may be callable only in system mode.
    /// @param _salt The CREATE2 salt.
    /// @param _initCode The init code for the contract.
    /// @return evmGasUsed The amount of EVM gas used.
    /// @return newAddress The address of created contract.
    function create2EVM(
        bytes32 _salt,
        bytes calldata _initCode
    ) external payable returns (uint256 evmGasUsed, address newAddress);

    /// @notice Changes what types of bytecodes are allowed to be deployed on the chain.
    /// @param newAllowedBytecodeTypes The new allowed bytecode types mode.
    function setAllowedBytecodeTypesToDeploy(AllowedBytecodeTypes newAllowedBytecodeTypes) external;
}
