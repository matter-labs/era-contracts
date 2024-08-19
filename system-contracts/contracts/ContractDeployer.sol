// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ImmutableData} from "./interfaces/IImmutableSimulator.sol";
import {IContractDeployer} from "./interfaces/IContractDeployer.sol";
import {CREATE2_EVM_PREFIX, CREATE2_PREFIX, CREATE_PREFIX, NONCE_HOLDER_SYSTEM_CONTRACT, ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT, FORCE_DEPLOYER, MAX_SYSTEM_CONTRACT_ADDRESS, KNOWN_CODE_STORAGE_CONTRACT, BASE_TOKEN_SYSTEM_CONTRACT, IMMUTABLE_SIMULATOR_SYSTEM_CONTRACT, COMPLEX_UPGRADER_CONTRACT, KECCAK256_SYSTEM_CONTRACT} from "./Constants.sol";

import {Utils} from "./libraries/Utils.sol";
import {EfficientCall} from "./libraries/EfficientCall.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {ISystemContract} from "./interfaces/ISystemContract.sol";
import {Unauthorized, InvalidNonceOrderingChange, ValuesNotEqual, EmptyBytes32, NotAllowedToDeployInKernelSpace, HashIsNonZero, NonEmptyAccount, UnknownCodeHash, NonEmptyMsgValue} from "./SystemContractErrors.sol";

import {RLPEncoder} from "./libraries/RLPEncoder.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice System smart contract that is responsible for deploying other smart contracts on zkSync.
 * @dev The contract is responsible for generating the address of the deployed smart contract,
 * incrementing the deployment nonce and making sure that the constructor is never called twice in a contract.
 * Note, contracts with bytecode that have already been published to L1 once
 * do not need to be published anymore.
 */
