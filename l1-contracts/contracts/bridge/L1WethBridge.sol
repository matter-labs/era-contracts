// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IL1Bridge.sol";
import "./interfaces/IL1BridgeLegacy.sol";
import "./interfaces/IL2WethBridge.sol";
import "./interfaces/IL2Bridge.sol";
import "./interfaces/IWETH9.sol";
import "../bridgehub/bridgehub-interfaces/IBridgehub.sol";
import "../state-transition/chain-interfaces/IMailbox.sol";
import "../state-transition/chain-interfaces/IGetters.sol";

import "./libraries/BridgeInitializationHelper.sol";

import "../common/Messaging.sol";
import "../common/libraries/UnsafeBytes.sol";
import "../common/ReentrancyGuard.sol";
import "../common/VersionTracker.sol";
import "../common/libraries/L2ContractHelper.sol";
import {L2_ETH_TOKEN_SYSTEM_CONTRACT_ADDR} from "../common/L2ContractAddresses.sol";
import "../vendor/AddressAliasHelper.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev This contract is designed to streamline and enhance the user experience
/// for bridging WETH tokens between L1 and L2 networks. The primary goal of this bridge is to
/// simplify the process by minimizing the number of transactions required, thus improving
/// efficiency and user experience.
/// @dev The default workflow for bridging WETH is performing three separate transactions: unwrap WETH to ETH,
/// deposit ETH to L2, and wrap ETH to WETH on L2. The `L1WethBridge` reduces this to a single
/// transaction, enabling users to bridge their WETH tokens directly between L1 and L2 networks.
/// @dev This contract accepts WETH deposits on L1, unwraps them to ETH, and sends the ETH to the L2
/// WETH bridge contract, where it is wrapped back into WETH and delivered to the L2 recipient.
/// @dev For withdrawals, the contract receives ETH from the L2 WETH bridge contract, wraps it into
/// WETH, and sends the WETH to the L1 recipient.
/// @dev The `L1WethBridge` contract works in conjunction with its L2 counterpart, `L2WethBridge`.
/// @dev Note VersionTracker stores at random addresses, so we can add it to the inheritance tree.
contract L1WethBridge is IL1Bridge, ReentrancyGuard, VersionTracker {
    using SafeERC20 for IERC20;

    address public constant ETH_TOKEN_ADDRESS = address(1);

    /// @dev Event emitted when ETH is received by the contract.
    event EthReceived(uint256 amount);

    /// @dev The address of the WETH token on L1
    address payable public immutable l1WethAddress;

    /// @dev bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication
    IBridgehub public immutable bridgehub;

    /// @dev Era's chainID
    uint256 public immutable eraChainId;

    /// @dev Governor's address
    address public governor;

    /// @dev The address of deployed L2 WETH bridge counterpart
    address public l2BridgeStandardAddressEthIsBase;
    address public l2BridgeStandardAddressEthIsNotBase;

    /// @dev The address of the WETH on L2
    address public l2WethStandardAddressEthIsBase;
    address public l2WethStandardAddressEthIsNotBase;

    /// @dev Hash of the factory deps that were used to deploy L2 WETH bridge
    bytes32 public factoryDepsHash;

    /// @dev A mapping chainId => bridgeProxy. Used to store the bridge proxy's address, and to see if it has been deployed yet.
    mapping(uint256 => address) public l2BridgeAddress;

    /// @dev A mapping chainId => WethProxy. Used to store the weth proxy's address, and to see if it has been deployed yet.
    mapping(uint256 => address) public l2WethAddress;

    /// @dev A mapping chainId => bridgeImplTxHash. Used to check the deploy transaction (which depends on its place in the priority queue).
    mapping(uint256 => bytes32) public bridgeImplDeployOnL2TxHash;

    /// @dev A mapping chainId => bridgeProxyTxHash. Used to check the deploy transaction (which depends on its place in the priority queue).
    mapping(uint256 => bytes32) public bridgeProxyDeployOnL2TxHash;

    /// @dev A mapping chainId => account => L2 deposit transaction hash => amount
    /// @dev Used for saving the number of deposited funds, to claim them in case the deposit transaction will fail
    /// @dev only used when it is not the base token, as then it is sent to refund recipient
    mapping(uint256 => mapping(address => mapping(bytes32 => uint256))) internal depositAmount;

    /// @dev we need to switch over from the diamondProxy Storage's isWithdrawalFinalized to this one for era
    /// we first deploy the new Mailbox facet, then transfer the Eth, then deploy this.
    uint256 eraIsWithdrawalFinalizedStorageSwitch;

    /// @dev address of EraDiamondProxy
    address eraDiamondProxy;

    /// @dev A mapping L2 chainId => Batch number => message number => flag
    /// @dev Used to indicate that L2 -> L1 WETH message was already processed
    mapping(uint256 => mapping(uint256 => mapping(uint256 => bool))) public isWithdrawalFinalized;

    /// @dev A mapping chainId => amount. Used before we activate hyperbridging.
    mapping(uint256 => uint256) public chainBalance;

    /// @notice Emitted when the withdrawal is finalized on L1 and funds are released.
    /// @param to The address to which the funds were sent
    /// @param amount The amount of funds that were sent
    event EthWithdrawalFinalized(uint256 chainId, address indexed to, uint256 amount);

    function l2Bridge() external view returns (address) {
        return l2BridgeAddress[eraChainId];
    }

    /// @notice Checks that the message sender is the governor
    modifier onlyGovernor() {
        require(msg.sender == governor, "L1WETHBridge: not governor");
        _;
    }

    /// @notice Checks that the message sender is the governor
    modifier onlyBridgehubOrEthChain(uint256 _chainId) {
        require(
            (msg.sender == address(bridgehub)) || (bridgehub.baseToken(_chainId) == ETH_TOKEN_ADDRESS),
            "L1WETHBridge: not bridgehub or eth chain"
        );
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(
        address payable _l1WethAddress,
        IBridgehub _bridgehub,
        uint256 _eraChainId,
        address _eraDiamondProxy
    ) reentrancyGuardInitializer {
        l1WethAddress = _l1WethAddress;
        bridgehub = _bridgehub;
        eraChainId = _eraChainId;
        eraDiamondProxy = _eraDiamondProxy;
    }

    // used for calling reentracyGuardInitializer in testing and independent deployments
    function initialize() external reentrancyGuardInitializer {}

    /// @dev Initializes a contract bridge for later use. Expected to be used in the proxy
    /// @dev During initialization deploys L2 WETH bridge counterpart as well as provides some factory deps for it
    /// @param _factoryDeps A list of raw bytecodes that are needed for deployment of the L2 WETH bridge
    /// @notice _factoryDeps[0] == a raw bytecode of L2 WETH bridge implementation. Note this deploys the Weth token
    /// implementation and proxy upon initialization
    /// @notice _factoryDeps[1] == a raw bytecode of proxy that is used as L2 WETH bridge
    /// @param _l2WethStandardAddressEthIsBase Pre-calculated address of L2 WETH token
    /// @param _governor Address which can change L2 WETH token implementation and upgrade the bridge
    function initializeV2(
        bytes[] calldata _factoryDeps,
        address _l2WethStandardAddressEthIsBase,
        address _l2WethStandardAddressEthIsNotBase,
        address _l2BridgeStandardAddressEthIsBase,
        address _l2BridgeStandardAddressEthIsNotBase,
        address _governor,
        uint256 _eraIsWithdrawalFinalizedStorageSwitch
    ) external reinitializer(2) {
        require(_l2WethStandardAddressEthIsBase != address(0), "L2 WETH address cannot be zero");
        require(_l2WethStandardAddressEthIsNotBase != address(0), "L2 WETH not eth based address cannot be zero");
        require(_l2BridgeStandardAddressEthIsBase != address(0), "L2 bridge address cannot be zero");
        require(_l2BridgeStandardAddressEthIsNotBase != address(0), "L2 bridge not eth based address cannot be zero");
        require(_governor != address(0), "Governor address cannot be zero");
        require(_factoryDeps.length == 2, "Invalid base factory deps length provided");

        l2WethStandardAddressEthIsBase = _l2WethStandardAddressEthIsBase;
        l2WethStandardAddressEthIsNotBase = _l2WethStandardAddressEthIsNotBase;

        l2BridgeStandardAddressEthIsBase = _l2BridgeStandardAddressEthIsBase;
        l2BridgeStandardAddressEthIsNotBase = _l2BridgeStandardAddressEthIsNotBase;

        governor = _governor;
        eraIsWithdrawalFinalizedStorageSwitch = _eraIsWithdrawalFinalizedStorageSwitch;

        // #if !EOA_GOVERNOR
        uint32 size;
        assembly {
            size := extcodesize(_governor)
        }
        require(size > 0, "L1WETHBridge, governor cannot be EOA");
        // #endif

        factoryDepsHash = keccak256(abi.encode(_factoryDeps));
    }

    function initializeChainGovernance(
        uint256 _chainId,
        address _l2BridgeAddress,
        address _l2WethAddress
    ) external onlyGovernor {
        l2BridgeAddress[_chainId] = _l2BridgeAddress;
        l2WethAddress[_chainId] = _l2WethAddress;
    }

    /// @dev Initializes a contract bridge for later use. Expected to be used in the proxy
    /// @dev During initialization deploys L2 WETH bridge counterpart as well as provides some factory deps for it
    /// @param _chainId of the chosen chain
    /// @param _mintValue the asset to be minted on the destination chain. If base token is ether, this will be msg.value
    /// @param _factoryDeps A list of raw bytecodes that are needed for deployment of the L2 WETH bridge
    /// @notice _factoryDeps[0] == a raw bytecode of L2 WETH bridge implementation. Note this deploys the Weth token
    /// implementation and proxy upon initialization
    /// @notice _factoryDeps[1] == a raw bytecode of proxy that is used as L2 WETH bridge
    /// @param _deployBridgeImplementationFee The fee that will be paid for the L1 -> L2 transaction for deploying L2
    /// bridge implementation
    /// @param _deployBridgeProxyFee The fee that will be paid for the L1 -> L2 transaction for deploying L2 bridge
    /// proxy
    function startInitializeChain(
        uint256 _chainId,
        uint256 _mintValue,
        bytes[] calldata _factoryDeps,
        uint256 _deployBridgeImplementationFee,
        uint256 _deployBridgeProxyFee
    ) external payable {
        uint256 mintValue = _mintValue;
        bool ethIsBaseToken;
        {
            require(l2BridgeAddress[_chainId] == address(0), "L1WETHBridge: bridge already deployed");
            require(_factoryDeps.length == 2, "L1WethBridge: Invalid number of factory deps");

            ethIsBaseToken = (bridgehub.baseToken(_chainId) == ETH_TOKEN_ADDRESS);
            if (ethIsBaseToken) {
                mintValue = msg.value;
            } else {
                require(msg.value == 0, "L1WethBridge: msg.value not 0 for non eth base token");
                /// we could also add this feature later if we want to
            }

            require(
                mintValue == _deployBridgeImplementationFee + _deployBridgeProxyFee,
                "Miscalculated deploy transactions fees"
            );

            require(factoryDepsHash == keccak256(abi.encode(_factoryDeps)), "L1WethBridge: Invalid factory deps");
        }

        bytes32 l2WethBridgeImplementationBytecodeHash = L2ContractHelper.hashL2Bytecode(_factoryDeps[0]);
        address wethBridgeImplementationAddr;
        {
            bytes32 bridgeImplTxHash;
            // Deploy L2 bridge implementation contract
            (wethBridgeImplementationAddr, bridgeImplTxHash) = BridgeInitializationHelper.requestDeployTransaction(
                ethIsBaseToken,
                _chainId,
                bridgehub,
                _deployBridgeImplementationFee,
                l2WethBridgeImplementationBytecodeHash,
                "", // Empty constructor data
                _factoryDeps // All factory deps are needed for L2 bridge
            );
            bridgeImplDeployOnL2TxHash[_chainId] = bridgeImplTxHash;
        }
        // Prepare the proxy constructor data
        bytes memory l2WethBridgeProxyConstructorData;
        {
            address proxyAdmin = readProxyAdmin();
            address l2ProxyAdmin = AddressAliasHelper.applyL1ToL2Alias(proxyAdmin);
            address l2Governor = AddressAliasHelper.applyL1ToL2Alias(governor);
            // Data to be used in delegate call to initialize the proxy
            bytes memory proxyInitializationParams = abi.encodeCall(
                IL2WethBridge.initialize,
                (address(this), l1WethAddress, l2ProxyAdmin, l2Governor, ethIsBaseToken)
            );
            l2WethBridgeProxyConstructorData = abi.encode(
                wethBridgeImplementationAddr,
                l2ProxyAdmin,
                proxyInitializationParams
            );
        }

        bytes32 l2WethBridgeProxyBytecodeHash = L2ContractHelper.hashL2Bytecode(_factoryDeps[1]);
        bytes32 bridgeProxyTxHash;

        {
            address wethBridgeProxyAddress;

            // Deploy L2 bridge proxy contract
            (wethBridgeProxyAddress, bridgeProxyTxHash) = BridgeInitializationHelper.requestDeployTransaction(
                ethIsBaseToken,
                _chainId,
                bridgehub,
                _deployBridgeProxyFee,
                l2WethBridgeProxyBytecodeHash,
                l2WethBridgeProxyConstructorData,
                // No factory deps are needed for L2 bridge proxy, because it is already passed in the previous step
                new bytes[](0)
            );
            require(
                (wethBridgeProxyAddress ==
                    (ethIsBaseToken ? l2BridgeStandardAddressEthIsBase : l2BridgeStandardAddressEthIsNotBase)),
                "L1WETHBridge: bridge address does not match"
            );
        }
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
        delete bridgeImplDeployOnL2TxHash[_chainId];
        delete bridgeProxyDeployOnL2TxHash[_chainId];

        bool ethIsBase = (bridgehub.baseToken(_chainId) == ETH_TOKEN_ADDRESS);

        l2BridgeAddress[_chainId] = ethIsBase ? l2BridgeStandardAddressEthIsBase : l2BridgeStandardAddressEthIsNotBase;
        l2WethAddress[_chainId] = ethIsBase ? l2WethStandardAddressEthIsBase : l2WethStandardAddressEthIsNotBase;
    }

    /// @notice Initiates a WETH deposit by depositing WETH into the L1 bridge contract, unwrapping it to ETH
    /// and sending it to the L2 bridge contract where ETH will be wrapped again to WETH and sent to the L2 recipient.
    /// @param _l2Receiver The account address that should receive WETH on L2
    /// @param _l1Token The L1 token address which is deposited (needs to be WETH address)
    /// @param _mintValue The total amount of base tokens to be minted. Covers both gas and msg.Value.
    /// If the base token is ETH, this will be overriden with msg.value + amount
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
    /// are controllable through the Mailbox,
    /// since the Mailbox applies address aliasing to the from address for the L2 tx if the L1 msg.sender is a contract.
    /// Without address aliasing for L1 contracts as refund recipients they would not be able to make proper L2 tx
    /// requests
    /// through the Mailbox to use or withdraw the funds from L2, and the funds would be lost.
    /// @return txHash The L2 transaction hash of deposit finalization
    function deposit(
        uint256 _chainId,
        address _l2Receiver,
        address _l1Token,
        uint256 _mintValue,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) external payable nonReentrant returns (bytes32 txHash) {
        uint256 mintValue = _mintValue;
        uint256 amount = _amount;
        {
            require(((_l1Token == l1WethAddress) || (_l1Token == ETH_TOKEN_ADDRESS)), "L1WETH Bridge: Invalid L1 token address");
            bool ethIsBaseToken = (bridgehub.baseToken(_chainId) == ETH_TOKEN_ADDRESS);
            require((_amount != 0) || (!ethIsBaseToken), "L1WETH Bridge: Amount cannot be zero when Eth is base token");
            require(l2BridgeAddress[_chainId] != address(0), "L1WETH Bridge: Bridge is not deployed");

            if (ethIsBaseToken) {
                mintValue = msg.value + _amount;
                // we check this in the Mailbox as well
                require(_mintValue <= mintValue, "L1WETH Bridge: Incorrect amount of ETH sent");
            } else {
                amount = msg.value + _amount;
            }

            if (_amount > 0) {
                // Deposit WETH tokens from the depositor address to the smart contract address
                IERC20(l1WethAddress).safeTransferFrom(msg.sender, address(this), _amount);
                // Unwrap WETH tokens (smart contract address receives the equivalent amount of ETH)
                IWETH9(l1WethAddress).withdraw(_amount);
            }
        }
        {
            // Request the finalization of the deposit on the L2 side
            bytes memory l2TxCalldata = _getDepositL2Calldata(msg.sender, _l2Receiver, l1WethAddress, amount);

            // If the refund recipient is not specified, the refund will be sent to the sender of the transaction.
            // Otherwise, the refund will be sent to the specified address.
            // If the recipient is a contract on L1, the address alias will be applied.
            address refundRecipient = _refundRecipient;
            if (_refundRecipient == address(0)) {
                refundRecipient = msg.sender != tx.origin
                    ? AddressAliasHelper.applyL1ToL2Alias(msg.sender)
                    : msg.sender;
            }
            txHash = _depositSendTx(
                _chainId,
                mintValue,
                amount,
                l2TxCalldata,
                _l2TxGasLimit,
                _l2TxGasPerPubdataByte,
                refundRecipient
            );
        }
        emit DepositInitiatedSharedBridge(_chainId, txHash, msg.sender, _l2Receiver, _l1Token, amount);
        if (_chainId == eraChainId) {
            emit DepositInitiated(txHash, msg.sender, _l2Receiver, _l1Token, amount);
        }
    }

    function _depositSendTx(
        uint256 _chainId,
        uint256 _mintValue,
        uint256 _amount,
        bytes memory _l2TxCalldata,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) internal returns (bytes32 txHash) {
        bool ethIsBaseToken = (bridgehub.baseToken(_chainId) == ETH_TOKEN_ADDRESS);
        if (ethIsBaseToken) {
            // note to have a unified interface with ERC20s we transfer all the value and redeposit it with bridgehubDeposit.
            // we don't increase chainBalance because we will add it in BridgehubDeposit
            // we don't save the depositAmount because base asset is sent to refundrecipient

            IBridgehub.L2TransactionRequest memory request = IBridgehub.L2TransactionRequest({
                chainId: _chainId,
                payer: msg.sender,
                l2Contract: l2BridgeAddress[_chainId],
                mintValue: _mintValue,
                l2Value: _amount,
                l2Calldata: _l2TxCalldata,
                l2GasLimit: _l2TxGasLimit,
                l2GasPerPubdataByteLimit: _l2TxGasPerPubdataByte,
                factoryDeps: new bytes[](0),
                refundRecipient: _refundRecipient
            });

            txHash = bridgehub.requestL2Transaction{value: _mintValue}(request);
        } else {
            IBridgehub.L2TransactionRequest memory request = IBridgehub.L2TransactionRequest({
                chainId: _chainId,
                payer: msg.sender,
                l2Contract: l2BridgeAddress[_chainId],
                mintValue: _mintValue, // the bridgehub will withdraw the mintValue from the other bridge for gas
                l2Value: 0, // the l2Value is 0, we are not tranferring the base asset
                l2Calldata: _l2TxCalldata,
                l2GasLimit: _l2TxGasLimit,
                l2GasPerPubdataByteLimit: _l2TxGasPerPubdataByte,
                factoryDeps: new bytes[](0),
                refundRecipient: _refundRecipient
            });

            txHash = bridgehub.requestL2Transaction(request);
            depositAmount[_chainId][msg.sender][txHash] = _amount;
            chainBalance[_chainId] += _amount;
        }
    }

    // we have to keep track of bridgehub deposits to track each chain's assets
    function bridgehubDeposit(
        uint256 _chainId,
        address _token,
        uint256 _amount,
        address //_prevMsgSender
    ) external payable override onlyBridgehubOrEthChain(_chainId) {
        require(_token == ETH_TOKEN_ADDRESS, "L1WETHBridge: Invalid token");
        chainBalance[_chainId] += _amount;
    }

    /// @dev Generate a calldata for calling the deposit finalization on the L2 WETH bridge contract
    function _getDepositL2Calldata(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount
    ) internal pure returns (bytes memory txCalldata) {
        txCalldata = abi.encodeCall(
            IL2Bridge.finalizeDeposit,
            (_l1Sender, _l2Receiver, _l1Token, _amount, new bytes(0))
        );
    }

    /// @notice Withdraw funds from the initiated deposit, that failed when finalizing on L2.
    /// Note: Refund is performed by sending an equivalent amount of ETH on L2 to the specified deposit refund
    /// recipient address.
    function claimFailedDeposit(
        uint256 _chainId,
        address _depositSender,
        address _l1Token,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external nonReentrant {
        bool proofValid = bridgehub.proveL1ToL2TransactionStatus(
            _chainId,
            _l2TxHash,
            _l2BatchNumber,
            _l2MessageIndex,
            _l2TxNumberInBatch,
            _merkleProof,
            TxStatus.Failure
        );
        require(proofValid, "L1WethBridge: Invalid L2 transaction status proof");

        uint256 amount = 0;
        amount = depositAmount[_chainId][_depositSender][_l2TxHash];
        require(amount > 0, "L1WethBridge: amount is zero");
        require(chainBalance[_chainId] >= amount, "L1WethBridge: chainBalance is too low");
        chainBalance[_chainId] -= amount;

        delete depositAmount[_chainId][_depositSender][_l2TxHash];

        // Withdraw funds
        // Wrap ETH to WETH tokens (smart contract address receives the equivalent amount of WETH)
        IWETH9(l1WethAddress).deposit{value: amount}();
        // Transfer WETH tokens from the smart contract address to the withdrawal receiver
        IERC20(l1WethAddress).safeTransfer(_depositSender, amount);

        emit ClaimedFailedDepositSharedBridge(_chainId, _depositSender, _l1Token, amount);
    }

    /// @notice Finalize the withdrawal and release funds
    /// @param _l2BatchNumber The L2 batch number where the ETH (WETH) withdrawal was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the ETH
    /// withdrawal message containing additional data about WETH withdrawal
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the ETH withdrawal log was sent
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization
    function finalizeWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external nonReentrant {
        require(!isWithdrawalFinalized[_chainId][_l2BatchNumber][_l2MessageIndex], "Withdrawal is already finalized");

        if ((_chainId == eraChainId) && ((_l2BatchNumber < eraIsWithdrawalFinalizedStorageSwitch))) {
            // in this case we have to check we don't double withdraw ether
            // we are not fully finalized if eth has not been withdrawn
            // note the WETH bridge has not yet been deployed, so it cannot be the case that we withdrew Eth but not WETH.
            bool alreadyFinalized = IGetters(eraDiamondProxy).isEthWithdrawalFinalized(_l2BatchNumber, _l2MessageIndex);
            require(!alreadyFinalized, "Withdrawal is already finalized");
        }

        (address l1WithdrawReceiver, uint256 amount, bool wrapToWeth) = _checkWithdrawal(
            _chainId,
            _l2BatchNumber,
            _l2MessageIndex,
            _l2TxNumberInBatch,
            _message,
            _merkleProof
        );
        require(chainBalance[_chainId] >= amount, "L1WethBridge: chainBalance is too low");
        chainBalance[_chainId] -= amount;
        if (wrapToWeth) {
            // Wrap ETH to WETH tokens (smart contract address receives the equivalent amount of WETH)
            IWETH9(l1WethAddress).deposit{value: amount}();
            // Transfer WETH tokens from the smart contract address to the withdrawal receiver
            IERC20(l1WethAddress).safeTransfer(l1WithdrawReceiver, amount);

            emit WithdrawalFinalizedSharedBridge(_chainId, l1WithdrawReceiver, l1WethAddress, amount);
            if (_chainId == eraChainId) {
                emit WithdrawalFinalized(l1WithdrawReceiver, l1WethAddress, amount);
            }
        } else {
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), l1WithdrawReceiver, amount, 0, 0, 0, 0)
            }
            require(callSuccess, "L1WethBridge: withdraw failed");
            emit EthWithdrawalFinalized(_chainId, l1WithdrawReceiver, amount);
        }

        isWithdrawalFinalized[_chainId][_l2BatchNumber][_l2MessageIndex] = true;
    }

    /// @dev check that the withdrawal is valid
    function _checkWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) internal view returns (address l1Receiver, uint256 amount, bool wrapToWeth) {
        (l1Receiver, amount, wrapToWeth) = _parseL2WithdrawalMessage(_chainId, _message);

        L2Message memory l2ToL1Message;
        {
            bool thisIsBaseTokenBridge = bridgehub.baseTokenBridge(_chainId) == address(this);
            address l2Sender = thisIsBaseTokenBridge ? L2_ETH_TOKEN_SYSTEM_CONTRACT_ADDR : l2BridgeAddress[_chainId];

            // Check that the specified message was actually sent while withdrawing eth from L2.
            l2ToL1Message = L2Message({txNumberInBatch: _l2TxNumberInBatch, sender: l2Sender, data: _message});
        }

        {
            bool success = bridgehub.proveL2MessageInclusion(
                _chainId,
                _l2BatchNumber,
                _l2MessageIndex,
                l2ToL1Message,
                _merkleProof
            );
            require(success, "vq");
        }
    }

    /// @dev Decode the ETH withdraw message with additional data about WETH withdrawal that came from L2EthToken
    /// contract
    function _parseL2WithdrawalMessage(
        uint256 _chainId,
        bytes memory _message
    ) internal view returns (address l1Receiver, uint256 ethAmount, bool wrapToWeth) {
        // We check that the message is long enough to read the data.
        // Please note that there are two versions of the message:
        // 1. The message that is sent by `withdraw(address _l1Receiver)`
        // It should be equal to the length of the bytes4 function signature + address l1Receiver + uint256 amount = 4 + 20 + 32 = 56 (bytes).
        // 2. The message that is sent by `withdrawWithMessage(address _l1Receiver, bytes calldata _additionalData)`
        // It should be equal to the length of the following:
        // bytes4 function signature + address l1Receiver + uint256 amount + address l2Sender + bytes _additionalData =
        // = 4 + 20 + 32 + 32 + _additionalData.length >= 68 (bytes).

        // So the data is expected to be at least 56 bytes long.
        require(_message.length >= 56, "Incorrect ETH message with additional data length");

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_message, 0);

        if (bytes4(functionSignature) == IMailbox.finalizeEthWithdrawal.selector) {
            (l1Receiver, offset) = UnsafeBytes.readAddress(_message, offset);
            (ethAmount, offset) = UnsafeBytes.readUint256(_message, offset);
            wrapToWeth = false;

            if (l1Receiver == address(this)) {
                wrapToWeth = true;

                // Check that the message length is correct.
                // additionalData (WETH withdrawal data): l2 sender address + weth receiver address = 20 + 20 = 40 (bytes)
                // It should be equal to the length of the function signature + eth receiver address + uint256 amount +
                // additionalData = 4 + 20 + 32 + 40 = 96 (bytes).
                require(_message.length == 96, "Incorrect ETH message with additional data length 2");

                address l2Sender;
                (l2Sender, offset) = UnsafeBytes.readAddress(_message, offset);
                require(l2Sender == l2BridgeAddress[_chainId], "The withdrawal was not initiated by L2 bridge");

                // Parse additional data
                (l1Receiver, offset) = UnsafeBytes.readAddress(_message, offset);
            }
        } else if (bytes4(functionSignature) == IL1BridgeDeprecated.finalizeWithdrawal.selector) {
            // this message is a token withdrawal

            // Check that the message length is correct.
            // It should be equal to the length of the function signature + address + address + uint256 = 4 + 20 + 20 + 32 =
            // 76 (bytes).
            require(_message.length == 76, "Incorrect ETH withdrawal message length");
            (l1Receiver, offset) = UnsafeBytes.readAddress(_message, offset);
            address l1Token;
            (l1Token, offset) = UnsafeBytes.readAddress(_message, offset);
            (ethAmount, offset) = UnsafeBytes.readUint256(_message, offset);
        } else {
            revert("Incorrect message function selector");
        }
    }

    /// @return l2Token Address of an L2 token counterpart.
    function l2TokenAddress(address _l1Token) public view override returns (address l2Token) {
        l2Token = _l1Token == l1WethAddress ? l2WethStandardAddressEthIsBase : address(0);
    }

    /// @dev The receive function is called when ETH is sent directly to the contract.
    receive() external payable {
        // Expected to receive ether in two cases:
        // 1. l1 WETH sends ether on `withdraw`
        require(msg.sender == l1WethAddress, "pn");
        emit EthReceived(msg.value);
    }

    /// @dev returns address of proxyAdmin
    function readProxyAdmin() public view returns (address) {
        address proxyAdmin;
        assembly {
            /// @dev proxy admin storage slot
            proxyAdmin := sload(0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103)
        }
        return proxyAdmin;
    }
}
