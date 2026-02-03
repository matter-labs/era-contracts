// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import "./interfaces/IL1Bridge.sol";
import "./interfaces/IL2Bridge.sol";
import "./interfaces/IL2ERC721Bridge.sol";

import "./libraries/BridgeInitializationHelper.sol";

import "../zksync/interfaces/IZkSync.sol";
import "../common/libraries/UnsafeBytes.sol";
import "../common/libraries/L2ContractHelper.sol";
import "../common/ReentrancyGuard.sol";
import "../vendor/AddressAliasHelper.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Smart contract that allows depositing ERC721 tokens from Ethereum to zkSync Era
/// @dev It is standard implementation of ERC721 Bridge that can be used as a reference
/// for any other custom token bridges.
contract L1ERC721Bridge is IL1Bridge, ReentrancyGuard {
    /// @dev zkSync smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication
    IZkSync internal immutable zkSync;

    /// @dev A mapping L2 batch number => message number => flag
    /// @dev Used to indicate that zkSync L2 -> L1 message was already processed
    mapping(uint256 => mapping(uint256 => bool)) public isWithdrawalFinalized;

    /// @dev A mapping account => L1 token address => L2 deposit transaction hash => token ID
    /// @dev Used for saving the deposited token ID, to claim them in case the deposit transaction will fail
    mapping(address => mapping(address => mapping(bytes32 => uint256))) internal depositTokenIds;

    /// @dev A mapping account => L1 token address => L2 deposit transaction hash => token ID => bool
    /// @dev Used for checking that token ID is deposited, to claim them in case the deposit transaction will fail
    mapping(address => mapping(address => mapping(bytes32 => mapping(uint256 => bool)))) internal depositTokenIdsPresent;

    /// @dev The address of deployed L2 bridge counterpart
    address public l2Bridge;

    /// @dev The address that acts as a beacon for L2 tokens
    address public l2TokenBeacon;

    /// @dev The bytecode hash of the L2 token contract
    bytes32 public l2TokenProxyBytecodeHash;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IZkSync _zkSync) reentrancyGuardInitializer {
        zkSync = _zkSync;
    }

    /// @dev Initializes a contract bridge for later use. Expected to be used in the proxy
    /// @dev During initialization deploys L2 bridge counterpart as well as provides some factory deps for it
    /// @param _factoryDeps A list of raw bytecodes that are needed for deployment of the L2 bridge
    /// @notice _factoryDeps[0] == a raw bytecode of L2 bridge implementation
    /// @notice _factoryDeps[1] == a raw bytecode of proxy that is used as L2 bridge
    /// @notice _factoryDeps[2] == a raw bytecode of token proxy
    /// @param _l2TokenBeacon Pre-calculated address of the L2 token upgradeable beacon
    /// @notice At the time of the function call, it is not yet deployed in L2, but knowledge of its address
    /// @notice is necessary for determining L2 token address by L1 address, see `l2TokenAddress(address)` function
    /// @param _governor Address which can change L2 token implementation and upgrade the bridge
    /// @param _deployBridgeImplementationFee How much of the sent value should be allocated to deploying the L2 bridge
    /// implementation
    /// @param _deployBridgeProxyFee How much of the sent value should be allocated to deploying the L2 bridge proxy
    function initialize(
        bytes[] calldata _factoryDeps,
        address _l2TokenBeacon,
        address _governor,
        uint256 _deployBridgeImplementationFee,
        uint256 _deployBridgeProxyFee
    ) external payable reentrancyGuardInitializer {
        require(_l2TokenBeacon != address(0), "nf");
        require(_governor != address(0), "nh");
        // We are expecting to see the exact three bytecodes that are needed to initialize the bridge
        require(_factoryDeps.length == 3, "mk");
        // The caller miscalculated deploy transactions fees
        require(msg.value == _deployBridgeImplementationFee + _deployBridgeProxyFee, "fee");
        l2TokenProxyBytecodeHash = L2ContractHelper.hashL2Bytecode(_factoryDeps[2]);
        l2TokenBeacon = _l2TokenBeacon;

        bytes32 l2BridgeImplementationBytecodeHash = L2ContractHelper.hashL2Bytecode(_factoryDeps[0]);
        bytes32 l2BridgeProxyBytecodeHash = L2ContractHelper.hashL2Bytecode(_factoryDeps[1]);

        // Deploy L2 bridge implementation contract
        address bridgeImplementationAddr = BridgeInitializationHelper.requestDeployTransaction(
            zkSync,
            _deployBridgeImplementationFee,
            l2BridgeImplementationBytecodeHash,
            "", // Empty constructor data
            _factoryDeps // All factory deps are needed for L2 bridge
        );

        // Prepare the proxy constructor data
        bytes memory l2BridgeProxyConstructorData;
        {
            // Data to be used in delegate call to initialize the proxy
            bytes memory proxyInitializationParams = abi.encodeCall(
                IL2ERC721Bridge.initialize,
                (address(this), l2TokenProxyBytecodeHash, _governor)
            );
            l2BridgeProxyConstructorData = abi.encode(bridgeImplementationAddr, _governor, proxyInitializationParams);
        }

        // Deploy L2 bridge proxy contract
        l2Bridge = BridgeInitializationHelper.requestDeployTransaction(
            zkSync,
            _deployBridgeProxyFee,
            l2BridgeProxyBytecodeHash,
            l2BridgeProxyConstructorData,
            // No factory deps are needed for L2 bridge proxy, because it is already passed in previous step
            new bytes[](0)
        );
    }

    /// @notice Initiates a deposit by locking token on the contract and sending the request
    /// of processing an L2 transaction where tokens would be minted
    /// @param _l2Receiver The account address that should receive the token on L2
    /// @param _l1Token The L1 token address which is deposited
    /// @param _tokenId The L1 token ID which is deposited
    /// @param _l2TxGasLimit The L2 gas limit to be used in the corresponding L2 transaction
    /// @param _l2TxGasPerPubdataByte The gasPerPubdataByteLimit to be used in the corresponding L2 transaction
    /// @param _refundRecipient The address on L2 that will receive the refund for the transaction.
    /// @dev If the L2 deposit finalization transaction fails, the `_refundRecipient` will receive the `_l2Value`.
    /// Please note, the contract may change the refund recipient's address to eliminate sending funds to addresses
    /// out of control.
    /// - If `_refundRecipient` is a contract on L1, the refund will be sent to the aliased `_refundRecipient`.
    /// - If `_refundRecipient` is set to `address(0)` and the sender has NO deployed bytecode on L1, the refund will
    /// be sent to the `msg.sender` address.
    /// - If `_refundRecipient` is set to `address(0)` and the sender has deployed bytecode on L1, the refund will be
    /// sent to the aliased `msg.sender` address.
    /// @dev The address aliasing of L1 contracts as refund recipient on L2 is necessary to guarantee that the funds
    /// are controllable through the Mailbox, since the Mailbox applies address aliasing to the from address for the
    /// L2 tx if the L1 msg.sender is a contract. Without address aliasing for L1 contracts as refund recipients they
    /// would not be able to make proper L2 tx requests through the Mailbox to use or withdraw the funds from L2, and
    /// the funds would be lost.
    /// @return l2TxHash The L2 transaction hash of deposit finalization
    function deposit(
        address _l2Receiver,
        address _l1Token,
        uint256 _tokenId,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) public payable nonReentrant returns (bytes32 l2TxHash) {
        _depositToken(msg.sender, IERC721(_l1Token), _tokenId);

        bytes memory l2TxCalldata = _getDepositL2Calldata(msg.sender, _l2Receiver, _l1Token, _tokenId);
        // If the refund recipient is not specified, the refund will be sent to the sender of the transaction.
        // Otherwise, the refund will be sent to the specified address.
        // If the recipient is a contract on L1, the address alias will be applied.
        address refundRecipient = _refundRecipient;
        if (_refundRecipient == address(0)) {
            refundRecipient = msg.sender != tx.origin ? AddressAliasHelper.applyL1ToL2Alias(msg.sender) : msg.sender;
        }
        l2TxHash = zkSync.requestL2Transaction{value: msg.value}(
            l2Bridge,
            0, // L2 msg.value
            l2TxCalldata,
            _l2TxGasLimit,
            _l2TxGasPerPubdataByte,
            new bytes[](0),
            refundRecipient
        );

        // Save the deposited token ID to claim on L1 if the deposit failed on L2
        depositTokenIds[msg.sender][_l1Token][l2TxHash] = _tokenId;
        depositTokenIdsPresent[msg.sender][_l1Token][l2TxHash][_tokenId] = true;

        emit DepositInitiated(l2TxHash, msg.sender, _l2Receiver, _l1Token, _tokenId);
    }

     /// @notice Initiates a batch deposit by locking token on the contract and sending the request
    /// of processing an L2 transaction where tokens would be minted
    /// @param _l2Receiver The account address that should receive the token on L2
    /// @param _l1Token The L1 token address which is deposited
    /// @param _tokenIds The L1 token IDs which are deposited
    /// @param _l2TxGasLimit The L2 gas limit to be used in the corresponding L2 transaction
    /// @param _l2TxGasPerPubdataByte The gasPerPubdataByteLimit to be used in the corresponding L2 transaction
    /// @param _refundRecipient The address on L2 that will receive the refund for the transaction.
    /// @return l2TxHashes The L2 transaction hashes of deposit finalization
    function depositBatch(
        address _l2Receiver,
        address _l1Token,
        uint256[] memory _tokenIds,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) public payable nonReentrant returns (bytes32[] memory l2TxHashes) {
        l2TxHashes = new bytes32[](_tokenIds.length);

        for (uint256 i; i < _tokenIds.length; i++) {
            bytes32 l2TxHash = deposit(_l2Receiver, _l1Token, _tokenIds[i], _l2TxGasLimit, _l2TxGasPerPubdataByte, _refundRecipient);
            l2TxHashes[i] = l2TxHash;
        }
    }

    /// @dev Transfers tokens from the depositor address to the smart contract address
    function _depositToken(address _from, IERC721 _token, uint256 _tokenId) internal {
        _token.transferFrom(_from, address(this), _tokenId);
        require(_token.ownerOf(_tokenId) == address(this), "Invalid transfer"); // The token has non-standard transfer logic
    }

    /// @dev Generate a calldata for calling the ERC721 deposit finalization on the L2 bridge contract
    function _getDepositL2Calldata(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _tokenId
    ) internal view returns (bytes memory txCalldata) {
        bytes memory gettersData = _getERC721Getters(_l1Token);
        (, bytes memory tokenURI) =  _l1Token.staticcall(abi.encodeCall(IERC721Metadata.tokenURI, (_tokenId)));

        txCalldata = abi.encodeCall(
            IL2Bridge.finalizeDeposit,
            (_l1Sender, _l2Receiver, _l1Token, 0, abi.encode(_tokenId, tokenURI, gettersData))
        );
    }

    /// @dev Receives and parses (name, symbol) from the token contract
    function _getERC721Getters(address _token) internal view returns (bytes memory data) {
        (, bytes memory data1) = _token.staticcall(abi.encodeCall(IERC721Metadata.name, ()));
        (, bytes memory data2) = _token.staticcall(abi.encodeCall(IERC721Metadata.symbol, ()));

        data = abi.encode(data1, data2);
    }

    /// @dev Withdraw token from the initiated deposit, that failed when finalizing on L2
    /// @param _depositSender The address of the deposit initiator
    /// @param _l1Token The address of the deposited L1 ERC721 token
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization
    function claimFailedDeposit(
        address _depositSender,
        address _l1Token,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external nonReentrant {
        bool proofValid = zkSync.proveL1ToL2TransactionStatus(
            _l2TxHash,
            _l2BatchNumber,
            _l2MessageIndex,
            _l2TxNumberInBatch,
            _merkleProof,
            TxStatus.Failure
        );
        require(proofValid, "yn");

        // Double mapping to avoid attack concerning token ID 0 without changing claimFailedDeposit() API
        uint256 tokenId = depositTokenIds[_depositSender][_l1Token][_l2TxHash];
        bool tokenIdValid = depositTokenIdsPresent[_depositSender][_l1Token][_l2TxHash][tokenId];
        require(tokenIdValid, "Invalid token ID");

        delete depositTokenIds[_depositSender][_l1Token][_l2TxHash];
        delete depositTokenIdsPresent[_depositSender][_l1Token][_l2TxHash][tokenId];

        // Withdraw token
        IERC721(_l1Token).transferFrom(address(this), _depositSender, tokenId);

        emit ClaimedFailedDeposit(_depositSender, _l1Token, tokenId);
    }

    /// @notice Finalize the withdrawal and release token
    /// @param _l2BatchNumber The L2 batch number where the withdrawal was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization
    function finalizeWithdrawal(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external nonReentrant {
        require(!isWithdrawalFinalized[_l2BatchNumber][_l2MessageIndex], "pw");

        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: _l2TxNumberInBatch,
            sender: l2Bridge,
            data: _message
        });

        (address l1Receiver, address l1Token, uint256 tokenId) = _parseL2WithdrawalMessage(l2ToL1Message.data);
        // Preventing the stack too deep error
        {
            bool success = zkSync.proveL2MessageInclusion(_l2BatchNumber, _l2MessageIndex, l2ToL1Message, _merkleProof);
            require(success, "nq");
        }

        isWithdrawalFinalized[_l2BatchNumber][_l2MessageIndex] = true;
        // Withdraw token
        IERC721(l1Token).transferFrom(address(this), l1Receiver, tokenId);

        emit WithdrawalFinalized(l1Receiver, l1Token, tokenId);
    }

    /// @dev Decode the withdraw message that came from L2
    function _parseL2WithdrawalMessage(
        bytes memory _l2ToL1message
    ) internal pure returns (address l1Receiver, address l1Token, uint256 tokenId) {
        // Check that the message length is correct.
        // It should be equal to the length of the function signature + address + address + uint256 = 4 + 20 + 20 + 32 =
        // 76 (bytes).
        require(_l2ToL1message.length == 76, "kk");

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        require(bytes4(functionSignature) == this.finalizeWithdrawal.selector, "nt");

        (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
        (l1Token, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
        (tokenId, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset);
    }

    /// @return The L2 token address that would be minted for deposit of the given L1 token
    function l2TokenAddress(address _l1Token) public view returns (address) {
        bytes32 constructorInputHash = keccak256(abi.encode(address(l2TokenBeacon), ""));
        bytes32 salt = bytes32(uint256(uint160(_l1Token)));

        return L2ContractHelper.computeCreate2Address(l2Bridge, salt, l2TokenProxyBytecodeHash, constructorInputHash);
    }
}
