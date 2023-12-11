// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IL1BridgeLegacy.sol";
import "./interfaces/IL1Bridge.sol";
import "./interfaces/IL2Bridge.sol";
import "./interfaces/IL2ERC20Bridge.sol";

import "./libraries/BridgeInitializationHelper.sol";

import "../bridgehub/bridgehub-interfaces/IBridgehub.sol";
import "../common/Messaging.sol";
import "../common/interfaces/IAllowList.sol";
import "../common/AllowListed.sol";
import "../common/libraries/UnsafeBytes.sol";
import "../common/libraries/L2ContractHelper.sol";
import "../common/ReentrancyGuard.sol";
import "../common/VersionTracker.sol";
import "../vendor/AddressAliasHelper.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Smart contract that allows depositing ERC20 tokens from Ethereum to zkSync Era
/// @dev It is standard implementation of ERC20 Bridge that can be used as a reference
/// for any other custom token bridges.
contract L1ERC20Bridge is IL1Bridge, IL1BridgeLegacy, AllowListed, ReentrancyGuard, VersionTracker {
    using SafeERC20 for IERC20;

    /// @dev The smart contract that manages the list with permission to call contract functions
    IAllowList internal immutable allowList;

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication
    IBridgehub internal immutable bridgehub;

    /// @dev A mapping L2 batch number => message number => flag
    /// @dev Used to indicate that L2 -> L1 message was already processed
    /// @dev this is just used for ERA for backwards compatibility reasons
    mapping(uint256 => mapping(uint256 => bool)) public isWithdrawalFinalizedEra;

    /// @dev A mapping account => L1 token address => L2 deposit transaction hash => amount
    /// @dev Used for saving the number of deposited funds, to claim them in case the deposit transaction will fail
    /// @dev this is just used for ERA for backwards compatibility reasons
    mapping(address => mapping(address => mapping(bytes32 => uint256))) internal depositAmountEra;

    /// @dev The standard address of deployed L2 bridge counterpart
    address public l2BridgeStandardAddress;

    /// @dev The standard address that acts as a beacon for L2 tokens
    address public l2TokenBeaconStandardAddress;

    /// @dev The bytecode hash of the L2 token contract
    bytes32 public l2TokenProxyBytecodeHash;

    mapping(address => uint256) public __DEPRECATED_lastWithdrawalLimitReset;

    /// @dev A mapping L1 token address => the accumulated withdrawn amount during the withdrawal limit window
    mapping(address => uint256) public __DEPRECATED_withdrawnAmountInWindow;

    /// @dev The accumulated deposited amount per user.
    /// @dev A mapping L1 token address => user address => the total deposited amount by the user
    mapping(address => mapping(address => uint256)) public totalDepositedAmountPerUser;

    /// @dev Era's chainID
    uint256 public immutable eraChainId;

    /// @dev Governor's address
    address public governor;

    // if not EOA then L1toL2 alias is applied.
    address public l2Governor;

    bytes32 public factoryDepsHash;

    /// @dev A mapping chainId => bridgeProxy. Used to store the bridge proxy's address, and to see if it has been deployed yet.
    mapping(uint256 => address) public l2BridgeAddress;

    /// @dev A mapping chainId => l2TokenBeacon. Used to store the token beacon proxy's address, and to see if it has been deployed yet.
    mapping(uint256 => address) public l2TokenBeaconAddress;

    /// @dev A mapping chainId => bridgeImplTxHash. Used to check the deploy transaction (which depends on its place in the priority queue).
    mapping(uint256 => bytes32) public bridgeImplDeployOnL2TxHash;

    /// @dev A mapping chainId => bridgeProxyTxHash. Used to check the deploy transaction (which depends on its place in the priority queue).
    mapping(uint256 => bytes32) public bridgeProxyDeployOnL2TxHash;

    /// @dev A mapping L2 _chainId => Batch number => message number => flag
    /// @dev Used to indicate that L2 -> L1 message was already processed
    mapping(uint256 => mapping(uint256 => mapping(uint256 => bool))) public isWithdrawalFinalized;

    /// @dev A mapping chainId => account => L1 token address => L2 deposit transaction hash => amount
    /// @dev Used for saving the number of deposited funds, to claim them in case the deposit transaction will fail
    mapping(uint256 => mapping(address => mapping(address => mapping(bytes32 => uint256)))) internal depositAmount;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IBridgehub _bridgehub, IAllowList _allowList, uint256 _eraChainId) reentrancyGuardInitializer {
        bridgehub = _bridgehub;
        allowList = _allowList;
        eraChainId = _eraChainId;
    }

    // used for calling reentracyGuardInitializer in testing and independent deployments
    function initialize() external reentrancyGuardInitializer {}

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
    /// implementation
    function initializeV2(
        bytes[] calldata _factoryDeps,
        address _l2TokenBeacon,
        address _l2Bridge,
        address _governor,
        address _l2Governor
    ) external payable reinitializer(2) {
        require(_l2TokenBeacon != address(0), "nf");
        require(_governor != address(0), "nh");
        // We are expecting to see the exact three bytecodes that are needed to initialize the bridge
        require(_factoryDeps.length == 3, "mk");
        // The caller miscalculated deploy transactions fees
        l2TokenProxyBytecodeHash = L2ContractHelper.hashL2Bytecode(_factoryDeps[2]);
        l2TokenBeaconStandardAddress = _l2TokenBeacon;
        l2BridgeStandardAddress = _l2Bridge;
        governor = _governor;
        l2Governor = _l2Governor;

        factoryDepsHash = keccak256(abi.encode(_factoryDeps));
    }

    function l2Bridge() external view returns (address) {
        return l2BridgeAddress[eraChainId];
    }

    /// @notice Checks that the message sender is the governor
    modifier onlyGovernor() {
        require(msg.sender == governor, "L1ERC20Bridge: not governor");
        _;
    }

    function initializeChainGovernance(
        uint256 _chainId,
        address _l2BridgeAddress,
        address _l2TokenBeaconAddress
    ) external onlyGovernor {
        l2BridgeAddress[_chainId] = _l2BridgeAddress;
        l2TokenBeaconAddress[_chainId] = _l2TokenBeaconAddress;
    }

    /// @dev Initializes a contract bridge for later use. Expected to be used in the proxy
    /// @dev During initialization deploys L2 bridge counterpart as well as provides some factory deps for it
    /// @param _factoryDeps A list of raw bytecodes that are needed for deployment of the L2 bridge
    /// @notice _factoryDeps[0] == a raw bytecode of L2 bridge implementation
    /// @notice _factoryDeps[1] == a raw bytecode of proxy that is used as L2 bridge
    /// @notice _factoryDeps[2] == a raw bytecode of token proxy
    /// @param _deployBridgeImplementationFee How much of the sent value should be allocated to deploying the L2 bridge
    /// implementation
    /// @param _deployBridgeProxyFee How much of the sent value should be allocated to deploying the L2 bridge proxy
    function startInitializeChain(
        uint256 _chainId,
        bytes[] calldata _factoryDeps,
        uint256 _deployBridgeImplementationFee,
        uint256 _deployBridgeProxyFee
    ) external payable {
        require(l2BridgeAddress[_chainId] == address(0), "L1ERC20Bridge: bridge already deployed");
        // We are expecting to see the exact three bytecodes that are needed to initialize the bridge
        require(_factoryDeps.length == 3, "L1ERC20Bridge: invalid number of factory deps");
        require(factoryDepsHash == keccak256(abi.encode(_factoryDeps)), "L1ERC20Bridge: invalid factory deps");
        // The caller miscalculated deploy transactions fees
        require(msg.value == _deployBridgeImplementationFee + _deployBridgeProxyFee, "L1ERC20Bridge: invalid fee");
        l2TokenProxyBytecodeHash = L2ContractHelper.hashL2Bytecode(_factoryDeps[2]);

        bytes32 l2BridgeImplementationBytecodeHash = L2ContractHelper.hashL2Bytecode(_factoryDeps[0]);
        bytes32 l2BridgeProxyBytecodeHash = L2ContractHelper.hashL2Bytecode(_factoryDeps[1]);

        // Deploy L2 bridge implementation contract
        (address bridgeImplementationAddr, bytes32 bridgeImplTxHash) = BridgeInitializationHelper
            .requestDeployTransaction(
                _chainId,
                bridgehub,
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
                IL2ERC20Bridge.initialize,
                (address(this), l2TokenProxyBytecodeHash, l2Governor)
            );
            l2BridgeProxyConstructorData = abi.encode(bridgeImplementationAddr, l2Governor, proxyInitializationParams);
        }

        // Deploy L2 bridge proxy contract
        (address bridgeProxyAddr, bytes32 bridgeProxyTxHash) = BridgeInitializationHelper.requestDeployTransaction(
            _chainId,
            bridgehub,
            _deployBridgeProxyFee,
            l2BridgeProxyBytecodeHash,
            l2BridgeProxyConstructorData,
            // No factory deps are needed for L2 bridge proxy, because it is already passed in previous step
            new bytes[](0)
        );
        require(bridgeProxyAddr == l2BridgeStandardAddress, "L1ERC20Bridge: bridge address does not match");

        bridgeImplDeployOnL2TxHash[_chainId] = bridgeImplTxHash;
        bridgeProxyDeployOnL2TxHash[_chainId] = bridgeProxyTxHash;
    }

    /// @dev We have to confirm that the deploy transactions succeeded.
    function finishInitializeChain(
        uint256 _chainId,
        uint256 _bridgeImplTxL2BatchNumber,
        uint256 _bridgeImplTxL2MessageIndex,
        uint16 _bridgeImplTxL2TxNumberInBatch,
        bytes32[] calldata _bridgeImplTxMerkleProof,
        uint256 _bridgeProxyTxL2BatchNumber,
        uint256 _bridgeProxyTxL2MessageIndex,
        uint16 _bridgeProxyTxL2TxNumberInBatch,
        bytes32[] calldata _bridgeProxyTxMerkleProof
    ) external {
        require(l2BridgeAddress[_chainId] == address(0), "L1ERC20Bridge: bridge already deployed");
        require(bridgeImplDeployOnL2TxHash[_chainId] != 0x00, "L1ERC20Bridge: bridge implementation tx not sent");

        require(
            bridgehub.proveL1ToL2TransactionStatus(
                _chainId,
                bridgeImplDeployOnL2TxHash[_chainId],
                _bridgeImplTxL2BatchNumber,
                _bridgeImplTxL2MessageIndex,
                _bridgeImplTxL2TxNumberInBatch,
                _bridgeImplTxMerkleProof,
                TxStatus(1)
            ),
            "L1ERC20Bridge: bridge implementation tx not confirmed"
        );
        require(
            bridgehub.proveL1ToL2TransactionStatus(
                _chainId,
                bridgeProxyDeployOnL2TxHash[_chainId],
                _bridgeProxyTxL2BatchNumber,
                _bridgeProxyTxL2MessageIndex,
                _bridgeProxyTxL2TxNumberInBatch,
                _bridgeProxyTxMerkleProof,
                TxStatus(1)
            ),
            "L1ERC20Bridge: bridge proxy tx not confirmed"
        );
        bridgeImplDeployOnL2TxHash[_chainId] = 0x00;
        bridgeProxyDeployOnL2TxHash[_chainId] = 0x00;
        l2BridgeAddress[_chainId] = l2BridgeStandardAddress;
        l2TokenBeaconAddress[_chainId] = l2TokenBeaconStandardAddress;
    }

    /// @notice Legacy deposit method with refunding the fee to the caller, use another `deposit` method instead.
    /// @dev Initiates a deposit by locking funds on the contract and sending the request
    /// of processing an L2 transaction where tokens would be minted
    /// @param _l2Receiver The account address that should receive funds on L2
    /// @param _l1Token The L1 token address which is deposited
    /// @param _amount The total amount of tokens to be bridged
    /// @param _l2TxGasLimit The L2 gas limit to be used in the corresponding L2 transaction
    /// @param _l2TxGasPerPubdataByte The gasPerPubdataByteLimit to be used in the corresponding L2 transaction
    /// @return l2TxHash The L2 transaction hash of deposit finalization
    /// NOTE: the function doesn't use `nonreentrant` and `senderCanCallFunction` modifiers, because the inner
    /// method does.
    function deposit(
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte
    ) external payable returns (bytes32 l2TxHash) {
        l2TxHash = deposit(
            eraChainId,
            _l2Receiver,
            _l1Token,
            _amount,
            _l2TxGasLimit,
            _l2TxGasPerPubdataByte,
            address(0)
        );
    }

    /// @notice Legacy deposit method with no chainId, use another `deposit` method instead.
    /// @dev Initiates a deposit by locking funds on the contract and sending the request
    /// of processing an L2 transaction where tokens would be minted
    /// @param _l2Receiver The account address that should receive funds on L2
    /// @param _l1Token The L1 token address which is deposited
    /// @param _amount The total amount of tokens to be bridged
    /// @param _l2TxGasLimit The L2 gas limit to be used in the corresponding L2 transaction
    /// @param _l2TxGasPerPubdataByte The gasPerPubdataByteLimit to be used in the corresponding L2 transaction
    /// @return l2TxHash The L2 transaction hash of deposit finalization
    /// @param _refundRecipient The address on L2 that will receive the refund for the transaction.
    /// NOTE: the function doesn't use `nonreentrant` and `senderCanCallFunction` modifiers,
    /// because the inner method does.
    function deposit(
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) external payable returns (bytes32 l2TxHash) {
        l2TxHash = deposit(
            eraChainId,
            _l2Receiver,
            _l1Token,
            _amount,
            _l2TxGasLimit,
            _l2TxGasPerPubdataByte,
            _refundRecipient
        );
    }

    /// @notice Initiates a deposit by locking funds on the contract and sending the request
    /// of processing an L2 transaction where tokens would be minted
    /// @param _l2Receiver The account address that should receive funds on L2
    /// @param _l1Token The L1 token address which is deposited
    /// @param _amount The total amount of tokens to be bridged
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
        uint256 _chainId,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) public payable nonReentrant senderCanCallFunction(allowList) returns (bytes32 l2TxHash) {
        require(_amount != 0, "2T"); // empty deposit amount
        uint256 amount = _depositFunds(msg.sender, IERC20(_l1Token), _amount);
        require(amount == _amount, "1T"); // The token has non-standard transfer logic
        // verify the deposit amount is allowed
        _verifyDepositLimit(_l1Token, msg.sender, _amount, false);

        bytes memory l2TxCalldata = _getDepositL2Calldata(msg.sender, _l2Receiver, _l1Token, amount);
        // If the refund recipient is not specified, the refund will be sent to the sender of the transaction.
        // Otherwise, the refund will be sent to the specified address.
        // If the recipient is a contract on L1, the address alias will be applied.
        address refundRecipient = _refundRecipient;
        if (_refundRecipient == address(0)) {
            refundRecipient = msg.sender != tx.origin ? AddressAliasHelper.applyL1ToL2Alias(msg.sender) : msg.sender;
        }

        l2TxHash = _depositSendTx(_chainId, l2TxCalldata, _l2TxGasLimit, _l2TxGasPerPubdataByte, refundRecipient);

        // Save the deposited amount to claim funds on L1 if the deposit failed on L2
        if (_chainId == eraChainId) {
            depositAmountEra[msg.sender][_l1Token][l2TxHash] = amount;
        } else {
            depositAmount[_chainId][msg.sender][_l1Token][l2TxHash] = amount;
        }

        emit DepositInitiatedChainId(_chainId, l2TxHash, msg.sender, _l2Receiver, _l1Token, amount);
        if (_chainId == eraChainId) {
            emit DepositInitiated(l2TxHash, msg.sender, _l2Receiver, _l1Token, amount);
        }
    }

    // to avoid stack too deep error
    function _depositSendTx(
        uint256 _chainId,
        bytes memory _l2TxCalldata,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) internal returns (bytes32 l2TxHash) {
        l2TxHash = bridgehub.requestL2Transaction{value: msg.value}(
            _chainId,
            l2BridgeAddress[_chainId],
            0, // L2 msg.value
            _l2TxCalldata,
            _l2TxGasLimit,
            _l2TxGasPerPubdataByte,
            new bytes[](0),
            _refundRecipient
        );
    }

    /// @dev Transfers tokens from the depositor address to the smart contract address
    /// @return The difference between the contract balance before and after the transferring of funds
    function _depositFunds(address _from, IERC20 _token, uint256 _amount) internal returns (uint256) {
        uint256 balanceBefore = _token.balanceOf(address(this));
        _token.safeTransferFrom(_from, address(this), _amount);
        uint256 balanceAfter = _token.balanceOf(address(this));

        return balanceAfter - balanceBefore;
    }

    /// @dev Generate a calldata for calling the deposit finalization on the L2 bridge contract
    function _getDepositL2Calldata(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount
    ) internal view returns (bytes memory txCalldata) {
        bytes memory gettersData = _getERC20Getters(_l1Token);

        txCalldata = abi.encodeCall(
            IL2Bridge.finalizeDeposit,
            (_l1Sender, _l2Receiver, _l1Token, _amount, gettersData)
        );
    }

    /// @dev Receives and parses (name, symbol, decimals) from the token contract
    function _getERC20Getters(address _token) internal view returns (bytes memory data) {
        (, bytes memory data1) = _token.staticcall(abi.encodeCall(IERC20Metadata.name, ()));
        (, bytes memory data2) = _token.staticcall(abi.encodeCall(IERC20Metadata.symbol, ()));
        (, bytes memory data3) = _token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        data = abi.encode(data1, data2, data3);
    }

    /// @dev Withdraw funds from the initiated deposit, that failed when finalizing on L2
    /// @param _depositSender The address of the deposit initiator
    /// @param _l1Token The address of the deposited L1 ERC20 token
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization
    function claimFailedDeposit(
        uint256 _chainId,
        address _depositSender,
        address _l1Token,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external nonReentrant senderCanCallFunction(allowList) {
        bool proofValid = bridgehub.proveL1ToL2TransactionStatus(
            _chainId,
            _l2TxHash,
            _l2BatchNumber,
            _l2MessageIndex,
            _l2TxNumberInBatch,
            _merkleProof,
            TxStatus.Failure
        );
        require(proofValid, "yn");

        uint256 amount = 0;
        if (_chainId == eraChainId) {
            amount = depositAmountEra[_depositSender][_l1Token][_l2TxHash];
        } else {
            amount = depositAmount[_chainId][_depositSender][_l1Token][_l2TxHash];
        }
        require(amount > 0, "y1");

        // Change the total deposited amount by the user
        _verifyDepositLimit(_l1Token, _depositSender, amount, true);

        if (_chainId == eraChainId) {
            delete depositAmountEra[_depositSender][_l1Token][_l2TxHash];
        } else {
            delete depositAmount[_chainId][_depositSender][_l1Token][_l2TxHash];
        }
        // Withdraw funds
        IERC20(_l1Token).safeTransfer(_depositSender, amount);

        emit ClaimedFailedDepositChainId(_chainId, _depositSender, _l1Token, amount);
        if (_chainId == eraChainId) {
            emit ClaimedFailedDeposit(_depositSender, _l1Token, amount);
        }
    }

    /// @notice Finalize the withdrawal and release funds
    /// @param _l2BatchNumber The L2 batch number where the withdrawal was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization
    function finalizeWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external nonReentrant senderCanCallFunction(allowList) {
        if (_chainId == eraChainId) {
            require(!isWithdrawalFinalizedEra[_l2BatchNumber][_l2MessageIndex], "pw");
        } else {
            require(!isWithdrawalFinalized[_chainId][_l2BatchNumber][_l2MessageIndex], "pw");
        }

        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: _l2TxNumberInBatch,
            sender: l2BridgeAddress[_chainId],
            data: _message
        });

        // Preventing the stack too deep error
        {
            bool success = bridgehub.proveL2MessageInclusion(
                _chainId,
                _l2BatchNumber,
                _l2MessageIndex,
                l2ToL1Message,
                _merkleProof
            );
            require(success, "nq");
        }

        {
            // Preventing the stack too deep error
            if (_chainId == eraChainId) {
                isWithdrawalFinalizedEra[_l2BatchNumber][_l2MessageIndex] = true;
            } else {
                isWithdrawalFinalized[_chainId][_l2BatchNumber][_l2MessageIndex] = true;
            }
        }

        {
            (address l1Receiver, address l1Token, uint256 amount) = _parseL2WithdrawalMessage(l2ToL1Message.data);

            // Withdraw funds
            IERC20(l1Token).safeTransfer(l1Receiver, amount);

            emit WithdrawalFinalizedChainId(_chainId, l1Receiver, l1Token, amount);
            if (_chainId == eraChainId) {
                emit WithdrawalFinalized(l1Receiver, l1Token, amount);
            }
        }
    }

    /// @dev Decode the withdraw message that came from L2
    function _parseL2WithdrawalMessage(
        bytes memory _l2ToL1message
    ) internal pure returns (address l1Receiver, address l1Token, uint256 amount) {
        // Check that the message length is correct.
        // It should be equal to the length of the function signature + address + address + uint256 = 4 + 20 + 20 + 32 =
        // 76 (bytes).
        require(_l2ToL1message.length == 76, "kk");

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        require(bytes4(functionSignature) == this.finalizeWithdrawal.selector, "nt");

        (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
        (l1Token, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
        (amount, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset);
    }

    /// @dev Verify the deposit limit is reached to its cap or not
    function _verifyDepositLimit(address _l1Token, address _depositor, uint256 _amount, bool _claiming) internal {
        IAllowList.Deposit memory limitData = IAllowList(allowList).getTokenDepositLimitData(_l1Token);
        if (!limitData.depositLimitation) return; // no deposit limitation is placed for this token

        if (_claiming) {
            totalDepositedAmountPerUser[_l1Token][_depositor] -= _amount;
        } else {
            require(totalDepositedAmountPerUser[_l1Token][_depositor] + _amount <= limitData.depositCap, "d1");
            totalDepositedAmountPerUser[_l1Token][_depositor] += _amount;
        }
    }

    /// @return The L2 token address that would be minted for deposit of the given L1 token
    function l2TokenAddress(address _l1Token) public view returns (address) {
        bytes32 constructorInputHash = keccak256(abi.encode(address(l2TokenBeaconStandardAddress), ""));
        bytes32 salt = bytes32(uint256(uint160(_l1Token)));

        return
            L2ContractHelper.computeCreate2Address(
                l2BridgeStandardAddress,
                salt,
                l2TokenProxyBytecodeHash,
                constructorInputHash
            );
    }
}
