// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ImmutableData} from "./interfaces/IImmutableSimulator.sol";
import {IContractDeployer, ForceDeployment} from "./interfaces/IContractDeployer.sol";
import {CREATE2_PREFIX, CREATE_PREFIX, NONCE_HOLDER_SYSTEM_CONTRACT, ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT, FORCE_DEPLOYER, MAX_SYSTEM_CONTRACT_ADDRESS, KNOWN_CODE_STORAGE_CONTRACT, BASE_TOKEN_SYSTEM_CONTRACT, IMMUTABLE_SIMULATOR_SYSTEM_CONTRACT, COMPLEX_UPGRADER_CONTRACT, SERVICE_CALL_PSEUDO_CALLER, EVM_PREDEPLOYS_MANAGER, EVM_HASHES_STORAGE} from "./Constants.sol";

import {Utils} from "./libraries/Utils.sol";
import {AuthorizationListItem} from "./libraries/TransactionHelper.sol";
import {RLPEncoder} from "./libraries/RLPEncoder.sol";
import {EfficientCall} from "./libraries/EfficientCall.sol";
import {SystemContractHelper} from "./libraries/SystemContractHelper.sol";
import {SystemContractBase} from "./abstract/SystemContractBase.sol";
import {Unauthorized, InvalidNonceOrderingChange, ValueMismatch, EmptyBytes32, EVMBytecodeHash, EVMBytecodeHashUnknown, EVMEmulationNotSupported, NotAllowedToDeployInKernelSpace, HashIsNonZero, NonEmptyAccount, UnknownCodeHash, NonEmptyMsgValue, EmptyAuthorizationList} from "./SystemContractErrors.sol";

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
    /// @dev For EOA and simple contracts (i.e. not accounts) this value is 0,
    /// which corresponds to `AccountAbstractionVersion.None`.and `AccountNonceOrdering.KeyedSequential`.
    mapping(address => AccountInfo) internal accountInfo;

    /// @notice What types of bytecode are allowed to be deployed on this chain.
    AllowedBytecodeTypes public allowedBytecodeTypesToDeploy;

    /// @dev Bytecode mask for delegated accounts:
    /// - Byte 0 (0x02) means the the account is processed through the EVM interpreter
    /// - Byte 1 (0x02) means that the account is delegated.
    /// - Bytes 2-3 (0x0017) means that the length of the bytecode is 23 bytes.
    /// - Bytes 4-8 have no meaning.
    /// - Bytes 9-11 (0xEF0100) are prefix for the 7702 bytecode of the contract (EF01000 || address).
    /// The rest is left empty for address masking.
    bytes32 private constant DELEGATION_BYTECODE_MASK =
        0x020200170000000000EF01000000000000000000000000000000000000000000;
    /// @dev Mask to extract the delegation address from the bytecode hash.
    bytes32 private constant DELEGATION_ADDRESS_MASK =
        0x000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    /// @dev Restricts `msg.sender` to be this contract itself.
    modifier onlySelf() {
        if (msg.sender != address(this)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Returns information about a certain account.
    /// @param _address The address of the account.
    /// @return The information about the account (AA version and nonce ordering).
    function getAccountInfo(address _address) external view returns (AccountInfo memory) {
        return accountInfo[_address];
    }

    /// @notice Returns `true` if account is an EOA (including 7702-delegated ones).
    /// This function will return `false` for _both_ smart contracts and smart accounts.
    /// @param _address The address of the account.
    /// @return `true` if the account is an EOA, `false` otherwise.
    function isAccountEOA(address _address) public view returns (bool) {
        bool systemContract = _address <= address(MAX_SYSTEM_CONTRACT_ADDRESS);
        if (systemContract) {
            return false;
        }

        bool noCodeHash = ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.getRawCodeHash(_address) == 0;
        if (noCodeHash) {
            return true;
        }

        bool delegated = getAccountDelegation(_address) != address(0);
        return delegated;
    }

    /// @notice Returns the account abstraction version if `_address` is a deployed contract.
    /// Returns the latest supported account abstraction version if `_address` is an EOA.
    /// @param _address The address of the account.
    /// @return The account abstraction version of the account. In particular, `Version1` for EOAs, `None` for non-account contracts. .
    function extendedAccountVersion(address _address) public view returns (AccountAbstractionVersion) {
        AccountInfo memory info = accountInfo[_address];
        if (info.supportedAAVersion != AccountAbstractionVersion.None) {
            return info.supportedAAVersion;
        }

        // It is an EOA, it is still an account.
        if (isAccountEOA(_address)) {
            return AccountAbstractionVersion.Version1;
        }

        return AccountAbstractionVersion.None;
    }

    /// @notice Stores the new account information
    /// @param _address The address of the account.
    /// @param _newInfo The new account information to store.
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
    /// @return newAddress The derived address of the contract.
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
    /// @return The derived address of the contract.
    function create2(
        bytes32 _salt,
        bytes32 _bytecodeHash,
        bytes calldata _input
    ) external payable override returns (address) {
        return create2Account(_salt, _bytecodeHash, _input, AccountAbstractionVersion.None);
    }

    /// @notice Deploys a contract with similar address derivation rules to the EVM's `CREATE` opcode.
    /// @param _salt A 32-byte salt.
    /// @param _bytecodeHash The correctly formatted hash of the bytecode.
    /// @param _input The constructor calldata
    /// @return The derived address of the contract.
    /// @dev Although this method accepts salt as one of its parameters.
    /// It is not used anywhere and is needed simply for the consistency for the compiler
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
    }

    /// @notice Method used by EVM emulator to deploy contracts.
    /// @param _newAddress The address of the contract to be deployed.
    /// @param _initCode The EVM code to be deployed (initCode).
    /// @return The amount of EVM gas used.
    /// @return The address of created contract.
    /// @dev Only possible revert case should be due to revert in the called constructor.
    /// @dev This method may be callable only by the EVM emulator.
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
    /// @return The derived address of the contract.
    /// @dev this method may be callable only in system mode,
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
    /// @return The derived address of the contract.
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
            // Accounts have keyed sequential nonces by default.
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
    /// @param _deployments The list of forced deployments to be done.
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

    /// @notice Returns the address of the account that is delegated to execute transactions on behalf of the given
    /// address.
    /// @notice Returns the zero address if no delegation is set.
    function getAccountDelegation(address _addr) public view override returns (address) {
        bytes32 codeHash = ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.getRawCodeHash(_addr);
        if (codeHash[0] == 0x02 && codeHash[1] == 0x02) {
            // The first two bytes of the code hash are 0x0202, which means that the account is delegated.
            // The delegation address is stored in the last 20 bytes of the code hash.
            return address(uint160(uint256(codeHash & DELEGATION_ADDRESS_MASK)));
        } else {
            // The account is not delegated.
            return address(0);
        }
    }

    /// @notice Method called by bootloader during processing of EIP7702 authorization lists.
    /// @notice Each item is processed independently, so if any check fails for an item,
    /// it is skipped and the next item is processed.
    function processDelegations(AuthorizationListItem[] calldata authorizationList) external onlyCallFromBootloader {
        uint256 listLength = authorizationList.length;
        // The transaction is considered invalid if the length of authorization_list is zero.
        if (listLength == 0) {
            revert EmptyAuthorizationList();
        }
        for (uint256 i = 0; i < listLength; ++i) {
            // Per EIP7702 rules, if any check for the tuple item fails,
            // we must move on to the next item in the list.
            AuthorizationListItem calldata item = authorizationList[i];

            // Verify the chain ID is 0 or the ID of the current chain.
            if (item.chainId != 0 && item.chainId != block.chainid) {
                continue;
            }

            // Verify the nonce is less than 2**64.
            if (item.nonce >= 2 ** 64) {
                continue;
            }

            // Calculate EIP7702 magic:
            // msg = keccak(MAGIC || rlp([chain_id, address, nonce]))
            bytes memory chainIdEncoded = RLPEncoder.encodeUint256(item.chainId);
            bytes memory addressEncoded = RLPEncoder.encodeAddress(item.addr);
            bytes memory nonceEncoded = RLPEncoder.encodeUint256(item.nonce);
            bytes memory listLenEncoded = RLPEncoder.encodeListLen(
                uint64(chainIdEncoded.length + addressEncoded.length + nonceEncoded.length)
            );
            bytes1 magic = bytes1(0x05);
            bytes32 message = keccak256(
                // solhint-disable-next-line func-named-parameters
                bytes.concat(magic, listLenEncoded, chainIdEncoded, addressEncoded, nonceEncoded)
            );

            // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
            // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
            // the valid range for s in (301): 0 < s < secp256k1n ÷ 2 + 1, and for v in (302): v ∈ {27, 28}. Most
            // signatures from current libraries generate a unique signature with an s-value in the lower half order.
            //
            // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
            // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
            // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
            // these malleable signatures as well.
            if (uint256(item.s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
                continue;
            }

            address authority = ecrecover(message, uint8(item.yParity + 27), bytes32(item.r), bytes32(item.s));

            // We only allow delegation for EOAs.
            if (!isAccountEOA(authority)) {
                continue;
            }

            // Avoid reverting if the nonce is not incremented.
            (bool nonceIncremented, ) = address(NONCE_HOLDER_SYSTEM_CONTRACT).call(
                abi.encodeWithSelector(
                    NONCE_HOLDER_SYSTEM_CONTRACT.incrementMinNonceIfEqualsFor.selector,
                    authority,
                    item.nonce
                )
            );
            if (!nonceIncremented) {
                continue;
            }
            if (item.addr == address(0)) {
                bytes32 currentBytecodeHash = ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.getRawCodeHash(authority);
                ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.storeAccount7702DelegationCodeHash(authority, 0x00);
                EVM_HASHES_STORAGE.storeEvmCodeHash(currentBytecodeHash, bytes32(0x0));
            } else {
                // Otherwise, store the delegation.
                bytes32 delegationCodeMarker = DELEGATION_BYTECODE_MASK | bytes32(uint256(uint160(item.addr)));
                ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT.storeAccount7702DelegationCodeHash(
                    authority,
                    delegationCodeMarker
                );
                bytes32 evmBytecodeHash = _hash7702Delegation(delegationCodeMarker);
                EVM_HASHES_STORAGE.storeEvmCodeHash(delegationCodeMarker, evmBytecodeHash);
            }
        }
    }

    /// @notice Hashes the code part extracted from EIP-7702 delegation contract bytecode hash
    /// without copying data to memory.
    /// @dev This method does not check whether the input is a valid EIP-7702 delegation code hash.
    /// @param input The EIP-7702 delegation code hash.
    /// @return hash The keccak256 hash of the code part of the EIP-7702 delegation code hash.
    function _hash7702Delegation(bytes32 input) internal pure returns (bytes32 hash) {
        // Hash bytes 9-32 (that have the contract code) without allocating an array.
        assembly {
            // Point to free memory and store 23 bytes starting at byte offset 9 of input
            let ptr := mload(0x40)
            mstore(ptr, shl(72, input)) // Shift left to remove first 9 bytes (9 * 8 = 72 bits)
            hash := keccak256(ptr, 23)
        }
    }

    /// @notice Deploys a bytecode on the specified address.
    /// @param _bytecodeHash The correctly formatted hash of the bytecode.
    /// @param _newAddress The address of the contract to be deployed.
    /// @param _aaVersion The version of the account abstraction protocol to use.
    /// @param _input The constructor calldata.
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

    /// @notice Deploy an EVM bytecode on the specified address.
    /// @param _sender The deployer address.
    /// @param _newAddress The address of the contract to be deployed.
    /// @param _initCode The constructor calldata.
    /// @return constructorReturnEvmGas The EVM gas left after constructor execution.
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
        constructorReturnEvmGas = _performDeployOnAddressEVM(
            _sender,
            _newAddress,
            AccountAbstractionVersion.None,
            _initCode
        );
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
        // Accounts have keyed sequential nonces by default.
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
        // Accounts have keyed sequential nonces by default.
        newAccountInfo.nonceOrdering = AccountNonceOrdering.KeyedSequential;
        _storeAccountInfo(_newAddress, newAccountInfo);

        // Note, that for contracts the "nonce" is set as deployment nonce.
        NONCE_HOLDER_SYSTEM_CONTRACT.incrementDeploymentNonce(_newAddress);

        // We will store dummy constructing bytecode hash to trigger EVM emulator in constructor call
        constructorReturnEvmGas = _constructEVMContract({
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
