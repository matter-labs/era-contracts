// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IL1WethBridge.sol";
import "./interfaces/IWETH9.sol";

import "../zksync/interfaces/IMailbox.sol";
import "../common/interfaces/IAllowList.sol";
import "../common/AllowListed.sol";
import "../common/libraries/UnsafeBytes.sol";
import "../common/ReentrancyGuard.sol";
import "../common/L2ContractHelper.sol";
import "../zksync/Storage.sol";
import "../zksync/Config.sol";

contract L1WethBridge is IL1WethBridge, AllowListed, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev The address of the WETH token on L1
    address public immutable l1WethAddress;

    /// @dev The smart contract that manages the list with permission to call contract functions
    IAllowList immutable allowList;

    /// @dev zkSync smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication
    IMailbox immutable zkSyncMailbox;

    /// @dev The address of the WETH proxy on L2
    address public l2ProxyWethAddress;

    /// @dev The L2 gas limit for requesting L1 -> L2 transaction of deploying L2 bridge instance
    /// NOTE: this constant will be accurately calculated in the future.
    uint256 constant DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT = $(PRIORITY_TX_MAX_GAS_LIMIT);

    /// @dev The default l2GasPricePerPubdata to be used in bridges.
    uint256 constant DEFAULT_L2_GAS_PRICE_PER_PUBDATA = $(DEFAULT_L2_GAS_PRICE_PER_PUBDATA);

    /// @dev A mapping L2 block number => message number => flag
    /// @dev Used to indicate that zkSync L2 -> L1 WETH message was already processed
    mapping(uint256 => mapping(uint256 => bool)) public isWethWithdrawalFinalized;

    /// @dev The address of deployed L2 WETH bridge counterpart
    address public l2WethBridge;

    // /// @dev The address of the factory that deploys proxy for L2 WETH tokens
    // address public l2WethFactory;

    // TODO: Should we remove L1 token address?
    /// @dev A mapping account => L1 token address => L2 deposit transaction hash => amount
    /// @dev Used for saving the number of deposited funds, to claim them in case the deposit transaction will fail
    mapping(address => mapping(address => mapping(bytes32 => uint256))) depositAmount;

    // TODO: Should we remove L1 token address?
    /// @dev The accumulated deposited amount per user.
    /// @dev A mapping L1 token address => user address => the total deposited amount by the user
    mapping(address => mapping(address => uint256)) public totalDepositedAmountPerUser;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(
        address _l1WethAddress,
        IMailbox _mailbox,
        IAllowList _allowList
    ) reentrancyGuardInitializer {
        l1WethAddress = _l1WethAddress;
        zkSyncMailbox = _mailbox;
        allowList = _allowList;
    }

    /// @dev Initializes a contract bridge for later use. Expected to be used in the proxy
    /// @dev During initialization deploys L2 WETH bridge counterpart as well as provides some factory deps for it
    /// @param _factoryDeps A list of raw bytecodes that are needed for deployment of the L2 WETH bridge
    /// @notice _factoryDeps[0] == a raw bytecode of L2 WETH bridge implementation
    /// @notice _factoryDeps[1] == a raw bytecode of proxy that is used as L2 WETH bridge
    /// @param _l2ProxyWethAddress Pre-calculated address of L2 WETH token beacon proxy
    /// @param _governor Address which can change L2 WETH token implementation and upgrade the bridge
    function initialize(
        bytes[] calldata _factoryDeps,
        address _l2ProxyWethAddress,
        address _governor
    ) external reentrancyGuardInitializer {
        require(_l2ProxyWethAddress != address(0), "nf");
        require(_governor != address(0), "nh");
        // We are expecting to see the exact three bytecodes that are needed to initialize the bridge
        require(_factoryDeps.length == 3, "mk");
        l2ProxyWethAddress = _l2ProxyWethAddress;

        bytes32 l2WethBridgeImplementationBytecodeHash = L2ContractHelper.hashL2Bytecode(_factoryDeps[0]);
        bytes32 l2WethBridgeProxyBytecodeHash = L2ContractHelper.hashL2Bytecode(_factoryDeps[1]);

        // Deploy L2 bridge implementation contract
        address wethBridgeImplementationAddr = _requestDeployTransaction(
            l2WethBridgeImplementationBytecodeHash,
            "", // Empty constructor data
            _factoryDeps // All factory deps are needed for L2 bridge
        );

        // Prepare the proxy constructor data
        bytes memory l2WethBridgeProxyConstructorData;
        {
            // Data to be used in delegate call to initialize the proxy
            bytes memory proxyInitializationParams = abi.encodeCall(
                IL2Bridge.initialize,
                (address(this), l1WethAddress, L2_ETH_TOKEN_ADDRESS, _governor)
            );
            l2WethBridgeProxyConstructorData = abi.encode(wethBridgeImplementationAddr, _governor, proxyInitializationParams);
        }

        // Deploy L2 bridge proxy contract
        l2WethBridge = _requestDeployTransaction(
            l2WethBridgeProxyBytecodeHash,
            l2WethBridgeProxyConstructorData,
            new bytes[](0) // No factory deps are needed for L2 bridge proxy, because it is already passed in previous step
        );
    }

    /// @notice Requests L2 transaction that will deploy a contract with a given bytecode hash and constructor data.
    /// NOTE: it is always use deploy via create2 with ZERO salt
    /// @param _bytecodeHash The hash of the bytecode of the contract to be deployed
    /// @param _constructorData The data to be passed to the contract constructor
    /// @param _factoryDeps A list of raw bytecodes that are needed for deployment
    function _requestDeployTransaction(
        bytes32 _bytecodeHash,
        bytes memory _constructorData,
        bytes[] memory _factoryDeps
    ) internal returns (address deployedAddress) {
        bytes memory deployCalldata = abi.encodeCall(
            IContractDeployer.create2,
            (bytes32(0), _bytecodeHash, _constructorData)
        );
        zkSyncMailbox.requestL2Transaction(
            DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
            0,
            deployCalldata,
            DEPLOY_L2_BRIDGE_COUNTERPART_GAS_LIMIT,
            DEFAULT_L2_GAS_PRICE_PER_PUBDATA,
            _factoryDeps,
            msg.sender
        );

        deployedAddress = L2ContractHelper.computeCreate2Address(
            // Apply the alias to the address of the bridge contract, to get the `msg.sender` in L2.
            AddressAliasHelper.applyL1ToL2Alias(address(this)),
            bytes32(0), // Zero salt
            _bytecodeHash,
            keccak256(_constructorData)
        );
    }

    function deposit(
        address _l2Receiver,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte
    ) external payable nonReentrant senderCanCallFunction(allowList) returns (bytes32 txHash) {
        require(_amount != 0, "Empty deposit amount");
        require(_l2Receiver != address(0), "L2 receiver address is zero");

        // Deposit WETH tokens from the depositor address to the smart contract address
        uint256 depositedAmount = _transferWethFunds(msg.sender, address(this), _amount);
        require(depositedAmount == _amount, "Incorrect amount of funds deposited");
        // verify the deposit amount is allowed
        _verifyWethDepositLimit(msg.sender, _amount, false);

        // Unwrap WETH tokens (smart contract address receives the equivalent amount of ETH)
        IWETH9(l1WethAddress).withdraw(_amount);

        // Request the finalization of the deposit on the L2 side
        bytes memory l2TxCalldata = _getDepositL2Calldata(msg.sender, _l2Receiver);
        txHash = zkSyncMailbox.requestL2Transaction{value: msg.value}(
            l2WethBridge,
            _amount,
            l2TxCalldata,
            _l2TxGasLimit,
            _l2TxGasPerPubdataByte,
            new bytes[](0),
            msg.sender
        );

        // Save the deposited amount to claim funds on L1 if the deposit failed on L2
        depositAmount[msg.sender][l1WethAddress][txHash] = amount;

        emit DepositInitiated(msg.sender, _l2Receiver, l1WethAddress, amount);
    }

    /// @dev Transfers WETH tokens from the depositor to the receiver address
    /// @return The difference between the receiver balance before and after the transferring funds
    function _transferWethFunds(
        address _from,
        address _to,
        uint256 _amount
    ) internal returns (uint256) {
        IWETH9 l1Weth = IWETH9(l1WethAddress);

        uint256 balanceBefore = l1Weth.balanceOf(_to);
        l1Weth.transferFrom(_from, _to, _amount);
        uint256 balanceAfter = l1Weth.balanceOf(_to);

        return balanceAfter - balanceBefore;
    }

    /// @dev Verify the WETH deposit limit is reached to its cap or not
    function _verifyWethDepositLimit(
        address _depositor,
        uint256 _amount,
        bool _claiming
    ) internal {
        IAllowList.Deposit memory limitData = IAllowList(allowList).getTokenDepositLimitData(l1WethAddress);
        if (!limitData.depositLimitation) return; // no deposit limitation is placed for this token

        if (_claiming) {
            totalDepositedAmountPerUser[l1WethAddress][_depositor] -= _amount;
        } else {
            require(totalDepositedAmountPerUser[l1WethAddress][_depositor] + _amount <= limitData.depositCap, "Deposit cap reached");
            totalDepositedAmountPerUser[l1WethAddress][_depositor] += _amount;
        }
    }

    /// @dev Generate a calldata for calling the deposit finalization on the L2 WETH bridge contract
    function _getDepositL2Calldata(
        address _l1Sender,
        address _l2Receiver
    ) internal view returns (bytes memory txCalldata) {
        txCalldata = abi.encodeCall(
            IL2Bridge.finalizeDeposit,
            (_l1Sender, _l2Receiver)
        );
    }

    /// @notice Finalize the WETH withdrawal and release funds
    /// @param _l2BlockNumber The L2 block number where the WETH withdrawal was processed
    /// @param _l2MessageIndexes The position in the L2 logs Merkle tree of the l2Logs that were sent with the ETH and WETH withdrawal messages, respectively
    /// @param _l2TxNumberInBlock The L2 transaction number in a block, in which the ETH and WETH withdrawal logs were sent
    /// @param _messages The L2 ETH and WETH withdraw data, stored in an L2 -> L1 messages
    /// @param _merkleProofs The Merkle proofs of the inclusion L2 -> L1 messages about ETH and WETH withdrawal initializations
    function finalizeWithdrawal(
        uint256 _l2BlockNumber,
        uint256[2] _l2MessageIndexes,
        uint16 _l2TxNumberInBlock,
        bytes[2] calldata _messages,
        bytes32[2][] calldata _merkleProofs
    ) external nonReentrant senderCanCallFunction(allowList) {
        require(!isWethWithdrawalFinalized[_l2BlockNumber][_l2MessageIndexes[1]], "WETH withdrawal is already finalized");

        L2Message memory l2ToL1EthMessage = L2Message({
            txNumberInBlock: _l2TxNumberInBlock,
            sender: L2_ETH_TOKEN_ADDRESS,
            data: _messages[0]
        });

        bool ethMessageProofValid = zkSyncMailbox.proveL2MessageInclusion(_l2BlockNumber, _l2MessageIndexes[0], l2ToL1EthMessage, _merkleProofs[0]);
        require(ethMessageProofValid, "ETH L2 -> L1 message inclusion proof is invalid"); // Failed to verify that ETH withdrawal was actually initialized on L2

        L2Message memory l2ToL1WethMessage = L2Message({
            txNumberInBlock: _l2TxNumberInBlock,
            sender: l2WethBridge,
            data: _messages[1]
        });

        bool wethMessageProofValid = zkSyncMailbox.proveL2MessageInclusion(_l2BlockNumber, _l2MessageIndexes[1], l2ToL1WethMessage, _merkleProofs[1]);
        require(wethMessageProofValid, "WETH L2 -> L1 message inclusion proof is invalid"); // Failed to verify that WETH withdrawal was actually initialized on L2

        (address _l1EthWithdrawReceiver, uint256 _ethAmount) = _parseL2EthWithdrawalMessage(_messages[0]);
        require(_l1EthWithdrawReceiver == address(this), "Wrong L1 ETH withdraw receiver");

        (address _l1WethWithdrawReceiver, uint256 _wethAmount) = _parseL2WethWithdrawalMessage(_messages[1]);
        require(_l1WethWithdrawReceiver != address(0), "L1 WETH withdraw receiver is zero address");

        require(_ethAmount == _wethAmount, "Unequal ETH and WETH amounts in the L2 -> L1 messages");

        // Widthdraw ETH to smart contract address
        zkSyncMailbox.finalizeEthWithdrawal(
            _l2BlockNumber,
            _l2MessageIndexes[0],
            _l2TxNumberInBlock,
            _messages[0],
            _merkleProofs[0]
        );

        // Wrap ETH to WETH tokens (smart contract address receives the equivalent amount of WETH)
        IWETH9(l1WethAddress).deposit{value: _ethAmount}();

        // Transfer WETH tokens from the smart contract address to the withdrawal receiver
        uint256 withdrawnAmount = _transferWethFunds(address(this), _l1WethWithdrawReceiver, _wethAmount);

        isWethWithdrawalFinalized[_l2BlockNumber][_l2MessageIndexes[1]] = true;

        emit WithdrawalFinalized(_l1WethWithdrawReceiver, l1WethAddress, _wethAmount);
    }

    /// @dev Decode the ETH withdraw message that came from L2EthToken contract
    function _parseL2EthWithdrawalMessage(bytes memory _message)
        internal
        pure
        returns (address l1Receiver, uint256 amount)
    {
        // Check that the message length is correct.
        // It should be equal to the length of the function signature + address + uint256 = 4 + 20 + 32 = 56 (bytes).
        require(_message.length == 56);

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_message, 0);
        require(bytes4(functionSignature) == zkSyncMailbox.finalizeEthWithdrawal.selector);

        (l1Receiver, offset) = UnsafeBytes.readAddress(_message, offset);
        (amount, offset) = UnsafeBytes.readUint256(_message, offset);
    }

    /// @dev Decode the WETH withdraw message that came from L2WethBridge contract
    function _parseL2WethWithdrawalMessage(bytes memory _message)
        internal
        pure
        returns (address l1WethReceiver, uint256 amount)
    {
        // Check that the message length is correct.
        // It should be equal to the length of the function signature + L2 sender address + L1 receiver address + uint256 = 4 + 20 + 20 + 32 = 76 (bytes).
        require(_message.length == 72);

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_message, 0);
        require(bytes4(functionSignature) == this.finalizeWithdrawal.selector);

        (l2WethSender, offset) = UnsafeBytes.readAddress(_message, offset);
        (l1WethReceiver, offset) = UnsafeBytes.readAddress(_message, offset);
        (amount, offset) = UnsafeBytes.readUint256(_message, offset);
    }
}