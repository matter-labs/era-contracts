// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

error Unauthorized(address caller);
error EmptyDeposit();
error ValueMismatch(uint256 expected, uint256 actual);
error WithdrawalAlreadyFinalized();
error ZeroAddress();
error SharedBridgeValueAlreadySet(SharedBridgeKey);
error NoFundsTransferred();
error ZeroBalance();
error NonEmptyMsgValue();
error L2BridgeNotDeployed(uint256 chainId);
error TokenNotSupported(address token);
error WithdrawIncorrectAmount();
error DepositExists();
error AddressAlreadyUsed(address addr);
error InvalidProof();
error DepositDNE();
error InsufficientFunds();
error DepositFailed();
error ShareadBridgeValueNotSet(SharedBridgeKey);
error WithdrawFailed();
error MalformedMessage();
error InvalidSelector(bytes4 func);
error STMAlreadyRegistered();
error STMNotRegistered();
error TokenAlreadyRegistered(address token);
error TokenNotRegistered(address token);
error InvalidChainId();
error WethBridgeNotSet();
error BridgeHubAlreadyRegistered();
error AddressTooLow(address);
error SlotOccupied();
error MalformedBytecode(BytecodeError);
error OperationShouldBeReady();
error OperationShouldBePending();
error OperationExists();
error InvalidDelay();
error PreviousOperationNotExecuted();
error HashMismatch(bytes32 expected, bytes32 actual);
error HyperchainLimitReached();
error TimeNotReached();
error TooMuchGas();
error MalformedCalldata();
error FacetIsFrozen(bytes4 func);
error PubdataBatchIsLessThanTxn();
error InvalidPubdataPricingMode();
error InvalidValue();
error ChainAlreadyLive();
error InvalidProtocolVersion();
error DiamondFreezeIncorrectState();

enum SharedBridgeKey {
    PostUpgradeFirstBatch,
    LegacyBridgeFirstBatch,
    LegacyBridgeLastDepositBatch,
    LegacyBridgeLastDepositTxn
}

enum BytecodeError {
    Version,
    NumberOfWords,
    Length,
    WordsMustBeOdd
}
