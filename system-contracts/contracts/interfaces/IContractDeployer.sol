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
    /// - `Arbitrary` means that the nonces for the accounts can be arbitrary. The operator
    /// should serve the transactions from such an account on a first-come-first-serve basis.
    /// @dev This ordering is more of a suggestion to the operator on how the AA expects its transactions
    /// to be processed and is not considered as a system invariant.
    enum AccountNonceOrdering {
        KeyedSequential,
        Arbitrary
    }

    /// @notice Defines what types of bytecode are allowed to be deployed on this chain
    /// - `EraVm` means that only native contracts can be deployed
    /// - `EraVmAndEVM` means that native contracts and EVM contracts can be deployed
    enum AllowedBytecodeTypes {
        EraVm,
        EraVmAndEVM
    }

    struct AccountInfo {
        AccountAbstractionVersion supportedAAVersion;
        AccountNonceOrdering nonceOrdering;
    }

    event ContractDeployed(
        address indexed deployerAddress,
        bytes32 indexed bytecodeHash,
        address indexed contractAddress
    );

    event AccountNonceOrderingUpdated(address indexed accountAddress, AccountNonceOrdering nonceOrdering);

    event AccountVersionUpdated(address indexed accountAddress, AccountAbstractionVersion aaVersion);

    event AllowedBytecodeTypesModeUpdated(AllowedBytecodeTypes mode);

    /// @notice Returns what types of bytecode are allowed to be deployed on this chain
    function allowedBytecodeTypesToDeploy() external view returns (AllowedBytecodeTypes mode);

    function getNewAddressCreate2(
        address _sender,
        bytes32 _bytecodeHash,
        bytes32 _salt,
        bytes calldata _input
    ) external view returns (address newAddress);

    function getNewAddressCreate(address _sender, uint256 _senderNonce) external pure returns (address newAddress);

    function create2(
        bytes32 _salt,
        bytes32 _bytecodeHash,
        bytes calldata _input
    ) external payable returns (address newAddress);

    function create2Account(
        bytes32 _salt,
        bytes32 _bytecodeHash,
        bytes calldata _input,
        AccountAbstractionVersion _aaVersion
    ) external payable returns (address newAddress);

    /// @dev While the `_salt` parameter is not used anywhere here,
    /// it is still needed for consistency between `create` and
    /// `create2` functions (required by the compiler).
    function create(
        bytes32 _salt,
        bytes32 _bytecodeHash,
        bytes calldata _input
    ) external payable returns (address newAddress);

    /// @dev While `_salt` is never used here, we leave it here as a parameter
    /// for the consistency with the `create` function.
    function createAccount(
        bytes32 _salt,
        bytes32 _bytecodeHash,
        bytes calldata _input,
        AccountAbstractionVersion _aaVersion
    ) external payable returns (address newAddress);

    /// @notice Returns the information about a certain AA.
    function getAccountInfo(address _address) external view returns (AccountInfo memory info);

    /// @notice Can be called by an account to update its account version
    function updateAccountVersion(AccountAbstractionVersion _version) external;

    /// @notice Can be called by an account to update its nonce ordering
    function updateNonceOrdering(AccountNonceOrdering _nonceOrdering) external;

    /// @notice This method is to be used only during an upgrade to set bytecodes on specific addresses.
    function forceDeployOnAddresses(ForceDeployment[] calldata _deployments) external payable;

    function createEVM(bytes calldata _initCode) external payable returns (uint256 evmGasUsed, address newAddress);

    function create2EVM(
        bytes32 _salt,
        bytes calldata _initCode
    ) external payable returns (uint256 evmGasUsed, address newAddress);

    /// @notice Changes what types of bytecodes are allowed to be deployed on the chain.
    /// @param newAllowedBytecodeTypes The new allowed bytecode types mode.
    function setAllowedBytecodeTypesToDeploy(AllowedBytecodeTypes newAllowedBytecodeTypes) external;
}