contract ContractDeployer is IContractDeployer, ISystemContract {
    /// @notice Information about an account contract.
    /// @dev For EOA and simple contracts (i.e. not accounts) this value is 0.
    mapping(address => AccountInfo) internal accountInfo;

    enum EvmContractState {
        None,
        ConstructorPending,
        ConstructorCalled,
        Deployed
    }

    mapping(address => bytes32) public evmCodeHash;

    uint256 public constructorReturnGas;

    function setDeployedCode(uint256 constructorGasLeft, bytes calldata paddedNewDeployedCode) external {
        require(ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.isAccountEVM(msg.sender));

        uint256 bytecodeLen = uint256(bytes32(paddedNewDeployedCode[:32]));
        bytes memory trueBytecode = paddedNewDeployedCode[32:32 + bytecodeLen];

        evmCodeHash[msg.sender] = keccak256(trueBytecode);
        constructorReturnGas = constructorGasLeft;

        // ToDO: use efficient call
        KNOWN_CODE_STORAGE_CONTRACT.publishEVMBytecode(paddedNewDeployedCode);

        bytes32 codeHash = Utils.hashEVMBytecode(paddedNewDeployedCode);
        ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.storeAccountConstructedCodeHash(msg.sender, codeHash);
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Returns information about a certain account.
    function getAccountInfo(address _address) external view returns (AccountInfo memory info) {
        return accountInfo[_address];
    }

    /// @notice Returns the account abstraction version if `_address` is a deployed contract.
    /// Returns the latest supported account abstraction version if `_address` is an EOA.
    function extendedAccountVersion(address _address) public view returns (AccountAbstractionVersion) {
        AccountInfo memory info = accountInfo[_address];
        if (info.supportedAAVersion != AccountAbstractionVersion.None) {
            return info.supportedAAVersion;
        }

        // It is an EOA, it is still an account.
        if (
            _address > address(MAX_SYSTEM_CONTRACT_ADDRESS) &&
            ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.getRawCodeHash(_address) == 0
        ) {
            return AccountAbstractionVersion.Version1;
        }

        return AccountAbstractionVersion.None;
    }

    /// @notice Stores the new account information
    function _storeAccountInfo(address _address, AccountInfo memory _newInfo) internal {
        accountInfo[_address] = _newInfo;
    }

    /// @notice Update the used version of the account.
    /// @param _version The new version of the AA protocol to use.
    /// @dev Note that it allows changes from account to non-account and vice versa.
    function updateAccountVersion(AccountAbstractionVersion _version) external onlySystemCall {
        accountInfo[msg.sender].supportedAAVersion = _version;

        emit AccountVersionUpdated(msg.sender, _version);
    }

    /// @notice Updates the nonce ordering of the account. Currently,
    /// it only allows changes from sequential to arbitrary ordering.
    /// @param _nonceOrdering The new nonce ordering to use.
    function updateNonceOrdering(AccountNonceOrdering _nonceOrdering) external onlySystemCall {
        AccountInfo memory currentInfo = accountInfo[msg.sender];

        if (
            _nonceOrdering != AccountNonceOrdering.Arbitrary ||
            currentInfo.nonceOrdering != AccountNonceOrdering.Sequential
        ) {
            revert InvalidNonceOrderingChange();
        }

        currentInfo.nonceOrdering = _nonceOrdering;
        _storeAccountInfo(msg.sender, currentInfo);

        emit AccountNonceOrderingUpdated(msg.sender, _nonceOrdering);
    }

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
    ) public view override returns (address newAddress) {
        // No collision is possible with the Ethereum's CREATE2, since
        // the prefix begins with 0x20....
        bytes32 constructorInputHash = EfficientCall.keccak(_input);

        bytes32 hash = keccak256(
            // solhint-disable-next-line func-named-parameters
            bytes.concat(CREATE2_PREFIX, bytes32(uint256(uint160(_sender))), _salt, _bytecodeHash, constructorInputHash)
        );

        newAddress = address(uint160(uint256(hash)));
    }

    /// @notice Calculates the address of a deployed contract via create
    /// @param _sender The account that deploys the contract.
    /// @param _senderNonce The deploy nonce of the sender's account.
    function getNewAddressCreate(
        address _sender,
        uint256 _senderNonce
    ) public pure override returns (address newAddress) {
        // No collision is possible with the Ethereum's CREATE, since
        // the prefix begins with 0x63....
        bytes32 hash = keccak256(
            bytes.concat(CREATE_PREFIX, bytes32(uint256(uint160(_sender))), bytes32(_senderNonce))
        );

        newAddress = address(uint160(uint256(hash)));
    }

    /// @notice Deploys a contract with similar address derivation rules to the EVM's `CREATE2` opcode.
    /// @param _salt The CREATE2 salt
    /// @param _bytecodeHash The correctly formatted hash of the bytecode.
    /// @param _input The constructor calldata
    function create2(
        bytes32 _salt,
        bytes32 _bytecodeHash,
        bytes calldata _input
    ) external payable override returns (address) {
        return create2Account(_salt, _bytecodeHash, _input, AccountAbstractionVersion.None);
    }

    /// @notice Deploys a contract with similar address derivation rules to the EVM's `CREATE` opcode.
    /// @param _bytecodeHash The correctly formatted hash of the bytecode.
    /// @param _input The constructor calldata
    /// @dev This method also accepts nonce as one of its parameters.
    /// It is not used anywhere and it needed simply for the consistency for the compiler
    /// Note: this method may be callable only in system mode,
    /// that is checked in the `createAccount` by `onlySystemCall` modifier.
    function create(
        bytes32 _salt,
        bytes32 _bytecodeHash,
        bytes calldata _input
    ) external payable override returns (address) {
        return createAccount(_salt, _bytecodeHash, _input, AccountAbstractionVersion.None);
    }

    function createEVM(bytes calldata _initCode) external payable override returns (address) {
        // If the account is an EOA, use the min nonce. If it's a contract, use deployment nonce
        // Subtract 1 for EOA since the nonce has already been incremented for this transaction
        uint256 senderNonce = msg.sender == tx.origin
            ? NONCE_HOLDER_SYSTEM_CONTRACT.getMinNonce(msg.sender) - 1
            : NONCE_HOLDER_SYSTEM_CONTRACT.incrementDeploymentNonce(msg.sender) + 1;
        address newAddress = Utils.getNewAddressCreateEVM(msg.sender, senderNonce);
        _evmDeployOnAddress(newAddress, _initCode);
        return newAddress;
    }

    /// @notice Deploys an EVM contract using address derivation of EVM's `CREATE2` opcode
    /// @param _salt The CREATE2 salt
    /// @param _initCode The init code for the contract
    /// Note: this method may be callable only in system mode,
    /// that is checked in the `createAccount` by `onlySystemCall` modifier.
    function create2EVM(bytes32 _salt, bytes calldata _initCode) external payable override returns (address) {
        // No collision is possible with the zksync's non-EVM CREATE2, since
        // the prefixes are different
        bytes32 bytecodeHash = EfficientCall.keccak(_initCode);
        address newAddress = Utils.getNewAddressCreate2EVM(msg.sender, _salt, bytecodeHash);

        _evmDeployOnAddress(newAddress, _initCode);

        return newAddress;
    }

    function createEVMInternal(address _newAddress, bytes calldata _initCode) external payable {
        require(ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.isAccountEVM(msg.sender));
        _evmDeployOnAddress(_newAddress, _initCode);
    }

    /// @notice Deploys a contract account with similar address derivation rules to the EVM's `CREATE2` opcode.
    /// @param _salt The CREATE2 salt
    /// @param _bytecodeHash The correctly formatted hash of the bytecode.
    /// @param _input The constructor calldata.
    /// @param _aaVersion The account abstraction version to use.
    /// Note: this method may be callable only in system mode,
    /// that is checked in the `createAccount` by `onlySystemCall` modifier.
    function create2Account(
        bytes32 _salt,
        bytes32 _bytecodeHash,
        bytes calldata _input,
        AccountAbstractionVersion _aaVersion
    ) public payable override onlySystemCall returns (address) {
        NONCE_HOLDER_SYSTEM_CONTRACT.incrementDeploymentNonce(msg.sender);
        address newAddress = getNewAddressCreate2(msg.sender, _bytecodeHash, _salt, _input);

        _nonSystemDeployOnAddress(_bytecodeHash, newAddress, _aaVersion, _input);

        return newAddress;
    }

    /// @notice Deploys a contract account with similar address derivation rules to the EVM's `CREATE` opcode.
    /// @param _bytecodeHash The correctly formatted hash of the bytecode.
    /// @param _input The constructor calldata.
    /// @param _aaVersion The account abstraction version to use.
    /// @dev This method also accepts salt as one of its parameters.
    /// It is not used anywhere and it needed simply for the consistency for the compiler
    function createAccount(
        bytes32, // salt
        bytes32 _bytecodeHash,
        bytes calldata _input,
        AccountAbstractionVersion _aaVersion
    ) public payable override onlySystemCall returns (address) {
        uint256 senderNonce = NONCE_HOLDER_SYSTEM_CONTRACT.incrementDeploymentNonce(msg.sender);
        address newAddress = getNewAddressCreate(msg.sender, senderNonce);

        _nonSystemDeployOnAddress(_bytecodeHash, newAddress, _aaVersion, _input);

        return newAddress;
    }

    /// @notice A struct that describes a forced deployment on an address
    struct ForceDeployment {
        // The bytecode hash to put on an address
        bytes32 bytecodeHash;
        // The address on which to deploy the bytecodehash to
        address newAddress;
        // Whether to run the constructor on the force deployment
        bool callConstructor;
        // The value with which to initialize a contract
        uint256 value;
        // The constructor calldata
        bytes input;
    }

    /// @notice The method that can be used to forcefully deploy a contract.
    /// @param _deployment Information about the forced deployment.
    /// @param _sender The `msg.sender` inside the constructor call.
    function forceDeployOnAddress(ForceDeployment calldata _deployment, address _sender) external payable onlySelf {
        _ensureBytecodeIsKnown(_deployment.bytecodeHash);

        // Since the `forceDeployOnAddress` function is called only during upgrades, the Governance is trusted to correctly select
        // the addresses to deploy the new bytecodes to and to assess whether overriding the AccountInfo for the "force-deployed"
        // contract is acceptable.
        AccountInfo memory newAccountInfo;
        newAccountInfo.supportedAAVersion = AccountAbstractionVersion.None;
        // Accounts have sequential nonces by default.
        newAccountInfo.nonceOrdering = AccountNonceOrdering.Sequential;
        _storeAccountInfo(_deployment.newAddress, newAccountInfo);

        _constructContract({
            _sender: _sender,
            _newAddress: _deployment.newAddress,
            _bytecodeHash: _deployment.bytecodeHash,
            _input: _deployment.input,
            _isSystem: false,
            _callConstructor: _deployment.callConstructor
        });
    }

    /// @notice This method is to be used only during an upgrade to set bytecodes on specific addresses.
    /// @dev We do not require `onlySystemCall` here, since the method is accessible only
    /// by `FORCE_DEPLOYER`.
    function forceDeployOnAddresses(ForceDeployment[] calldata _deployments) external payable {
        if (msg.sender != FORCE_DEPLOYER && msg.sender != address(COMPLEX_UPGRADER_CONTRACT)) {
            revert Unauthorized(msg.sender);
        }

        uint256 deploymentsLength = _deployments.length;
        // We need to ensure that the `value` provided by the call is enough to provide `value`
        // for all of the deployments
        uint256 sumOfValues = 0;
        for (uint256 i = 0; i < deploymentsLength; ++i) {
            sumOfValues += _deployments[i].value;
        }
        if (msg.value != sumOfValues) {
            revert ValuesNotEqual(sumOfValues, msg.value);
        }

        for (uint256 i = 0; i < deploymentsLength; ++i) {
            this.forceDeployOnAddress{value: _deployments[i].value}(_deployments[i], msg.sender);
        }
    }

    function _nonSystemDeployOnAddress(
        bytes32 _bytecodeHash,
        address _newAddress,
        AccountAbstractionVersion _aaVersion,
        bytes calldata _input
    ) internal {
        if (_bytecodeHash == bytes32(0x0)) {
            revert EmptyBytes32();
        }
        if (uint160(_newAddress) <= MAX_SYSTEM_CONTRACT_ADDRESS) {
            revert NotAllowedToDeployInKernelSpace();
        }

        // We do not allow deploying twice on the same address.
        bytes32 codeHash = ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.getCodeHash(uint256(uint160(_newAddress)));
        if (codeHash != 0x0) {
            revert HashIsNonZero(codeHash);
        }
        // Do not allow deploying contracts to default accounts that have already executed transactions.
        if (NONCE_HOLDER_SYSTEM_CONTRACT.getRawNonce(_newAddress) != 0x00) {
            revert NonEmptyAccount();
        }

        _performDeployOnAddress(_bytecodeHash, _newAddress, _aaVersion, _input, true);
    }

    function _evmDeployOnAddress(address _newAddress, bytes calldata _initCode) internal {
        // Unfortunately we can not provide revert reason as it would break EVM compatibility
        // TODO: maybe it is redundant
        require(ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.getCodeHash(uint256(uint160(_newAddress))) == 0x0);
        _performDeployOnAddressEVM(_newAddress, AccountAbstractionVersion.None, _initCode, false);
    }

    /// @notice Deploy a certain bytecode on the address.
    /// @param _bytecodeHash The correctly formatted hash of the bytecode.
    /// @param _newAddress The address of the contract to be deployed.
    /// @param _aaVersion The version of the account abstraction protocol to use.
    /// @param _input The constructor calldata.
    function _performDeployOnAddress(
        bytes32 _bytecodeHash,
        address _newAddress,
        AccountAbstractionVersion _aaVersion,
        bytes calldata _input,
        bool _callConstructor
    ) internal {
        _ensureBytecodeIsKnown(_bytecodeHash);

        AccountInfo memory newAccountInfo;
        newAccountInfo.supportedAAVersion = _aaVersion;
        // Accounts have sequential nonces by default.
        newAccountInfo.nonceOrdering = AccountNonceOrdering.Sequential;
        _storeAccountInfo(_newAddress, newAccountInfo);

        _constructContract({
            _sender: msg.sender,
            _newAddress: _newAddress,
            _bytecodeHash: _bytecodeHash,
            _input: _input,
            _isSystem: false,
            _callConstructor: _callConstructor
        });
    }

    function convertToConstructorEVMInput(bytes calldata _input) internal pure returns (bytes memory) {
        // With how the contracts work, the calldata to the constructor must be an ABI-encoded `bytes`.
        // This means that it should also contain offset as well as length
        uint256 _fullLength = _input.length;
        bytes memory extendedInput = new bytes(_input.length + 64);

        assembly {
            // "Offset" for the calldata
            mstore(add(extendedInput, 0x20), 0x20)
            // "Length"
            mstore(add(extendedInput, 0x40), _fullLength)

            calldatacopy(add(extendedInput, 0x60), _input.offset, _fullLength)
        }

        return extendedInput;
    }

    /// @notice Deploy a certain bytecode on the address.
    /// @param _newAddress The address of the contract to be deployed.
    /// @param _aaVersion The version of the account abstraction protocol to use.
    /// @param _input The constructor calldata.
    function _performDeployOnAddressEVM(
        address _newAddress,
        AccountAbstractionVersion _aaVersion,
        bytes calldata _input,
        bool _callConstructor
    ) internal {
        AccountInfo memory newAccountInfo;
        newAccountInfo.supportedAAVersion = _aaVersion;
        // Accounts have sequential nonces by default.
        newAccountInfo.nonceOrdering = AccountNonceOrdering.Sequential;
        _storeAccountInfo(_newAddress, newAccountInfo);

        // Note, that for contracts the "nonce" is set as deployment nonce.
        NONCE_HOLDER_SYSTEM_CONTRACT.incrementDeploymentNonce(_newAddress);

        // When constructing they just get the intrepeter bytecode hash in consutrcting mode
        _constructEVMContract(msg.sender, _newAddress, _input);
    }

    /// @notice Check that bytecode hash is marked as known on the `KnownCodeStorage` system contracts
    function _ensureBytecodeIsKnown(bytes32 _bytecodeHash) internal view {
        uint256 knownCodeMarker = KNOWN_CODE_STORAGE_CONTRACT.getMarker(_bytecodeHash);
        if (knownCodeMarker == 0) {
            revert UnknownCodeHash(_bytecodeHash);
        }
    }

    /// @notice Ensures that the _newAddress and assigns a new contract hash to it
    /// @param _newAddress The address of the deployed contract
    /// @param _bytecodeHash The correctly formatted hash of the bytecode.
    function _storeConstructingByteCodeHashOnAddress(address _newAddress, bytes32 _bytecodeHash) internal {
        // Set the "isConstructor" flag to the bytecode hash
        bytes32 constructingBytecodeHash = Utils.constructingBytecodeHash(_bytecodeHash);
        ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.storeAccountConstructingCodeHash(_newAddress, constructingBytecodeHash);
    }

    /// @notice Transfers the `msg.value` ETH to the deployed account & invokes its constructor.
    /// This function must revert in case the deployment fails.
    /// @param _sender The msg.sender to be used in the constructor
    /// @param _newAddress The address of the deployed contract
    /// @param _input The constructor calldata
    /// @param _isSystem Whether the call should be a system call (could be possibly required in the future).
    function _constructContract(
        address _sender,
        address _newAddress,
        bytes32 _bytecodeHash,
        bytes calldata _input,
        bool _isSystem,
        bool _callConstructor
    ) internal {
        uint256 value = msg.value;
        if (_callConstructor) {
            // 1. Transfer the balance to the new address on the constructor call.
            if (value > 0) {
                BASE_TOKEN_SYSTEM_CONTRACT.transferFromTo(address(this), _newAddress, value);
            }
            // 2. Set the constructed code hash on the account
            _storeConstructingByteCodeHashOnAddress(_newAddress, _bytecodeHash);

            // 3. Call the constructor on behalf of the account
            if (value > 0) {
                // Safe to cast value, because `msg.value` <= `uint128.max` due to `MessageValueSimulator` invariant
                SystemContractHelper.setValueForNextFarCall(uint128(value));
            }
            bytes memory returnData = EfficientCall.mimicCall({
                _gas: gasleft(),
                _address: _newAddress,
                _data: _input,
                _whoToMimic: _sender,
                _isConstructor: true,
                _isSystem: _isSystem
            });
            // 4. Mark bytecode hash as constructed
            ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.markAccountCodeHashAsConstructed(_newAddress);
            // 5. Set the contract immutables
            ImmutableData[] memory immutables = abi.decode(returnData, (ImmutableData[]));
            IMMUTABLE_SIMULATOR_SYSTEM_CONTRACT.setImmutables(_newAddress, immutables);
        } else {
            if (value != 0) {
                revert NonEmptyMsgValue();
            }
            // If we do not call the constructor, we need to set the constructed code hash.
            ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.storeAccountConstructedCodeHash(_newAddress, _bytecodeHash);
        }

        emit ContractDeployed(_sender, _bytecodeHash, _newAddress);
    }

    function _constructEVMContract(address _sender, address _newAddress, bytes calldata _input) internal {
        // FIXME: this is a temporary limitation.
        // To be removed in the future
        require(_input.length > 0);

        constructorReturnGas = 0;

        uint256 value = msg.value;
        // 1. Transfer the balance to the new address on the constructor call.
        if (value > 0) {
            BASE_TOKEN_SYSTEM_CONTRACT.transferFromTo(address(this), _newAddress, value);
        }

        // 2. Set the constructed code hash on the account
        _storeConstructingByteCodeHashOnAddress(
            _newAddress,
            // Dummy EVM bytecode hash just to call simulator.
            // The second byte is `0x01` to indicate that it is being constructed.
            bytes32(0x0201000000000000000000000000000000000000000000000000000000000000)
        );

        // 3. Call the constructor on behalf of the account
        if (value > 0) {
            // Safe to cast value, because `msg.value` <= `uint128.max` due to `MessageValueSimulator` invariant
            SystemContractHelper.setValueForNextFarCall(uint128(value));
        }

        // In case of EVM contracts returnData is the new deployed code
        bool success = SystemContractHelper.mimicCall(uint32(gasleft()), _newAddress, msg.sender, _input, true, false);

        if (!success) {
            assembly {
                // Just propagate the error back
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }

        require(evmCodeHash[_newAddress] != 0x0, "The code hash must be set after the constructor call");
        emit ContractDeployed(_sender, evmCodeHash[_newAddress], _newAddress);
    }
}
