// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ImmutableData} from "./interfaces/IImmutableSimulator.sol";
import {IContractDeployer, ForceDeployment} from "./interfaces/IContractDeployer.sol";
import {CREATE2_PREFIX, CREATE_PREFIX, NONCE_HOLDER_SYSTEM_CONTRACT, ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT, FORCE_DEPLOYER, MAX_SYSTEM_CONTRACT_ADDRESS, KNOWN_CODE_STORAGE_CONTRACT, BASE_TOKEN_SYSTEM_CONTRACT, IMMUTABLE_SIMULATOR_SYSTEM_CONTRACT, COMPLEX_UPGRADER_CONTRACT, SERVICE_CALL_PSEUDO_CALLER, EVM_PREDEPLOYS_MANAGER, EVM_HASHES_STORAGE} from "./Constants.sol";

import {Utils} from "./libraries/Utils.sol";
import {EfficientCall} from "./libraries/EfficientCall.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {SystemContractBase} from "./abstract/SystemContractBase.sol";
import {Unauthorized, InvalidNonceOrderingChange, ValueMismatch, EmptyBytes32, EVMBytecodeHash, EVMBytecodeHashUnknown, EVMEmulationNotSupported, NotAllowedToDeployInKernelSpace, HashIsNonZero, NonEmptyAccount, UnknownCodeHash, NonEmptyMsgValue} from "./SystemContractErrors.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice System smart contract that is responsible for deploying other smart contracts on ZKsync.
 * @dev The contract is responsible for generating the address of the deployed smart contract,
 * incrementing the deployment nonce and making sure that the constructor is never called twice in a contract.
 * Note, contracts with bytecode that have already been published to L1 once
 * do not need to be published anymore.
 */
