// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IL1ERC20Bridge} from "./interfaces/IL1ERC20Bridge.sol";
import {IL1SharedBridge} from "./interfaces/IL1SharedBridge.sol";
import {IL2Bridge} from "./interfaces/IL2Bridge.sol";
import {IL2BridgeLegacy} from "./interfaces/IL2BridgeLegacy.sol";
import {IL1AssetHandler} from "./interfaces/IL1AssetHandler.sol";
import {IL1NativeTokenVault} from "./interfaces/IL1NativeTokenVault.sol";

import {IMailbox} from "../state-transition/chain-interfaces/IMailbox.sol";
import {L2Message, TxStatus} from "../common/Messaging.sol";
import {UnsafeBytes} from "../common/libraries/UnsafeBytes.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS, TWO_BRIDGES_MAGIC_VALUE, ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {IBridgehub, L2TransactionRequestTwoBridgesInner, L2TransactionRequestDirect} from "../bridgehub/IBridgehub.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "../common/L2ContractAddresses.sol";

import {BridgeHelper} from "./BridgeHelper.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Bridges assets between L1 and ZK chain, supporting both ETH and ERC20 tokens.
/// @dev Designed for use with a proxy for upgradability.
contract L1SharedBridge is IL1SharedBridge, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev The address of the WETH token on L1.
    address public immutable override L1_WETH_TOKEN;

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @dev Era's chainID
    uint256 internal immutable ERA_CHAIN_ID;

    /// @dev The address of ZKsync Era diamond proxy contract.
    address internal immutable ERA_DIAMOND_PROXY;

    /// @dev Stores the first batch number on the ZKsync Era Diamond Proxy that was settled after Diamond proxy upgrade.
    /// This variable is used to differentiate between pre-upgrade and post-upgrade Eth withdrawals. Withdrawals from batches older
    /// than this value are considered to have been finalized prior to the upgrade and handled separately.
    uint256 internal eraPostDiamondUpgradeFirstBatch;

    /// @dev Stores the first batch number on the ZKsync Era Diamond Proxy that was settled after L1ERC20 Bridge upgrade.
    /// This variable is used to differentiate between pre-upgrade and post-upgrade ERC20 withdrawals. Withdrawals from batches older
    /// than this value are considered to have been finalized prior to the upgrade and handled separately.
    uint256 internal eraPostLegacyBridgeUpgradeFirstBatch;

    /// @dev Stores the ZKsync Era batch number that processes the last deposit tx initiated by the legacy bridge
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

    /// @dev A mapping chainId => L2 deposit transaction hash => dataHash
    // keccak256(abi.encode(account, tokenAddress, amount)) for legacy transfers
    // keccak256(abi.encode(_prevMsgSender, assetId, transferData)) for new transfers
    /// @dev Tracks deposit transactions to L2 to enable users to claim their funds if a deposit fails.
    mapping(uint256 chainId => mapping(bytes32 l2DepositTxHash => bytes32 depositDataHash))
        public
        override depositHappened;

    /// @dev Tracks the processing status of L2 to L1 messages, indicating whether a message has already been finalized.
    mapping(uint256 chainId => mapping(uint256 l2BatchNumber => mapping(uint256 l2ToL1MessageNumber => bool isFinalized)))
        public isWithdrawalFinalized;

    /// @notice Deprecated. Kept for backwards compatibility.
    /// @dev Indicates whether the hyperbridging is enabled for a given chain.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 chainId => bool enabled) public hyperbridgingEnabled;

    /// @dev Maps token balances for each chain to prevent unauthorized spending across ZK chain.
    /// This serves as a security measure until hyperbridging is implemented.
    /// NOTE: this function may be removed in the future, don't rely on it!
    mapping(uint256 chainId => mapping(address l1Token => uint256 balance)) public chainBalance;

    /// @dev A mapping assetId => assetHandlerAddress
    /// @dev Tracks the address of Asset Handler contracts, where bridged funds are locked for each asset
    /// @dev P.S. this liquidity was locked directly in SharedBridge before
    mapping(bytes32 assetId => address assetHandlerAddress) public assetHandlerAddress;

    /// @dev A mapping assetId => the asset deployment tracker address
    /// @dev Tracks the address of Deployment Tracker contract on L1, which sets Asset Handlers on L2s (ZK chain)
    /// @dev for the asset and stores respective addresses
    mapping(bytes32 assetId => address assetDeploymentTracker) public assetDeploymentTracker;

    /// @dev Address of native token vault
    IL1NativeTokenVault public nativeTokenVault;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyBridgehub() {
        require(msg.sender == address(BRIDGE_HUB), "ShB not BH");
        _;
    }

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyThis() {
        require(msg.sender == address(this), "ShB: only self");
        _;
    }

    /// @notice Checks that the message sender is the bridgehub or ZKsync Era Diamond Proxy.
    modifier onlyBridgehubOrEra(uint256 _chainId) {
        require(
            msg.sender == address(BRIDGE_HUB) || (_chainId == ERA_CHAIN_ID && msg.sender == ERA_DIAMOND_PROXY),
            "L1SharedBridge: msg.sender not equal to bridgehub or era chain"
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
    /// @dev Used for testing purposes only, as the contract has been initialized on mainnet
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

    /// @dev transfer token to shared bridge as part of upgrade
    function transferTokenToNTV(address _token) external {
        require(msg.sender == address(nativeTokenVault), "ShB: not NTV");
        if (ETH_TOKEN_ADDRESS == _token) {
            address ntvAddress = address(nativeTokenVault);
            uint256 amount = address(this).balance;
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), ntvAddress, amount, 0, 0, 0, 0)
            }
            require(callSuccess, "ShB: eth transfer failed");
        } else {
            IERC20(_token).safeTransfer(address(nativeTokenVault), IERC20(_token).balanceOf(address(this)));
        }
    }

    /// @dev transfer balance to native token vault as part of upgrade
    function transferBalanceToNTV(uint256 _chainId, address _token) external {
        require(msg.sender == address(nativeTokenVault), "ShB: not NTV");
        chainBalance[_chainId][_token] = 0;
    }

    /// @dev Sets the L1ERC20Bridge contract address. Should be called only once.
    function setL1Erc20Bridge(address _legacyBridge) external onlyOwner {
        require(address(legacyBridge) == address(0), "ShB: legacy bridge already set");
        require(_legacyBridge != address(0), "ShB: legacy bridge 0");
        legacyBridge = IL1ERC20Bridge(_legacyBridge);
    }

    /// @dev Sets the nativeTokenVault contract address. Should be called only once.
    function setNativeTokenVault(IL1NativeTokenVault _nativeTokenVault) external onlyOwner {
        require(address(nativeTokenVault) == address(0), "ShB: native token vault already set");
        require(address(_nativeTokenVault) != address(0), "ShB: native token vault 0");
        nativeTokenVault = _nativeTokenVault;
    }

    /// @dev Initializes the l2Bridge address by governance for a specific chain.
    function initializeChainGovernance(uint256 _chainId, address _l2BridgeAddress) external onlyOwner {
        l2BridgeAddress[_chainId] = _l2BridgeAddress;
    }

    /// @notice Sets the asset handler address for a specified asset ID on the chain of the asset deployment tracker.
    /// @dev The caller of this function is encoded within the `assetId`, therefore, it should be invoked by the asset deployment tracker contract.
    /// @dev Typically, for most tokens, ADT is the native token vault. However, custom tokens may have their own specific asset deployment trackers.
    /// @dev `setAssetHandlerAddressOnCounterPart` should be called on L1 to set asset handlers on L2 chains for a specific asset ID.
    /// @param _additionalData The asset data which may include the asset address and any additional required data or encodings.
    /// @param _assetHandlerAddress The address of the asset handler to be set for the provided asset.
    function setAssetHandlerAddressInitial(bytes32 _additionalData, address _assetHandlerAddress) external {
        address sender = msg.sender == address(nativeTokenVault) ? NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS : msg.sender;
        bytes32 assetId = DataEncoding.encodeAssetId(_additionalData, sender);
        assetHandlerAddress[assetId] = _assetHandlerAddress;
        assetDeploymentTracker[assetId] = msg.sender;
        emit AssetHandlerRegisteredInitial(assetId, _assetHandlerAddress, _additionalData, sender);
    }

    /// @dev Used to set the assetHandlerAddress for a given assetId on chains different from the assetDeploymentTrackers chain.
    /// @dev This function should typically be called by the respective asset deployment tracker, or alternatively by the owner.
    function setAssetHandlerAddressOnCounterPart(
        uint256 _chainId,
        uint256 _mintValue,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient,
        bytes32 _assetId,
        address _assetAddressOnCounterPart
    ) external payable returns (bytes32 l2TxHash) {
        require(msg.sender == assetDeploymentTracker[_assetId] || msg.sender == owner(), "ShB: only ADT or owner");
        require(l2BridgeAddress[_chainId] != address(0), "ShB: chain governance not initialized");

        bytes memory l2Calldata = abi.encodeCall(
            IL2Bridge.setAssetHandlerAddress,
            (_assetId, _assetAddressOnCounterPart)
        );

        L2TransactionRequestDirect memory request = L2TransactionRequestDirect({
            chainId: _chainId,
            l2Contract: l2BridgeAddress[_chainId],
            mintValue: _mintValue, // l2 gas + l2 msg.Value the bridgehub will withdraw the mintValue from the base token bridge for gas
            l2Value: 0, // For base token deposits, there is no msg.value during the call, as the base token is minted to the recipient address
            l2Calldata: l2Calldata,
            l2GasLimit: _l2TxGasLimit,
            l2GasPerPubdataByteLimit: _l2TxGasPerPubdataByte,
            factoryDeps: new bytes[](0),
            refundRecipient: _refundRecipient
        });
        l2TxHash = BRIDGE_HUB.requestL2TransactionDirect{value: msg.value}(request);
    }

    /// @notice Allows bridgehub to acquire mintValue for L1->L2 transactions.
    /// @dev If the corresponding L2 transaction fails, refunds are issued to a refund recipient on L2.
    /// @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _assetId The deposited asset ID.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _amount The total amount of tokens to be bridged.
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _prevMsgSender,
        uint256 _amount
    ) external payable virtual onlyBridgehubOrEra(_chainId) whenNotPaused {
        (address l1AssetHandler, bytes32 assetId) = _getAssetProperties(_assetId);
        _transferAllowanceToNTV(assetId, _amount, _prevMsgSender);
        // slither-disable-next-line unused-return
        IL1AssetHandler(l1AssetHandler).bridgeBurn{value: msg.value}({
            _chainId: _chainId,
            _l2Value: 0,
            _assetId: assetId,
            _prevMsgSender: _prevMsgSender,
            _data: abi.encode(_amount, address(0))
        });

        // Note that we don't save the deposited amount, as this is for the base token, which gets sent to the refundRecipient if the tx fails
        emit BridgehubDepositBaseTokenInitiated(_chainId, _prevMsgSender, _assetId, _amount);
    }

    /// @notice Returns the address of asset handler and parsed assetId, if padded token address was passed
    /// @dev For backwards compatibility we pad the l1Token to become a bytes32 assetId.
    /// @dev We deal with this case here. We also register the asset.
    /// @param _assetId bytes32 encoding of asset Id or padded address of the token
    function _getAssetProperties(bytes32 _assetId) internal returns (address l1AssetHandler, bytes32 assetId) {
        // Check if the passed id is the address and assume NTV for the case
        assetId = uint256(_assetId) <= type(uint160).max ? DataEncoding.encodeNTVAssetId(_assetId) : _assetId;
        l1AssetHandler = assetHandlerAddress[_assetId];
        // Check if no asset handler is set
        if (l1AssetHandler == address(0)) {
            require(uint256(_assetId) <= type(uint160).max, "ShB: only address can be registered");
            l1AssetHandler = address(nativeTokenVault);
            nativeTokenVault.registerToken(address(uint160(uint256(_assetId))));
        }
    }

    /// @notice Decodes the transfer input for legacy data and transfers allowance to NTV
    /// @dev Is not applicable for custom asset handlers
    /// @param _data encoded transfer data (address _l1Token, uint256 _depositAmount, address _l2Receiver)
    /// @param _prevMsgSender address of the deposit initiator
    function handleLegacyData(
        bytes calldata _data,
        address _prevMsgSender
    ) external onlyThis returns (bytes32, bytes memory) {
        (address _l1Token, uint256 _depositAmount, address _l2Receiver) = abi.decode(
            _data,
            (address, uint256, address)
        );
        bytes32 assetId = _ensureTokenRegisteredWithNTV(_l1Token);
        _transferAllowanceToNTV(assetId, _depositAmount, _prevMsgSender);
        return (assetId, abi.encode(_depositAmount, _l2Receiver));
    }

    function _ensureTokenRegisteredWithNTV(address _l1Token) internal returns (bytes32 assetId) {
        assetId = DataEncoding.encodeNTVAssetId(_l1Token);
        if (nativeTokenVault.tokenAddress(assetId) == address(0)) {
            nativeTokenVault.registerToken(_l1Token);
        }
    }

    /// @notice Transfers allowance to Native Token Vault, if the asset is registered with it. Does nothing for ETH or non-registered tokens.
    /// @dev assetId is not the padded address, but the correct encoded id (NTV stores respective format for IDs)
    function _transferAllowanceToNTV(bytes32 _assetId, uint256 _amount, address _prevMsgSender) internal {
        address l1TokenAddress = nativeTokenVault.tokenAddress(_assetId);
        if (l1TokenAddress == address(0) || l1TokenAddress == ETH_TOKEN_ADDRESS) {
            return;
        }
        IERC20 l1Token = IERC20(l1TokenAddress);

        // Do the transfer if allowance to Shared bridge is bigger than amount
        // And if there is not enough allowance for the NTV
        if (
            l1Token.allowance(_prevMsgSender, address(this)) >= _amount &&
            l1Token.allowance(_prevMsgSender, address(nativeTokenVault)) < _amount
        ) {
            // slither-disable-next-line arbitrary-send-erc20
            l1Token.safeTransferFrom(_prevMsgSender, address(this), _amount);
            l1Token.forceApprove(address(nativeTokenVault), _amount);
        }
    }

    /// @notice Initiates a deposit transaction within Bridgehub, used by `requestL2TransactionTwoBridges`.
    /// @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _l2Value The L2 `msg.value` from the L1 -> L2 deposit transaction.
    /// @param _data The calldata for the second bridge deposit.
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
        bytes32 assetId;
        bytes memory transferData;
        bool legacyDeposit = false;
        try this.handleLegacyData(_data, _prevMsgSender) returns (
            bytes32 assetIdDecoded,
            bytes memory transferDataDecoded
        ) {
            (assetId, transferData) = (assetIdDecoded, transferDataDecoded);
            legacyDeposit = true;
        } catch {
            (assetId, transferData) = abi.decode(_data, (bytes32, bytes));
        }

        require(BRIDGE_HUB.baseTokenAssetId(_chainId) != assetId, "ShB: baseToken deposit not supported");

        bytes memory bridgeMintCalldata = _burn({
            _chainId: _chainId,
            _l2Value: _l2Value,
            _assetId: assetId,
            _prevMsgSender: _prevMsgSender,
            _transferData: transferData,
            _passValue: true
        });
        bytes32 txDataHash = this.encodeTxDataHash(legacyDeposit, _prevMsgSender, assetId, transferData);

        request = _requestToBridge({
            _chainId: _chainId,
            _prevMsgSender: _prevMsgSender,
            _assetId: assetId,
            _bridgeMintCalldata: bridgeMintCalldata,
            _txDataHash: txDataHash
        });

        emit BridgehubDepositInitiated({
            chainId: _chainId,
            txDataHash: txDataHash,
            from: _prevMsgSender,
            assetId: assetId,
            bridgeMintCalldata: bridgeMintCalldata
        });
    }

    /// @dev Encodes the transaction data hash using either the latest encoding standard or the legacy standard.
    /// @param _isLegacyEncoding Boolean flag indicating whether to use the legacy encoding standard (true) or the latest encoding standard (false).
    /// @param _prevMsgSender The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _transferData The encoded transfer data, which includes both the deposit amount and the address of the L2 receiver.
    /// @return txDataHash The resulting encoded transaction data hash.
    function encodeTxDataHash(
        bool _isLegacyEncoding,
        address _prevMsgSender,
        bytes32 _assetId,
        bytes memory _transferData
    ) external view returns (bytes32 txDataHash) {
        if (_isLegacyEncoding) {
            (uint256 depositAmount, ) = abi.decode(_transferData, (uint256, address));
            txDataHash = keccak256(abi.encode(_prevMsgSender, nativeTokenVault.tokenAddress(_assetId), depositAmount));
        } else {
            txDataHash = keccak256(abi.encode(_prevMsgSender, _assetId, _transferData));
        }
    }

    /// @dev send the burn message to the asset
    /// @notice Forwards the burn request for specific asset to respective asset handler
    /// @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _l2Value The L2 `msg.value` from the L1 -> L2 deposit transaction.
    /// @param _assetId The deposited asset ID.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _transferData The encoded data, which is used by the asset handler to determine L2 recipient and amount. Might include extra information.
    /// @param _passValue Boolean indicating whether to pass msg.value in the call.
    /// @return bridgeMintCalldata The calldata used by remote asset handler to mint tokens for recipient.
    function _burn(
        uint256 _chainId,
        uint256 _l2Value,
        bytes32 _assetId,
        address _prevMsgSender,
        bytes memory _transferData,
        bool _passValue
    ) internal returns (bytes memory bridgeMintCalldata) {
        address l1AssetHandler = assetHandlerAddress[_assetId];
        require(l1AssetHandler != address(0), "ShB: asset handler does not exist for assetId");
        uint256 msgValue = _passValue ? msg.value : 0;
        bridgeMintCalldata = IL1AssetHandler(l1AssetHandler).bridgeBurn{value: msgValue}({
            _chainId: _chainId,
            _l2Value: _l2Value,
            _assetId: _assetId,
            _prevMsgSender: _prevMsgSender,
            _data: _transferData
        });
    }

    /// @dev The request data that is passed to the bridgehub
    function _requestToBridge(
        uint256 _chainId,
        address _prevMsgSender,
        bytes32 _assetId,
        bytes memory _bridgeMintCalldata,
        bytes32 _txDataHash
    ) internal view returns (L2TransactionRequestTwoBridgesInner memory request) {
        // Request the finalization of the deposit on the L2 side
        bytes memory l2TxCalldata = _getDepositL2Calldata(_prevMsgSender, _assetId, _bridgeMintCalldata);

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
    /// @param _chainId The chain ID of the ZK chain to which confirm the deposit.
    /// @param _txDataHash The keccak256 hash of abi.encode(msgSender, l1Token, amount)
    /// @param _txHash The hash of the L1->L2 transaction to confirm the deposit.
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
    function _getDepositL2Calldata(
        address _l1Sender,
        bytes32 _assetId,
        bytes memory _assetData
    ) internal view returns (bytes memory) {
        // First branch covers the case when asset is not registered with NTV (custom asset handler)
        // Second branch handles tokens registered with NTV and uses legacy calldata encoding
        if (nativeTokenVault.tokenAddress(_assetId) == address(0)) {
            return abi.encodeCall(IL2Bridge.finalizeDeposit, (_assetId, _assetData));
        } else {
            // slither-disable-next-line unused-return
            (uint256 _amount, , address _l2Receiver, bytes memory _gettersData, address _parsedL1Token) = DataEncoding
                .decodeBridgeMintData(_assetData);
            return
                abi.encodeCall(
                    IL2BridgeLegacy.finalizeDeposit,
                    (_l1Sender, _l2Receiver, _parsedL1Token, _amount, _gettersData)
                );
        }
    }

    /// @dev Withdraw funds from the initiated deposit, that failed when finalizing on L2.
    /// @param _depositSender The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _assetData The encoded transfer data, which includes both the deposit amount and the address of the L2 receiver.
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization.
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed.
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent.
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization.
    /// @dev Processes claims of failed deposit, whether they originated from the legacy bridge or the current system.
    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        address _depositSender,
        bytes32 _assetId,
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
            // Determine if the given dataHash matches the calculated legacy transaction hash.
            bool isLegacyTxDataHash = _isLegacyTxDataHash(_depositSender, _assetId, _assetData, dataHash);
            // If the dataHash matches the legacy transaction hash, skip the next step.
            // Otherwise, perform the check using the new transaction data hash encoding.
            if (!isLegacyTxDataHash) {
                bytes32 txDataHash = this.encodeTxDataHash(false, _depositSender, _assetId, _assetData);
                require(dataHash == txDataHash, "ShB: d.it not hap");
            }
        }
        delete depositHappened[_chainId][_l2TxHash];

        IL1AssetHandler(assetHandlerAddress[_assetId]).bridgeRecoverFailedTransfer(
            _chainId,
            _assetId,
            _depositSender,
            _assetData
        );

        emit ClaimedFailedDepositSharedBridge(_chainId, _depositSender, _assetId, _assetData);
    }

    /// @dev Determines if an eth withdrawal was initiated on ZKsync Era before the upgrade to the Shared Bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number for the withdrawal.
    /// @return Whether withdrawal was initiated on ZKsync Era before diamond proxy upgrade.
    function _isEraLegacyEthWithdrawal(uint256 _chainId, uint256 _l2BatchNumber) internal view returns (bool) {
        require((_chainId != ERA_CHAIN_ID) || eraPostDiamondUpgradeFirstBatch != 0, "ShB: diamondUFB not set for Era");
        return (_chainId == ERA_CHAIN_ID) && (_l2BatchNumber < eraPostDiamondUpgradeFirstBatch);
    }

    /// @dev Determines if a token withdrawal was initiated on ZKsync Era before the upgrade to the Shared Bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number for the withdrawal.
    /// @return Whether withdrawal was initiated on ZKsync Era before Legacy Bridge upgrade.
    function _isEraLegacyTokenWithdrawal(uint256 _chainId, uint256 _l2BatchNumber) internal view returns (bool) {
        require(
            (_chainId != ERA_CHAIN_ID) || eraPostLegacyBridgeUpgradeFirstBatch != 0,
            "ShB: LegacyUFB not set for Era"
        );
        return (_chainId == ERA_CHAIN_ID) && (_l2BatchNumber < eraPostLegacyBridgeUpgradeFirstBatch);
    }

    /// @dev Determines if the provided data for a failed deposit corresponds to a legacy failed deposit.
    /// @param _prevMsgSender The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _transferData The encoded transfer data, which includes both the deposit amount and the address of the L2 receiver.
    /// @param _expectedTxDataHash The nullifier data hash stored for the failed deposit.
    /// @return isLegacyTxDataHash True if the transaction is legacy, false otherwise.
    function _isLegacyTxDataHash(
        address _prevMsgSender,
        bytes32 _assetId,
        bytes memory _transferData,
        bytes32 _expectedTxDataHash
    ) internal view returns (bool isLegacyTxDataHash) {
        try this.encodeTxDataHash(true, _prevMsgSender, _assetId, _transferData) returns (bytes32 txDataHash) {
            return txDataHash == _expectedTxDataHash;
        } catch {
            return false;
        }
    }

    /// @dev Determines if a deposit was initiated on zkSync Era before the upgrade to the Shared Bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number for the deposit where it was processed.
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the deposit was processed.
    /// @return Whether deposit was initiated on ZKsync Era before Shared Bridge upgrade.
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
                (_l2TxNumberInBatch <= eraLegacyBridgeLastDepositTxNumber &&
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
    ) internal nonReentrant whenNotPaused returns (address l1Receiver, bytes32 assetId, uint256 amount) {
        require(!isWithdrawalFinalized[_chainId][_l2BatchNumber][_l2MessageIndex], "Withdrawal is already finalized");
        isWithdrawalFinalized[_chainId][_l2BatchNumber][_l2MessageIndex] = true;

        // Handling special case for withdrawal from ZKsync Era initiated before Shared Bridge.
        require(!_isEraLegacyEthWithdrawal(_chainId, _l2BatchNumber), "ShB: legacy eth withdrawal");
        require(!_isEraLegacyTokenWithdrawal(_chainId, _l2BatchNumber), "ShB: legacy token withdrawal");
        bytes memory transferData;
        {
            MessageParams memory messageParams = MessageParams({
                l2BatchNumber: _l2BatchNumber,
                l2MessageIndex: _l2MessageIndex,
                l2TxNumberInBatch: _l2TxNumberInBatch
            });
            (assetId, transferData) = _checkWithdrawal(_chainId, messageParams, _message, _merkleProof);
        }
        address l1AssetHandler = assetHandlerAddress[assetId];
        // slither-disable-next-line unused-return
        IL1AssetHandler(l1AssetHandler).bridgeMint(_chainId, assetId, transferData);
        (amount, l1Receiver) = abi.decode(transferData, (uint256, address));

        emit WithdrawalFinalizedSharedBridge(_chainId, l1Receiver, assetId, amount);
    }

    /// @dev Verifies the validity of a withdrawal message from L2 and returns details of the withdrawal.
    function _checkWithdrawal(
        uint256 _chainId,
        MessageParams memory _messageParams,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) internal view returns (bytes32 assetId, bytes memory transferData) {
        (assetId, transferData) = _parseL2WithdrawalMessage(_chainId, _message);
        L2Message memory l2ToL1Message;
        {
            bool baseTokenWithdrawal = (assetId == BRIDGE_HUB.baseTokenAssetId(_chainId));
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
    ) internal view returns (bytes32 assetId, bytes memory transferData) {
        // We check that the message is long enough to read the data.
        // Please note that there are three versions of the message:
        // 1. The message that is sent by `withdraw(address _l1Receiver)` or `withdrawWithMessage`. In the second case, this function ignores the extra data
        // It should be equal to the length of the bytes4 function signature + address l1Receiver + uint256 amount = 4 + 20 + 32 = 56 (bytes).
        // 2. The legacy `getL1WithdrawMessage`, the length of the data is known.
        // 3. The message that is encoded by `getL1WithdrawMessage(bytes32 _assetId, bytes memory _bridgeMintData)`
        // No length is assumed. The assetId is decoded and the mintData is passed to respective assetHandler

        uint256 amount;
        address l1Receiver;
        // uint256 l1ReceiverBytes;
        // address parsedL1Receiver;

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        if (bytes4(functionSignature) == IMailbox.finalizeEthWithdrawal.selector) {
            // The data is expected to be at least 56 bytes long.
            require(_l2ToL1message.length >= 56, "ShB wrong msg len"); // wrong message length
            // this message is a base token withdrawal
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            (amount, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset);
            assetId = BRIDGE_HUB.baseTokenAssetId(_chainId);
            transferData = abi.encode(amount, l1Receiver);
        } else if (bytes4(functionSignature) == IL1ERC20Bridge.finalizeWithdrawal.selector) {
            // We use the IL1ERC20Bridge for backward compatibility with old withdrawals.
            address l1Token;
            // this message is a token withdrawal

            // Check that the message length is correct.
            // It should be equal to the length of the function signature + address + address + uint256 = 4 + 20 + 20 + 32 =
            // 76 (bytes).
            require(_l2ToL1message.length == 76, "ShB wrong msg len 2");
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            (l1Token, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            (amount, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset);

            assetId = DataEncoding.encodeNTVAssetId(l1Token);
            transferData = abi.encode(amount, l1Receiver);
        } else if (bytes4(functionSignature) == this.finalizeWithdrawal.selector) {
            // The data is expected to be at least 36 bytes long to contain assetId.
            require(_l2ToL1message.length >= 36, "ShB wrong msg len"); // wrong message length
            (assetId, offset) = UnsafeBytes.readBytes32(_l2ToL1message, offset);
            transferData = UnsafeBytes.readRemainingBytes(_l2ToL1message, offset);
        } else {
            revert("ShB Incorrect message function selector");
        }
    }

    /// @dev Receives and parses (name, symbol, decimals) from the token contract
    function getERC20Getters(address _token) public view returns (bytes memory) {
        return BridgeHelper.getERC20Getters(_token, ETH_TOKEN_ADDRESS);
    }

    /*//////////////////////////////////////////////////////////////
            SHARED BRIDGE TOKEN BRIDGING LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw funds from the initiated deposit, that failed when finalizing on L2
    /// @dev Cannot be used to claim deposits made with new encoding
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
        bytes32 assetId = DataEncoding.encodeNTVAssetId(_l1Asset);
        // For legacy deposits, the l2 receiver is not required to check tx data hash
        bytes memory transferData = abi.encode(_amount, address(0));
        bridgeRecoverFailedTransfer({
            _chainId: _chainId,
            _depositSender: _depositSender,
            _assetId: assetId,
            _assetData: transferData,
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
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
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
    /// @return l2TxHash The L2 transaction hash of deposit finalization.
    function depositLegacyErc20Bridge(
        address _prevMsgSender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) external payable override onlyLegacyBridge nonReentrant whenNotPaused returns (bytes32 l2TxHash) {
        require(l2BridgeAddress[ERA_CHAIN_ID] != address(0), "ShB b. n dep");
        require(_l1Token != L1_WETH_TOKEN, "ShB: WETH deposit not supported 2");

        bytes32 _assetId;
        bytes memory bridgeMintCalldata;

        {
            // Inner call to encode data to decrease local var numbers
            _assetId = _ensureTokenRegisteredWithNTV(_l1Token);
            IERC20(_l1Token).forceApprove(address(nativeTokenVault), _amount);
        }

        {
            bridgeMintCalldata = _burn({
                _chainId: ERA_CHAIN_ID,
                _l2Value: 0,
                _assetId: _assetId,
                _prevMsgSender: _prevMsgSender,
                _transferData: abi.encode(_amount, _l2Receiver),
                _passValue: false
            });
        }

        {
            bytes memory l2TxCalldata = _getDepositL2Calldata(_prevMsgSender, _assetId, bridgeMintCalldata);

            // If the refund recipient is not specified, the refund will be sent to the sender of the transaction.
            // Otherwise, the refund will be sent to the specified address.
            // If the recipient is a contract on L1, the address alias will be applied.
            address refundRecipient = AddressAliasHelper.actualRefundRecipient(_refundRecipient, _prevMsgSender);

            L2TransactionRequestDirect memory request = L2TransactionRequestDirect({
                chainId: ERA_CHAIN_ID,
                l2Contract: l2BridgeAddress[ERA_CHAIN_ID],
                mintValue: msg.value, // l2 gas + l2 msg.Value the bridgehub will withdraw the mintValue from the shared bridge (base token bridge) for gas
                l2Value: 0, // L2 msg.value, this contract doesn't support base token deposits or wrapping functionality, for direct deposits use bridgehub
                l2Calldata: l2TxCalldata,
                l2GasLimit: _l2TxGasLimit,
                l2GasPerPubdataByteLimit: _l2TxGasPerPubdataByte,
                factoryDeps: new bytes[](0),
                refundRecipient: refundRecipient
            });
            l2TxHash = BRIDGE_HUB.requestL2TransactionDirect{value: msg.value}(request);
        }

        // Save the deposited amount to claim funds on L1 if the deposit failed on L2
        depositHappened[ERA_CHAIN_ID][l2TxHash] = keccak256(abi.encode(_prevMsgSender, _l1Token, _amount));

        emit LegacyDepositInitiated({
            chainId: ERA_CHAIN_ID,
            l2DepositTxHash: l2TxHash,
            from: _prevMsgSender,
            to: _l2Receiver,
            l1Asset: _l1Token,
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
        bytes32 assetId;
        (l1Receiver, assetId, amount) = _finalizeWithdrawal({
            _chainId: ERA_CHAIN_ID,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _message: _message,
            _merkleProof: _merkleProof
        });
        l1Asset = nativeTokenVault.tokenAddress(assetId);
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
