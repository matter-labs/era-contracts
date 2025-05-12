// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IAccountCodeStorage} from "./interfaces/IAccountCodeStorage.sol";
import {SystemContractBase} from "./abstract/SystemContractBase.sol";
import {SystemContractsCaller} from "./libraries/SystemContractsCaller.sol";
import {EfficientCall} from "./libraries/EfficientCall.sol";
import {Transaction, AuthorizationListItem} from "./libraries/TransactionHelper.sol";
import {RLPEncoder} from "./libraries/RLPEncoder.sol";
import {Utils} from "./libraries/Utils.sol";
import {DEPLOYER_SYSTEM_CONTRACT, NONCE_HOLDER_SYSTEM_CONTRACT, CURRENT_MAX_PRECOMPILE_ADDRESS, EVM_HASHES_STORAGE, INonceHolder} from "./Constants.sol";
import {Unauthorized, InvalidCodeHash, CodeHashReason} from "./SystemContractErrors.sol";

event AccountDelegated(address indexed authority, address indexed delegationAddress);
event AccountDelegationRemoved(address indexed authority);

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The storage of this contract serves as a mapping for the code hashes of the 32-byte account addresses.
 * @dev Code hash is not strictly a hash, it's a structure where the first byte denotes the version of the hash,
 * the second byte denotes whether the contract is constructed, and the next two bytes denote the length in 32-byte words.
 * And then the next 28 bytes are the truncated hash.
 * @dev In this version of ZKsync, the first byte of the hash MUST be 1.
 * @dev The length of each bytecode MUST be odd.  It's internal code format requirements, due to padding of SHA256 function.
 * @dev It is also assumed that all the bytecode hashes are *known*, i.e. the full bytecodes
 * were published on L1 as calldata. This contract trusts the ContractDeployer and the KnownCodesStorage
 * system contracts to enforce the invariants mentioned above.
 */