contract ContractDeployer is IContractDeployer, SystemContractBase {
    /// @notice Information about an account contract.
    /// @dev For EOA and simple contracts (i.e. not accounts) this value is 0.
    mapping(address => AccountInfo) internal accountInfo;

    /// @notice What types of bytecode are allowed to be deployed on this chain.
    AllowedBytecodeTypes public allowedBytecodeTypesToDeploy;

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

    /// @notice Updates the nonce ordering of the account. Since only `KeyedSequential`
    /// is supported, currently this method always reverts.
    function updateNonceOrdering(AccountNonceOrdering) external onlySystemCall {
        revert InvalidNonceOrderingChange();
        // NOTE: If this method is ever implemented, the `AccountNonceOrderingUpdated` event should be emitted.
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

    /// @notice Deploys an EVM contract using address derivation of EVM's `CREATE` opcode.
    /// @dev Note: this method may be callable only in system mode.
    /// @param _initCode The init code for the contract.
    /// @return The amount of EVM gas used.
    /// @return The address of created contract.
    function createEVM(bytes calldata _initCode) external payable override onlySystemCall returns (uint256, address) {
        uint256 senderNonce;
        // If the account is an EOA, use the min nonce. If it's a contract, use deployment nonce
        if (msg.sender == tx.origin) {
            // Subtract 1 for EOA since the nonce has already been incremented for this transaction
            senderNonce = NONCE_HOLDER_SYSTEM_CONTRACT.getMinNonce(msg.sender) - 1;
        } else {
            // Deploy from EraVM context
            senderNonce = NONCE_HOLDER_SYSTEM_CONTRACT.incrementDeploymentNonce(msg.sender);
        }

        address newAddress = Utils.getNewAddressCreateEVM(msg.sender, senderNonce);

        uint256 evmGasUsed = _evmDeployOnAddress(msg.sender, newAddress, _initCode);

        return (evmGasUsed, newAddress);
    }

    /// @notice Deploys an EVM contract using address derivation of EVM's `CREATE2` opcode.
    /// @dev Note: this method may be callable only in system mode.
    /// @param _salt The CREATE2 salt.
    /// @param _initCode The init code for the contract.
    /// @return The amount of EVM gas used.
    /// @return The address of created contract.
    function create2EVM(
        bytes32 _salt,
        bytes calldata _initCode
    ) external payable override onlySystemCall returns (uint256, address) {
        NONCE_HOLDER_SYSTEM_CONTRACT.incrementDeploymentNonce(msg.sender);
        // No collision is possible with the zksync's non-EVM CREATE2, since the prefixes are different
        bytes32 bytecodeHash = EfficientCall.keccak(_initCode);
        address newAddress = Utils.getNewAddressCreate2EVM(msg.sender, _salt, bytecodeHash);

        uint256 evmGasUsed = _evmDeployOnAddress(msg.sender, newAddress, _initCode);

        return (evmGasUsed, newAddress);
    }

    /// @notice Method used by EVM emulator to check if contract can be deployed and calculate the corresponding address.
    /// @dev Note: this method may be callable only by the EVM emulator.
    /// @param _salt The CREATE2 salt.
    /// @param _evmBytecodeHash The keccak of EVM code to be deployed (initCode).
    /// @return newAddress The address of the contract to be deployed.
    function precreateEvmAccountFromEmulator(
        bytes32 _salt,
        bytes32 _evmBytecodeHash
    ) public onlySystemCallFromEvmEmulator returns (address newAddress) {
        if (allowedBytecodeTypesToDeploy != AllowedBytecodeTypes.EraVmAndEVM) {
            revert EVMEmulationNotSupported();
        }

        uint256 senderNonce = NONCE_HOLDER_SYSTEM_CONTRACT.incrementDeploymentNonce(msg.sender);

        if (_evmBytecodeHash != bytes32(0)) {
            // Create2 case
            newAddress = Utils.getNewAddressCreate2EVM(msg.sender, _salt, _evmBytecodeHash);
        } else {
            // Create case
            newAddress = Utils.getNewAddressCreateEVM(msg.sender, senderNonce);
        }

        return newAddress;
    }

    /// @notice Method used by EVM emulator to deploy contracts.
    /// @param _newAddress The address of the contract to be deployed.
    /// @param _initCode The EVM code to be deployed (initCode).
    /// Note: only possible revert case should be due to revert in the called constructor.
    /// Note: this method may be callable only by the EVM emulator.
    function createEvmFromEmulator(
        address _newAddress,
        bytes calldata _initCode
    ) external payable onlySystemCallFromEvmEmulator returns (uint256, address) {
        uint256 constructorReturnEvmGas = _performDeployOnAddressEVM(
            msg.sender,
            _newAddress,
            AccountAbstractionVersion.None,
            _initCode
        );
        return (constructorReturnEvmGas, _newAddress);
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

    /// @notice The method that can be used to forcefully deploy a contract.
    /// @param _deployment Information about the forced deployment.
    /// @param _sender The `msg.sender` inside the constructor call.
    function forceDeployOnAddress(ForceDeployment calldata _deployment, address _sender) external payable onlySelf {
        // Since the `forceDeployOnAddress` function is called only during upgrades, the Governance is trusted to correctly select
        // the addresses to deploy the new bytecodes to and to assess whether overriding the AccountInfo for the "force-deployed"
        // contract is acceptable.

        if (Utils.isCodeHashEVM(_deployment.bytecodeHash)) {
            // Note, that for contracts the "nonce" is set as deployment nonce.
            uint256 deploymentNonce = NONCE_HOLDER_SYSTEM_CONTRACT.getDeploymentNonce(_deployment.newAddress);
            if (deploymentNonce == 0) {
                NONCE_HOLDER_SYSTEM_CONTRACT.incrementDeploymentNonce(_deployment.newAddress);
            }

            if (!_deployment.callConstructor) {
                _ensureBytecodeIsKnown(_deployment.bytecodeHash);
            }

            // It is not possible to change the AccountInfo for EVM contracts.
            // _versionedBytecodeHash will be ignored if _callConstructor is true
            _constructEVMContract({
                _sender: _sender,
                _newAddress: _deployment.newAddress,
                _versionedBytecodeHash: _deployment.bytecodeHash,
                _input: _deployment.input,
                _callConstructor: _deployment.callConstructor
            });
        } else {
            _ensureBytecodeIsKnown(_deployment.bytecodeHash);

            AccountInfo memory newAccountInfo;
            newAccountInfo.supportedAAVersion = AccountAbstractionVersion.None;
            // Accounts have sequential nonces by default.
            newAccountInfo.nonceOrdering = AccountNonceOrdering.KeyedSequential;
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
    }

    /// @notice This method is to be used only during an upgrade to set bytecodes on specific addresses.
    /// @dev We do not require `onlySystemCall` here, since the method is accessible only
    /// by `FORCE_DEPLOYER`.
    function forceDeployOnAddresses(ForceDeployment[] calldata _deployments) external payable override {
        if (
            msg.sender != FORCE_DEPLOYER &&
            msg.sender != address(COMPLEX_UPGRADER_CONTRACT) &&
            msg.sender != EVM_PREDEPLOYS_MANAGER
        ) {
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
            revert ValueMismatch(sumOfValues, msg.value);
        }

        for (uint256 i = 0; i < deploymentsLength; ++i) {
            this.forceDeployOnAddress{value: _deployments[i].value}(_deployments[i], msg.sender);
        }
    }

    /// @notice Changes what types of bytecodes are allowed to be deployed on the chain. Can be used only during upgrades.
    /// @param newAllowedBytecodeTypes The new allowed bytecode types mode.
    function setAllowedBytecodeTypesToDeploy(AllowedBytecodeTypes newAllowedBytecodeTypes) external {
        if (
            msg.sender != FORCE_DEPLOYER &&
            msg.sender != address(COMPLEX_UPGRADER_CONTRACT) &&
            msg.sender != SERVICE_CALL_PSEUDO_CALLER
        ) {
            revert Unauthorized(msg.sender);
        }

        if (allowedBytecodeTypesToDeploy != newAllowedBytecodeTypes) {
            allowedBytecodeTypesToDeploy = newAllowedBytecodeTypes;

            emit AllowedBytecodeTypesModeUpdated(newAllowedBytecodeTypes);
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
        if (Utils.isCodeHashEVM(_bytecodeHash)) {
            revert EVMBytecodeHash();
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

        // solhint-disable-next-line func-named-parameters
        _performDeployOnAddress(_bytecodeHash, _newAddress, _aaVersion, _input, true);
    }

    function _evmDeployOnAddress(
        address _sender,
        address _newAddress,
        bytes calldata _initCode
    ) internal returns (uint256 constructorReturnEvmGas) {
        if (allowedBytecodeTypesToDeploy != AllowedBytecodeTypes.EraVmAndEVM) {
            revert EVMEmulationNotSupported();
        }

        // Unfortunately we can not provide revert reason as it would break EVM compatibility
        // solhint-disable-next-line reason-string, gas-custom-errors
        require(NONCE_HOLDER_SYSTEM_CONTRACT.getRawNonce(_newAddress) == 0x0);
        // solhint-disable-next-line reason-string, gas-custom-errors
        require(ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.getRawCodeHash(_newAddress) == 0x0);
        return _performDeployOnAddressEVM(_sender, _newAddress, AccountAbstractionVersion.None, _initCode);
    }

    /// @notice Deploy a certain bytecode on the address.
    /// @param _bytecodeHash The correctly formatted hash of the bytecode.
    /// @param _newAddress The address of the contract to be deployed.
    /// @param _aaVersion The version of the account abstraction protocol to use.
    /// @param _input The constructor calldata.
    /// @param _callConstructor Whether to run the constructor or not.
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
        newAccountInfo.nonceOrdering = AccountNonceOrdering.KeyedSequential;
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

    /// @notice Deploy a certain EVM bytecode on the address.
    /// @param _sender The deployer address.
    /// @param _newAddress The address of the contract to be deployed.
    /// @param _aaVersion The version of the account abstraction protocol to use.
    /// @param _input The constructor calldata.
    /// @return constructorReturnEvmGas The EVM gas left after constructor execution.
    function _performDeployOnAddressEVM(
        address _sender,
        address _newAddress,
        AccountAbstractionVersion _aaVersion,
        bytes calldata _input
    ) internal returns (uint256 constructorReturnEvmGas) {
        AccountInfo memory newAccountInfo;
        newAccountInfo.supportedAAVersion = _aaVersion;
        // Accounts have sequential nonces by default.
        newAccountInfo.nonceOrdering = AccountNonceOrdering.KeyedSequential;
        _storeAccountInfo(_newAddress, newAccountInfo);

        // Note, that for contracts the "nonce" is set as deployment nonce.
        NONCE_HOLDER_SYSTEM_CONTRACT.incrementDeploymentNonce(_newAddress);

        // We will store dummy constructing bytecode hash to trigger EVM emulator in constructor call
        return
            _constructEVMContract({
                _sender: _sender,
                _newAddress: _newAddress,
                _versionedBytecodeHash: bytes32(0), // Ignored since we will call constructor
                _input: _input,
                _callConstructor: true
            });
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
    /// @param _bytecodeHash The correctly formatted versioned hash of the bytecode.
    /// @param _input The constructor calldata
    /// @param _isSystem Whether the call should be a system call (could be possibly required in the future).
    /// @param _callConstructor Whether to run the constructor or not.
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

    /// @notice Transfers the `msg.value` ETH to the deployed account & invokes its constructor.
    /// This function must revert in case the deployment fails.
    /// @param _sender The msg.sender to be used in the constructor.
    /// @param _newAddress The address of the deployed contract.
    /// @param _versionedBytecodeHash The correctly formatted versioned hash of the bytecode (ignored if `_callConstructor` is true).
    /// @param _input The constructor calldata.
    /// @param _callConstructor Whether to run the constructor or not.
    /// @return constructorReturnEvmGas The EVM gas left after constructor execution.
    function _constructEVMContract(
        address _sender,
        address _newAddress,
        bytes32 _versionedBytecodeHash,
        bytes calldata _input,
        bool _callConstructor
    ) internal returns (uint256 constructorReturnEvmGas) {
        uint256 value = msg.value;
        if (_callConstructor) {
            // 1. Transfer the balance to the new address on the constructor call.
            if (value > 0) {
                BASE_TOKEN_SYSTEM_CONTRACT.transferFromTo(address(this), _newAddress, value);
            }

            // 2. Set the constructing code hash on the account
            ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.storeAccountConstructingCodeHash(
                _newAddress,
                // Dummy EVM bytecode hash just to call emulator.
                // The second byte is `0x01` to indicate that it is being constructed.
                bytes32(0x0201000000000000000000000000000000000000000000000000000000000000)
            );

            // 3. Call the constructor on behalf of the account
            if (value > 0) {
                // Safe to cast value, because `msg.value` <= `uint128.max` due to `MessageValueSimulator` invariant
                SystemContractHelper.setValueForNextFarCall(uint128(value));
            }

            bytes memory paddedBytecode = EfficientCall.mimicCall({
                _gas: gasleft(), // note: native gas, not EVM gas
                _address: _newAddress,
                _data: _input,
                _whoToMimic: _sender,
                _isConstructor: true,
                _isSystem: false
            });

            uint256 evmBytecodeLen;
            // Returned data bytes have structure: paddedBytecode.evmBytecodeLen.constructorReturnEvmGas
            assembly {
                let dataLen := mload(paddedBytecode)
                evmBytecodeLen := mload(add(paddedBytecode, sub(dataLen, 0x20)))
                constructorReturnEvmGas := mload(add(paddedBytecode, dataLen))
                mstore(paddedBytecode, sub(dataLen, 0x40)) // shrink paddedBytecode
            }

            _versionedBytecodeHash = KNOWN_CODE_STORAGE_CONTRACT.publishEVMBytecode(evmBytecodeLen, paddedBytecode);
            ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.storeAccountConstructedCodeHash(_newAddress, _versionedBytecodeHash);

            // Calculate keccak256 of the EVM bytecode if it hasn't been done before
            if (EVM_HASHES_STORAGE.getEvmCodeHash(_versionedBytecodeHash) == bytes32(0)) {
                bytes32 evmBytecodeHash;
                assembly {
                    evmBytecodeHash := keccak256(add(paddedBytecode, 0x20), evmBytecodeLen)
                }

                EVM_HASHES_STORAGE.storeEvmCodeHash(_versionedBytecodeHash, evmBytecodeHash);
            }
        } else {
            if (value != 0) {
                revert NonEmptyMsgValue();
            }

            // Sanity check, EVM code hash should be present if versioned bytecode hash is known
            if (EVM_HASHES_STORAGE.getEvmCodeHash(_versionedBytecodeHash) == bytes32(0)) {
                revert EVMBytecodeHashUnknown();
            }

            // If we do not call the constructor, we need to set the constructed code hash.
            ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.storeAccountConstructedCodeHash(_newAddress, _versionedBytecodeHash);
        }

        emit ContractDeployed(_sender, _versionedBytecodeHash, _newAddress);
    }
}
