// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IL1ERC20Bridge} from "./interfaces/IL1ERC20Bridge.sol";
import {IL1SharedBridge} from "./interfaces/IL1SharedBridge.sol";
import {IL2Bridge} from "./interfaces/IL2Bridge.sol";
import {IL1StandardAsset} from "./interfaces/IL1StandardAsset.sol";
import {IL1NativeTokenVault} from "./interfaces/IL1NativeTokenVault.sol";

import {IMailbox} from "../state-transition/chain-interfaces/IMailbox.sol";
import {L2Message, TxStatus} from "../common/Messaging.sol";
import {UnsafeBytes} from "../common/libraries/UnsafeBytes.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS, TWO_BRIDGES_MAGIC_VALUE, ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {IBridgehub, L2TransactionRequestTwoBridgesInner, L2TransactionRequestDirect} from "../bridgehub/IBridgehub.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "../common/L2ContractAddresses.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Bridges assets between L1 and hyperchains, supporting both ETH and ERC20 tokens.
/// @dev Designed for use with a proxy for upgradability.
contract L1SharedBridge is IL1SharedBridge, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev The address of the WETH token on L1.
    address public immutable override L1_WETH_TOKEN;

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @dev Era's chainID
    uint256 public immutable ERA_CHAIN_ID;

    /// @dev The address of zkSync Era diamond proxy contract.
    address public immutable ERA_DIAMOND_PROXY;

    /// @dev Stores the first batch number on the zkSync Era Diamond Proxy that was settled after Diamond proxy upgrade.
    /// This variable is used to differentiate between pre-upgrade and post-upgrade Eth withdrawals. Withdrawals from batches older
    /// than this value are considered to have been finalized prior to the upgrade and handled separately.
    uint256 internal eraPostDiamondUpgradeFirstBatch;

    /// @dev Stores the first batch number on the zkSync Era Diamond Proxy that was settled after L1ERC20 Bridge upgrade.
    /// This variable is used to differentiate between pre-upgrade and post-upgrade ERC20 withdrawals. Withdrawals from batches older
    /// than this value are considered to have been finalized prior to the upgrade and handled separately.
    uint256 internal eraPostLegacyBridgeUpgradeFirstBatch;

    /// @dev Stores the zkSync Era batch number that processes the last deposit tx initiated by the legacy bridge
    /// This variable (together with eraLegacyBridgeLastDepositTxNumber) is used to differentiate between pre-upgrade and post-upgrade deposits. Deposits processed in older batches
    /// than this value are considered to have been processed prior to the upgrade and handled separately.
    /// We use this both for Eth and erc20 token deposits, so we need to update the diamond and bridge simultaneously.
    uint256 internal eraLegacyBridgeLastDepositBatch;

    /// @dev The tx number in the _eraLegacyBridgeLastDepositBatch of the last deposit tx initiated by the legacy bridge
    /// This variable (together with eraLegacyBridgeLastDepositBatch) is used to differentiate between pre-upgrade and post-upgrade deposits. Deposits processed in older txs
    /// than this value are considered to have been processed prior to the upgrade and handled separately.
    /// We use this both for Eth and erc20 token deposits, so we need to update the diamond and bridge simultaneously.
    uint256 internal eraLegacyBridgeLastDepositTxNumber;

    /// @dev Legacy bridge smart contract that used to hold ERC20 tokens.
    IL1ERC20Bridge public override legacyBridge;

    /// @dev A mapping chainId => bridgeProxy. Used to store the bridge proxy's address, and to see if it has been deployed yet.
    mapping(uint256 chainId => address l2Bridge) public override l2BridgeAddress;

    /// @dev A mapping chainId => L2 deposit transaction hash => keccak256(abi.encode(account, tokenAddress, amount))
    /// @dev Tracks deposit transactions from L2 to enable users to claim their funds if a deposit fails.
    mapping(uint256 chainId => mapping(bytes32 l2DepositTxHash => bytes32 depositDataHash))
        public
        override depositHappened;

    /// @dev Tracks the processing status of L2 to L1 messages, indicating whether a message has already been finalized.
    mapping(uint256 chainId => mapping(uint256 l2BatchNumber => mapping(uint256 l2ToL1MessageNumber => bool isFinalized)))
        public isWithdrawalFinalized;

    /// @dev Indicates whether the hyperbridging is enabled for a given chain.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 chainId => bool enabled) public hyperbridgingEnabled;

    /// @dev A mapping assetInfo => assetAddress
    mapping(bytes32 _assetInfo => address _assetAddress) public assetAddress;

    /// @dev Address of native token vault
    IL1NativeTokenVault public nativeTokenVault;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyBridgehub() {
        require(msg.sender == address(BRIDGE_HUB), "ShB not BH");
        _;
    }

    /// @notice Checks that the message sender is the bridgehub or zkSync Era Diamond Proxy.
    modifier onlyBridgehubOrEra(uint256 _chainId) {
        require(
            msg.sender == address(BRIDGE_HUB) || (_chainId == ERA_CHAIN_ID && msg.sender == ERA_DIAMOND_PROXY),
            "L1SharedBridge: msg.value not equal to amounnot bridgehub or era chain"
        );
        _;
    }

    /// @notice Checks that the message sender is the legacy bridge.
    modifier onlyLegacyBridge() {
        require(msg.sender == address(legacyBridge), "ShB not legacy bridge");
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(
        address _l1WethAddress,
        IBridgehub _bridgehub,
        uint256 _eraChainId,
        address _eraDiamondProxy
    ) reentrancyGuardInitializer {
        _disableInitializers();
        L1_WETH_TOKEN = _l1WethAddress;
        BRIDGE_HUB = _bridgehub;
        ERA_CHAIN_ID = _eraChainId;
        ERA_DIAMOND_PROXY = _eraDiamondProxy;
    }

    /// @dev Initializes a contract bridge for later use. Expected to be used in the proxy
    /// @param _owner Address which can change L2 token implementation and upgrade the bridge
    /// implementation. The owner is the Governor and separate from the ProxyAdmin from now on, so that the Governor can call the bridge.
    function initialize(
        address _owner,
        uint256 _eraPostDiamondUpgradeFirstBatch,
        uint256 _eraPostLegacyBridgeUpgradeFirstBatch,
        uint256 _eraLegacyBridgeLastDepositBatch,
        uint256 _eraLegacyBridgeLastDepositTxNumber
    ) external reentrancyGuardInitializer initializer {
        require(_owner != address(0), "ShB owner 0");
        _transferOwnership(_owner);
        if (eraPostDiamondUpgradeFirstBatch == 0) {
            eraPostDiamondUpgradeFirstBatch = _eraPostDiamondUpgradeFirstBatch;
            eraPostLegacyBridgeUpgradeFirstBatch = _eraPostLegacyBridgeUpgradeFirstBatch;
            eraLegacyBridgeLastDepositBatch = _eraLegacyBridgeLastDepositBatch;
            eraLegacyBridgeLastDepositTxNumber = _eraLegacyBridgeLastDepositTxNumber;
        }
    }

    // /// @dev This sets the first post diamond upgrade batch for era, used to check old eth withdrawals
    // /// @param _eraPostDiamondUpgradeFirstBatch The first batch number on the zkSync Era Diamond Proxy that was settled after diamond proxy upgrade.
    // function setEraPostDiamondUpgradeFirstBatch(uint256 _eraPostDiamondUpgradeFirstBatch) external onlyOwner {
    //     require(eraPostDiamondUpgradeFirstBatch == 0, "ShB: eFPUB already set");
    //     eraPostDiamondUpgradeFirstBatch = _eraPostDiamondUpgradeFirstBatch;
    // }

    // /// @dev This sets the first post upgrade batch for era, used to check old token withdrawals
    // /// @param _eraPostLegacyBridgeUpgradeFirstBatch The first batch number on the zkSync Era Diamond Proxy that was settled after legacy bridge upgrade.
    // function setEraPostLegacyBridgeUpgradeFirstBatch(uint256 _eraPostLegacyBridgeUpgradeFirstBatch) external onlyOwner {
    //     require(eraPostLegacyBridgeUpgradeFirstBatch == 0, "ShB: eFPUB already set");
    //     eraPostLegacyBridgeUpgradeFirstBatch = _eraPostLegacyBridgeUpgradeFirstBatch;
    // }

    // /// @dev This sets the first post upgrade batch for era, used to check old withdrawals
    // /// @param  _eraLegacyBridgeLastDepositBatch The the zkSync Era batch number that processes the last deposit tx initiated by the legacy bridge
    // /// @param _eraLegacyBridgeLastDepositTxNumber The tx number in the _eraLegacyBridgeLastDepositBatch of the last deposit tx initiated by the legacy bridge
    // function setEraLegacyBridgeLastDepositTime(
    //     uint256 _eraLegacyBridgeLastDepositBatch,
    //     uint256 _eraLegacyBridgeLastDepositTxNumber
    // ) external onlyOwner {
    //     require(eraLegacyBridgeLastDepositBatch == 0, "ShB: eLOBDB already set");
    //     require(eraLegacyBridgeLastDepositTxNumber == 0, "ShB: eLOBDTN already set");
    //     eraLegacyBridgeLastDepositBatch = _eraLegacyBridgeLastDepositBatch;
    //     eraLegacyBridgeLastDepositTxNumber = _eraLegacyBridgeLastDepositTxNumber;
    // }

    /// @dev Sets the L1ERC20Bridge contract address. Should be called only once.
    function setL1Erc20Bridge(address _legacyBridge) external onlyOwner {
        require(address(legacyBridge) == address(0), "ShB: legacy bridge already set");
        require(_legacyBridge != address(0), "ShB: legacy bridge 0");
        legacyBridge = IL1ERC20Bridge(_legacyBridge);
    }

    /// @dev Sets the L1ERC20Bridge contract address. Should be called only once.
    function setNativeTokenVault(IL1NativeTokenVault _nativeTokenVault) external onlyOwner {
        require(address(nativeTokenVault) == address(0), "ShB: legacy bridge already set");
        require(address(_nativeTokenVault) != address(0), "ShB: legacy bridge 0");
        nativeTokenVault = _nativeTokenVault;
    }

    /// @dev Initializes the l2Bridge address by governance for a specific chain.
    function initializeChainGovernance(uint256 _chainId, address _l2BridgeAddress) external onlyOwner {
        l2BridgeAddress[_chainId] = _l2BridgeAddress;
    }

    /// @dev Used to set the assedAddress for a given assetInfo.
    function setAssetAddress(bytes32 _additionalData, address _assetAddress) external {
        address sender = msg.sender == address(nativeTokenVault) ? NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS : msg.sender;
        bytes32 assetInfo = keccak256(abi.encode(uint256(block.chainid), sender, _additionalData)); /// todo make other asse
        assetAddress[assetInfo] = _assetAddress;
        emit AssetRegistered(assetInfo, _assetAddress, _additionalData, sender);
    }

    /// @notice Allows bridgehub to acquire mintValue for L1->L2 transactions.
    /// @dev If the corresponding L2 transaction fails, refunds are issued to a refund recipient on L2.
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetInfo,
        address _prevMsgSender,
        uint256 _amount
    ) external payable virtual onlyBridgehubOrEra(_chainId) whenNotPaused {
        (address l1Asset, bytes32 assetInfo) = _getAssetProperties(_assetInfo);
        bytes memory bridgeMintData = IL1StandardAsset(l1Asset).bridgeBurn{value: msg.value}({
            _chainId: _chainId,
            _mintValue: 0,
            _assetInfo: assetInfo,
            _prevMsgSender: _prevMsgSender,
            _data: abi.encode(_amount, address(0))
        });

        // Note that we don't save the deposited amount, as this is for the base token, which gets sent to the refundRecipient if the tx fails
        emit BridgehubDepositBaseTokenInitiated(_chainId, _prevMsgSender, _assetInfo, _amount);
        // We could use this data instead of the above
        emit BridgehubMintData(bridgeMintData);
    }

    /// @dev for backwards compatibility and to automatically register l1 assets, and we return the correct info.
    function _getAssetProperties(bytes32 _assetInfo) internal returns (address l1Asset, bytes32 assetInfo) {
        l1Asset = assetAddress[_assetInfo];
        assetInfo = _assetInfo;
        if (l1Asset == address(0) && (uint256(_assetInfo) <= type(uint160).max)) {
            l1Asset = address(nativeTokenVault);
            assetInfo = keccak256(abi.encode(block.chainid, NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS, _assetInfo));
            nativeTokenVault.registerToken(address(uint160(uint256(_assetInfo))));
        }
    }

    function decodeLegacyData(bytes calldata _data, address _prevMsgSender) external returns (bytes32, bytes memory) {
        require (msg.sender == address(this));
        (address _l1Token, uint256 _depositAmount, address _l2Receiver) = abi.decode(
            _data,
            (address, uint256, address)
        );
        bytes32 assetInfo = nativeTokenVault.getAssetInfo(_l1Token);
        if (nativeTokenVault.tokenAddress(assetInfo) == address(0)) {
            nativeTokenVault.registerToken(_l1Token);
        }
        _transferAllowanceToNTV(assetInfo, _depositAmount, _prevMsgSender);
        return (assetInfo, abi.encode(_depositAmount, _l2Receiver));
    }

    function _transferAllowanceToNTV(bytes32 _assetInfo, uint256 _amount, address _prevMsgSender) internal {
        // assetInfo might be padded token address, or it might be asset info (get token from NTV)
        // do the transfer if allowance is bigger than amount
        address asset = assetAddress[_assetInfo];
        address l1TokenAddress = nativeTokenVault.tokenAddress(_assetInfo);
        if (asset == address(0) && (uint256(_assetInfo) <= type(uint160).max)) {
            l1TokenAddress = address(uint160(uint256(_assetInfo)));
        } else if (l1TokenAddress == address(0) || l1TokenAddress == ETH_TOKEN_ADDRESS) {
            return;
        }
        IERC20 l1Token = IERC20(l1TokenAddress);

        if (l1Token.allowance(_prevMsgSender, address(this)) >= _amount) {
            l1Token.safeTransferFrom(_prevMsgSender, address(this), _amount);
            l1Token.safeIncreaseAllowance(address(nativeTokenVault), _amount);
        }
    }

    /// @notice Initiates a deposit transaction within Bridgehub, used by `requestL2TransactionTwoBridges`.
    function bridgehubDeposit(
        uint256 _chainId,
        address _prevMsgSender,
        uint256 _l2Value,
        bytes calldata _data
    )
        external
        payable
        override
        onlyBridgehub
        whenNotPaused
        returns (L2TransactionRequestTwoBridgesInner memory request)
    {
        require(l2BridgeAddress[_chainId] != address(0), "ShB l2 bridge not deployed");
        bytes32 _assetInfo;
        bytes memory _assetData;
        try this.decodeLegacyData(_data, _prevMsgSender) returns (
            bytes32 _assetInfoCatch,
            bytes memory _assetDataCatch
        ) {
            (_assetInfo, _assetData) = (_assetInfoCatch, _assetDataCatch);
        } catch {
            (_assetInfo, _assetData) = abi.decode(_data, (bytes32, bytes));
        }

        require(BRIDGE_HUB.baseToken(_chainId) != assetAddress[_assetInfo], "ShB: baseToken deposit not supported");

        (bytes memory bridgeMintCalldata, bytes32 assetInfo) = _burn({
            _chainId: _chainId,
            _l2Value: _l2Value,
            _assetInfo: _assetInfo,
            _prevMsgSender: _prevMsgSender,
            _assetData: _assetData
        });

        bytes32 txDataHash = keccak256(abi.encode(_prevMsgSender, assetInfo, _assetData));
        request = _requestToBridge({
            _chainId: _chainId,
            _assetInfo: assetInfo,
            _bridgeMintCalldata: bridgeMintCalldata,
            _txDataHash: txDataHash
        });

        emit BridgehubDepositInitiated({
            chainId: _chainId,
            txDataHash: txDataHash,
            from: _prevMsgSender,
            assetInfo: assetInfo,
            bridgeMintCalldataHash: keccak256(bridgeMintCalldata)
        });
    }

    /// @dev send the burn message to the asset
    function _burn(
        uint256 _chainId,
        uint256 _l2Value,
        bytes32 _assetInfo,
        address _prevMsgSender,
        bytes memory _assetData
    ) internal returns (bytes memory bridgeMintCalldata, bytes32 assetInfo) {
        address l1Asset;
        (l1Asset, assetInfo) = _getAssetProperties(_assetInfo);
        bridgeMintCalldata = IL1StandardAsset(l1Asset).bridgeBurn{value: msg.value}({
            _chainId: _chainId,
            _mintValue: _l2Value,
            _assetInfo: assetInfo,
            _prevMsgSender: _prevMsgSender,
            _data: _assetData
        });
    }

    /// @dev The request data that is passed to the bridgehub
    function _requestToBridge(
        uint256 _chainId,
        bytes32 _assetInfo,
        bytes memory _bridgeMintCalldata,
        bytes32 _txDataHash
    ) internal view returns (L2TransactionRequestTwoBridgesInner memory request) {
        // Request the finalization of the deposit on the L2 side
        bytes memory l2TxCalldata = _getDepositL2Calldata(_assetInfo, _bridgeMintCalldata);

        request = L2TransactionRequestTwoBridgesInner({
            magicValue: TWO_BRIDGES_MAGIC_VALUE,
            l2Contract: l2BridgeAddress[_chainId],
            l2Calldata: l2TxCalldata,
            factoryDeps: new bytes[](0),
            txDataHash: _txDataHash
        });
    }

    /// @notice Confirms the acceptance of a transaction by the Mailbox, as part of the L2 transaction process within Bridgehub.
    /// This function is utilized by `requestL2TransactionTwoBridges` to validate the execution of a transaction.
    function bridgehubConfirmL2Transaction(
        uint256 _chainId,
        bytes32 _txDataHash,
        bytes32 _txHash
    ) external override onlyBridgehub whenNotPaused {
        require(depositHappened[_chainId][_txHash] == 0x00, "ShB tx hap");
        depositHappened[_chainId][_txHash] = _txDataHash;
        emit BridgehubDepositFinalized(_chainId, _txDataHash, _txHash);
    }

    /// @dev Generate a calldata for calling the deposit finalization on the L2 bridge contract
    function _getDepositL2Calldata(bytes32 _assetInfo, bytes memory _assetData) internal view returns (bytes memory) {
        return abi.encodeCall(IL2Bridge.finalizeDeposit, (_assetInfo, _assetData));
    }

    /// @dev Withdraw funds from the initiated deposit, that failed when finalizing on L2
    /// @param _depositSender The address of the deposit initiator
    /// @param _assetInfo The address of the deposited L1 ERC20 token
    /// @param _assetData The amount of the deposit that failed.
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization
    /// @dev Processes claims of failed deposit, whether they originated from the legacy bridge or the current system.
    function claimFailedBurn(
        uint256 _chainId,
        address _depositSender, // todo is this needed, or should it be part of assetData?
        bytes32 _assetInfo,
        bytes memory _assetData,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) public nonReentrant whenNotPaused {
        {
            bool proofValid = BRIDGE_HUB.proveL1ToL2TransactionStatus({
                _chainId: _chainId,
                _l2TxHash: _l2TxHash,
                _l2BatchNumber: _l2BatchNumber,
                _l2MessageIndex: _l2MessageIndex,
                _l2TxNumberInBatch: _l2TxNumberInBatch,
                _merkleProof: _merkleProof,
                _status: TxStatus.Failure
            });
            require(proofValid, "yn");
        }

        require(!_isEraLegacyDeposit(_chainId, _l2BatchNumber, _l2TxNumberInBatch), "ShB: legacy cFD");
        {
            bytes32 dataHash = depositHappened[_chainId][_l2TxHash];
            bytes32 assetInfo;
            bytes32 txDataHash;
            if (uint256(_assetInfo) <= type(uint160).max) {
                assetInfo = keccak256(abi.encode(block.chainid, NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS, _assetInfo));
                (uint256 _amount, ) = abi.decode(_assetData, (uint256, address));
                txDataHash = keccak256(abi.encode(_depositSender, uint160(uint256(_assetInfo)), _amount));
            } else {
                txDataHash = keccak256(abi.encode(_depositSender, _assetInfo, _assetData));
            }
            require(dataHash == txDataHash, "ShB: d.it not hap");
        }
        delete depositHappened[_chainId][_l2TxHash];

        IL1StandardAsset(assetAddress[_assetInfo]).bridgeClaimFailedBurn(
            _chainId,
            _assetInfo,
            _depositSender,
            _assetData
        );

        emit ClaimedFailedDepositSharedBridge(_chainId, _depositSender, _assetInfo, keccak256(_assetData));
    }

    /// @dev Determines if an eth withdrawal was initiated on zkSync Era before the upgrade to the Shared Bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number for the withdrawal.
    /// @return Whether withdrawal was initiated on zkSync Era before diamond proxy upgrade.
    function _isEraLegacyEthWithdrawal(uint256 _chainId, uint256 _l2BatchNumber) internal view returns (bool) {
        require((_chainId != ERA_CHAIN_ID) || eraPostDiamondUpgradeFirstBatch != 0, "ShB: diamondUFB not set for Era");
        return (_chainId == ERA_CHAIN_ID) && (_l2BatchNumber < eraPostDiamondUpgradeFirstBatch);
    }

    /// @dev Determines if a token withdrawal was initiated on zkSync Era before the upgrade to the Shared Bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number for the withdrawal.
    /// @return Whether withdrawal was initiated on zkSync Era before Legacy Bridge upgrade.
    function _isEraLegacyTokenWithdrawal(uint256 _chainId, uint256 _l2BatchNumber) internal view returns (bool) {
        require(
            (_chainId != ERA_CHAIN_ID) || eraPostLegacyBridgeUpgradeFirstBatch != 0,
            "ShB: LegacyUFB not set for Era"
        );
        return (_chainId == ERA_CHAIN_ID) && (_l2BatchNumber < eraPostLegacyBridgeUpgradeFirstBatch);
    }

    /// @dev Determines if a deposit was initiated on zkSync Era before the upgrade to the Shared Bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number for the deposit where it was processed.
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the deposit was processed.
    /// @return Whether deposit was initiated on zkSync Era before Shared Bridge upgrade.
    function _isEraLegacyDeposit(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2TxNumberInBatch
    ) internal view returns (bool) {
        require(
            (_chainId != ERA_CHAIN_ID) || (eraLegacyBridgeLastDepositBatch != 0),
            "ShB: last deposit time not set for Era"
        );
        return
            (_chainId == ERA_CHAIN_ID) &&
            (_l2BatchNumber < eraLegacyBridgeLastDepositBatch ||
                (_l2TxNumberInBatch < eraLegacyBridgeLastDepositTxNumber &&
                    _l2BatchNumber == eraLegacyBridgeLastDepositBatch));
    }

    /// @notice Finalize the withdrawal and release funds
    /// @param _chainId The chain ID of the transaction to check
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
    ) external override {
        _finalizeWithdrawal({
            _chainId: _chainId,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _message: _message,
            _merkleProof: _merkleProof
        });
    }

    struct MessageParams {
        uint256 l2BatchNumber;
        uint256 l2MessageIndex;
        uint16 l2TxNumberInBatch;
    }

    /// @dev Internal function that handles the logic for finalizing withdrawals,
    /// serving both the current bridge system and the legacy ERC20 bridge.
    function _finalizeWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) internal nonReentrant whenNotPaused returns (bytes32 assetInfo, uint256 amount) {
        require(!isWithdrawalFinalized[_chainId][_l2BatchNumber][_l2MessageIndex], "Withdrawal is already finalized");
        isWithdrawalFinalized[_chainId][_l2BatchNumber][_l2MessageIndex] = true;

        // Handling special case for withdrawal from zkSync Era initiated before Shared Bridge.
        require(!_isEraLegacyEthWithdrawal(_chainId, _l2BatchNumber), "ShB: legacy eth withdrawal");
        require(!_isEraLegacyTokenWithdrawal(_chainId, _l2BatchNumber), "ShB: legacy token withdrawal");
        bytes memory assetData;
        {
            MessageParams memory messageParams = MessageParams({
                l2BatchNumber: _l2BatchNumber,
                l2MessageIndex: _l2MessageIndex,
                l2TxNumberInBatch: _l2TxNumberInBatch
            });
            (assetInfo, assetData) = _checkWithdrawal(_chainId, messageParams, _message, _merkleProof);
        }
        address l1Asset = assetAddress[assetInfo];
        IL1StandardAsset(l1Asset).bridgeMint(_chainId, assetInfo, assetData);

        // emit WithdrawalFinalizedSharedBridge(_chainId, l1Receiver, assetInfo, keccak256(assetData));
    }

    /// @dev Verifies the validity of a withdrawal message from L2 and returns details of the withdrawal.
    function _checkWithdrawal(
        uint256 _chainId,
        MessageParams memory _messageParams,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) internal view returns (bytes32 assetInfo, bytes memory assetData) {
        (assetInfo, assetData) = _parseL2WithdrawalMessage(_chainId, _message);
        L2Message memory l2ToL1Message;
        {
            bool baseTokenWithdrawal = (assetInfo == BRIDGE_HUB.baseTokenAssetInfo(_chainId));
            address l2Sender = baseTokenWithdrawal ? L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR : l2BridgeAddress[_chainId];

            l2ToL1Message = L2Message({
                txNumberInBatch: _messageParams.l2TxNumberInBatch,
                sender: l2Sender,
                data: _message
            });
        }

        bool success = BRIDGE_HUB.proveL2MessageInclusion({
            _chainId: _chainId,
            _batchNumber: _messageParams.l2BatchNumber,
            _index: _messageParams.l2MessageIndex,
            _message: l2ToL1Message,
            _proof: _merkleProof
        });
        require(success, "ShB withd w proof"); // withdrawal wrong proof
    }

    function _parseL2WithdrawalMessage(
        uint256 _chainId,
        bytes memory _l2ToL1message
    ) internal view returns (bytes32 assetInfo, bytes memory assetData) {
        // We check that the message is long enough to read the data.
        // Please note that there are two versions of the message:
        // 1. The message that is sent by `withdraw(address _l1Receiver)`
        // It should be equal to the length of the bytes4 function signature + address l1Receiver + uint256 amount = 4 + 20 + 32 = 56 (bytes).
        // 2. The message that is sent by `withdrawWithMessage(address _l1Receiver, bytes calldata _additionalData)`
        // It should be equal to the length of the following:
        // bytes4 function signature + address l1Receiver + uint256 amount + address l2Sender + bytes _additionalData =
        // = 4 + 20 + 32 + 32 + _additionalData.length >= 68 (bytes).

        // So the data is expected to be at least 56 bytes long.
        require(_l2ToL1message.length >= 56, "ShB wrong msg len"); // wrong message length
        uint256 amount;
        address l1Receiver;

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        if (bytes4(functionSignature) == IMailbox.finalizeEthWithdrawal.selector) {
            // this message is a base token withdrawal
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            (amount, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset);
            assetInfo = nativeTokenVault.getAssetInfo(BRIDGE_HUB.baseToken(_chainId));
            assetData = abi.encode(amount, l1Receiver);
        } else if (bytes4(functionSignature) == IL1ERC20Bridge.finalizeWithdrawal.selector) {
            // We use the IL1ERC20Bridge for backward compatibility with old withdrawals.

            // this message is a token withdrawal

            // Check that the message length is correct.
            // It should be equal to the length of the function signature + address + address + uint256 = 4 + 20 + 20 + 32 =
            // 76 (bytes).
            require(_l2ToL1message.length == 76, "ShB wrong msg len 2");
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            address l1Asset;
            (l1Asset, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            assetInfo = nativeTokenVault.getAssetInfo(l1Asset);
            (amount, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset);
            assetData = abi.encode(amount, l1Receiver);
        } else if (bytes4(functionSignature) == this.finalizeWithdrawal.selector) {
            //todo
        } else {
            revert("ShB Incorrect message function selector");
        }
    }

    /*//////////////////////////////////////////////////////////////
            SHARED BRIDGE TOKEN BRIDGGIN LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Withdraw funds from the initiated deposit, that failed when finalizing on L2
    /// @param _depositSender The address of the deposit initiator
    /// @param _l1Asset The address of the deposited L1 ERC20 token
    /// @param _amount The amount of the deposit that failed.
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization
    function claimFailedDeposit(
        uint256 _chainId,
        address _depositSender,
        address _l1Asset,
        uint256 _amount,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external override {
        bytes32 assetInfo = bytes32(uint256(uint160(_l1Asset)));
        bytes memory assetData = abi.encode(_amount, _depositSender); // todo
        claimFailedBurn({
            _chainId: _chainId,
            _depositSender: _depositSender,
            _assetInfo: assetInfo,
            _assetData: assetData,
            _l2TxHash: _l2TxHash,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _merkleProof: _merkleProof
        });
    }

    /*//////////////////////////////////////////////////////////////
                    ERA ERC20 LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initiates a deposit by locking funds on the contract and sending the request
    /// of processing an L2 transaction where tokens would be minted.
    /// @dev If the token is bridged for the first time, the L2 token contract will be deployed. Note however, that the
    /// newly-deployed token does not support any custom logic, i.e. rebase tokens' functionality is not supported.
    /// @param _l2Receiver The account address that should receive funds on L2
    /// @param _l1Asset The L1 token address which is deposited
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
    /// @return l2TxHash The L2 transaction hash of deposit finalization.
    function depositLegacyErc20Bridge(
        address _prevMsgSender,
        address _l2Receiver,
        address _l1Asset,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) external payable override onlyLegacyBridge nonReentrant whenNotPaused returns (bytes32 l2TxHash) {
        require(l2BridgeAddress[ERA_CHAIN_ID] != address(0), "ShB b. n dep");
        require(_l1Asset != L1_WETH_TOKEN, "ShB: WETH deposit not supported 2");

        // // Note that funds have been transferred to this contract in the legacy ERC20 bridge.
        // if (!hyperbridgingEnabled[ERA_CHAIN_ID]) {
        //     chainBalance[ERA_CHAIN_ID][_l1Asset] += _amount;
        // }

        bytes memory bridgeMintData = abi.encode(_amount);
        bytes memory l2TxCalldata = _getDepositL2Calldata(
            IL1NativeTokenVault(nativeTokenVault).getAssetInfoFromLegacy(_l1Asset),
            bridgeMintData
        );

        {
            // If the refund recipient is not specified, the refund will be sent to the sender of the transaction.
            // Otherwise, the refund will be sent to the specified address.
            // If the recipient is a contract on L1, the address alias will be applied.
            address refundRecipient = AddressAliasHelper.actualRefundRecipient(_refundRecipient, _prevMsgSender);

            L2TransactionRequestDirect memory request = L2TransactionRequestDirect({
                chainId: ERA_CHAIN_ID,
                l2Contract: l2BridgeAddress[ERA_CHAIN_ID],
                mintValue: msg.value, // l2 gas + l2 msg.Value the bridgehub will withdraw the mintValue from the base token bridge for gas
                l2Value: 0, // L2 msg.value, this contract doesn't support base token deposits or wrapping functionality, for direct deposits use bridgehub
                l2Calldata: l2TxCalldata,
                l2GasLimit: _l2TxGasLimit,
                l2GasPerPubdataByteLimit: _l2TxGasPerPubdataByte,
                factoryDeps: new bytes[](0),
                refundRecipient: refundRecipient
            });
            l2TxHash = BRIDGE_HUB.requestL2TransactionDirect{value: msg.value}(request);
        }

        bytes32 txDataHash = keccak256(abi.encode(_prevMsgSender, _l1Asset, _amount));
        // Save the deposited amount to claim funds on L1 if the deposit failed on L2
        depositHappened[ERA_CHAIN_ID][l2TxHash] = txDataHash;

        emit LegacyDepositInitiated({
            chainId: ERA_CHAIN_ID,
            l2DepositTxHash: l2TxHash,
            from: _prevMsgSender,
            to: _l2Receiver,
            l1Asset: _l1Asset,
            amount: _amount
        });
    }

    /// @notice Finalizes the withdrawal for transactions initiated via the legacy ERC20 bridge.
    /// @param _l2BatchNumber The L2 batch number where the withdrawal was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization
    ///
    /// @return l1Receiver The address on L1 that will receive the withdrawn funds
    /// @return l1Asset The address of the L1 token being withdrawn
    /// @return amount The amount of the token being withdrawn
    function finalizeWithdrawalLegacyErc20Bridge(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external override onlyLegacyBridge returns (address l1Receiver, address l1Asset, uint256 amount) {
        bytes32 assetInfo;
        (assetInfo, amount) = _finalizeWithdrawal({
            _chainId: ERA_CHAIN_ID,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _message: _message,
            _merkleProof: _merkleProof
        });
        l1Asset = IL1NativeTokenVault(nativeTokenVault).tokenAddress(assetInfo);
    }

    /// @notice Withdraw funds from the initiated deposit, that failed when finalizing on zkSync Era chain.
    /// This function is specifically designed for maintaining backward-compatibility with legacy `claimFailedDeposit`
    /// method in `L1ERC20Bridge`.
    ///
    /// @param _depositSender The address of the deposit initiator
    /// @param _l1Asset The address of the deposited L1 ERC20 token
    /// @param _amount The amount of the deposit that failed.
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization
    function claimFailedDepositLegacyErc20Bridge(
        address _depositSender,
        address _l1Asset,
        uint256 _amount,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external override onlyLegacyBridge {
        bytes32 assetInfo = nativeTokenVault.getAssetInfoFromLegacy(_l1Asset);
        bytes memory assetData = abi.encode(_amount, _depositSender); //todo
        claimFailedBurn({
            _chainId: ERA_CHAIN_ID,
            _depositSender: _depositSender,
            _assetInfo: assetInfo,
            _assetData: assetData,
            _l2TxHash: _l2TxHash,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _merkleProof: _merkleProof
        });
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses all functions marked with the `whenNotPaused` modifier.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, allowing all functions marked with the `whenNotPaused` modifier to be called again.
    function unpause() external onlyOwner {
        _unpause();
    }
}