contract AccountCodeStorage is IAccountCodeStorage, SystemContractBase {
    bytes32 private constant EMPTY_STRING_KECCAK = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    /// @notice Information about EIP-7702 delegated EOAs.
    /// @dev Delegated EOAs.
    mapping(address => address) private delegatedEOAs;

    modifier onlyDeployer() {
        if (msg.sender != address(DEPLOYER_SYSTEM_CONTRACT)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Stores the bytecodeHash of constructing contract.
    /// @param _address The address of the account to set the codehash to.
    /// @param _hash The new bytecode hash of the constructing account.
    /// @dev This method trusts the ContractDeployer to make sure that the bytecode is known and well-formed,
    /// but checks whether the bytecode hash corresponds to the constructing smart contract.
    function storeAccountConstructingCodeHash(address _address, bytes32 _hash) external override onlyDeployer {
        // Check that code hash corresponds to the deploying smart contract
        if (!Utils.isContractConstructing(_hash)) {
            revert InvalidCodeHash(CodeHashReason.NotContractOnConstructor);
        }
        _storeCodeHash(_address, _hash);
    }

    /// @notice Stores the bytecodeHash of constructed contract.
    /// @param _address The address of the account to set the codehash to.
    /// @param _hash The new bytecode hash of the constructed account.
    /// @dev This method trusts the ContractDeployer to make sure that the bytecode is known and well-formed,
    /// but checks whether the bytecode hash corresponds to the constructed smart contract.
    function storeAccountConstructedCodeHash(address _address, bytes32 _hash) external override onlyDeployer {
        // Check that code hash corresponds to the deploying smart contract
        if (!Utils.isContractConstructed(_hash)) {
            revert InvalidCodeHash(CodeHashReason.NotConstructedContract);
        }
        _storeCodeHash(_address, _hash);
    }

    /// @notice Marks the account bytecodeHash as constructed.
    /// @param _address The address of the account to mark as constructed
    function markAccountCodeHashAsConstructed(address _address) external override onlyDeployer {
        bytes32 codeHash = getRawCodeHash(_address);

        if (!Utils.isContractConstructing(codeHash)) {
            revert InvalidCodeHash(CodeHashReason.NotContractOnConstructor);
        }

        // Get the bytecode hash with "isConstructor" flag equal to false
        bytes32 constructedBytecodeHash = Utils.constructedBytecodeHash(codeHash);

        _storeCodeHash(_address, constructedBytecodeHash);
    }

    /// @dev Store the codehash of the account without any checks.
    /// @param _address The address of the account to set the codehash to.
    /// @param _hash The new account bytecode hash.
    function _storeCodeHash(address _address, bytes32 _hash) internal {
        uint256 addressAsKey = uint256(uint160(_address));
        assembly {
            sstore(addressAsKey, _hash)
        }
    }

    /// @notice Get the codehash stored for an address.
    /// @param _address The address of the account of which the codehash to return
    /// @return codeHash The codehash stored for this account.
    function getRawCodeHash(address _address) public view override returns (bytes32 codeHash) {
        uint256 addressAsKey = uint256(uint160(_address));

        assembly {
            codeHash := sload(addressAsKey)
        }
    }

    /// @notice Simulate the behavior of the `extcodehash` EVM opcode.
    /// @param _input The 256-bit account address.
    /// @return codeHash - hash of the bytecode according to the EIP-1052 specification.
    function getCodeHash(uint256 _input) external view override returns (bytes32) {
        // We consider the account bytecode hash of the last 20 bytes of the input, because
        // according to the spec "If EXTCODEHASH of A is X, then EXTCODEHASH of A + 2**160 is X".
        address account = address(uint160(_input));
        if (uint160(account) <= CURRENT_MAX_PRECOMPILE_ADDRESS) {
            return EMPTY_STRING_KECCAK;
        }

        bytes32 codeHash = getRawCodeHash(account);

        // The code hash is equal to the `keccak256("")` if the account is an EOA with at least one transaction.
        // Otherwise, the account is either deployed smart contract or an empty account,
        // for both cases the code hash is equal to the raw code hash.
        if (codeHash == 0x00 && NONCE_HOLDER_SYSTEM_CONTRACT.getRawNonce(account) > 0) {
            codeHash = EMPTY_STRING_KECCAK;
        }
        // The contract is still on the constructor, which means it is not deployed yet,
        // so set `keccak256("")` as a code hash. The EVM has the same behavior.
        else if (Utils.isContractConstructing(codeHash)) {
            codeHash = EMPTY_STRING_KECCAK;
        } else if (Utils.isCodeHashEVM(codeHash)) {
            codeHash = EVM_HASHES_STORAGE.getEvmCodeHash(codeHash);
        }

        return codeHash;
    }

    /// @notice Simulate the behavior of the `extcodesize` EVM opcode.
    /// @param _input The 256-bit account address.
    /// @return codeSize - the size of the deployed smart contract in bytes.
    function getCodeSize(uint256 _input) external view override returns (uint256 codeSize) {
        // We consider the account bytecode size of the last 20 bytes of the input, because
        // according to the spec "If EXTCODESIZE of A is X, then EXTCODESIZE of A + 2**160 is X".
        address account = address(uint160(_input));
        bytes32 codeHash = getRawCodeHash(account);

        // If the contract is a default account or is on constructor the code size is zero,
        // otherwise extract the proper value for it from the bytecode hash.
        // NOTE: zero address and precompiles are a special case, they are contracts, but we
        // want to preserve EVM invariants (see EIP-1052 specification). That's why we automatically
        // return `0` length in the following cases:
        // - `codehash(0) == 0`
        // - `account` is a precompile.
        // - `account` is currently being constructed
        if (
            uint160(account) > CURRENT_MAX_PRECOMPILE_ADDRESS &&
            codeHash != 0x00 &&
            !Utils.isContractConstructing(codeHash)
        ) {
            codeSize = Utils.bytecodeLenInBytes(codeHash);
        }
    }

    /// @notice Method for detecting whether an address is an EVM contract
    function isAccountEVM(address _addr) external view override returns (bool) {
        bytes32 bytecodeHash = getRawCodeHash(_addr);
        return Utils.isCodeHashEVM(bytecodeHash);
    }

    /// @notice Returns the address of the account that is delegated to execute transactions on behalf of the given
    /// address.
    /// @notice Returns the zero address if no delegation is set.
    function getAccountDelegation(address _addr) external view override returns (address) {
        return delegatedEOAs[_addr];
    }

    /// @notice Allows the bootloader to override bytecode hash of account.
    /// TODO: can we avoid it and do it in bootloader? Having it as a public interface feels very unsafe.
    function setRawCodeHash(address addr, bytes32 rawBytecodeHash) external onlyCallFromBootloader {
        _storeCodeHash(addr, rawBytecodeHash);
    }

    function processDelegations(AuthorizationListItem[] calldata authorizationList) external onlyCallFromBootloader {
        for (uint256 i = 0; i < authorizationList.length; i++) {
            // Per EIP7702 rules, if any check for the tuple item fails,
            // we must move on to the next item in the list.
            AuthorizationListItem calldata item = authorizationList[i];

            // Verify the chain ID is 0 or the ID of the current chain.
            if (item.chainId != 0 && item.chainId != block.chainid) {
                continue;
            }

            // Verify the nonce is less than 2**64 - 1.
            if (item.nonce >= 0xFFFFFFFFFFFFFFFF) {
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
            bytes32 message = keccak256(
                bytes.concat(bytes1(0x05), listLenEncoded, chainIdEncoded, addressEncoded, nonceEncoded)
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

            // ZKsync has native account abstraction, so we only allow delegation for EOAs.
            if (this.getRawCodeHash(authority) != 0x00 && this.getAccountDelegation(authority) == address(0)) {
                continue;
            }

            bool nonceIncremented = this._performRawMimicCall(
                uint32(gasleft()),
                authority,
                address(NONCE_HOLDER_SYSTEM_CONTRACT),
                abi.encodeCall(INonceHolder.incrementMinNonceIfEquals, (item.nonce)),
                true
            );
            if (!nonceIncremented) {
                continue;
            }
            if (item.addr == address(0)) {
                // If the delegation address is 0, we need to remove the delegation.
                delete delegatedEOAs[authority];
                _storeCodeHash(authority, 0x00);
                emit AccountDelegationRemoved(authority);
            } else {
                // Otherwise, store the delegation.
                // TODO: Do we need any security checks here, e.g. non-default code hash or non-system contract?
                delegatedEOAs[authority] = item.addr;

                bytes32 codeHash = getRawCodeHash(item.addr);
                _storeCodeHash(authority, codeHash); // TODO: Do we need additional checks here?
                emit AccountDelegated(authority, item.addr);
            }
        }
    }

    // Needed to convert `memory` to `calldata`
    // TODO: (partial) duplication with EntryPointV01; probably need to be moved somewhere.
    function _performRawMimicCall(
        uint32 _gas,
        address _whoToMimic,
        address _to,
        bytes calldata _data,
        bool isSystem
    ) external onlyCallFrom(address(this)) returns (bool success) {
        return EfficientCall.rawMimicCall(_gas, _to, _data, _whoToMimic, false, isSystem);
    }
}
