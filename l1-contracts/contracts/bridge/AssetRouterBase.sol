// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IL2BridgeLegacy} from "./interfaces/IL2BridgeLegacy.sol";
import {IAssetRouterBase} from "./interfaces/IAssetRouterBase.sol";
import {IAssetHandler} from "./interfaces/IAssetHandler.sol";
import {INativeTokenVault} from "./interfaces/INativeTokenVault.sol";

import {TWO_BRIDGES_MAGIC_VALUE} from "../common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDRESS, L2_ASSET_ROUTER_ADDR} from "../common/L2ContractAddresses.sol";

import {IBridgehub, L2TransactionRequestTwoBridgesInner, L2TransactionRequestDirect} from "../bridgehub/IBridgehub.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Bridges assets between L1 and ZK chain, supporting both ETH and ERC20 tokens.
/// @dev Designed for use with a proxy for upgradability.
abstract contract AssetRouterBase is IAssetRouterBase, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @dev Base token address.
    address public immutable override BASE_TOKEN_ADDRESS;

    /// @dev Address of native token vault.
    INativeTokenVault public nativeTokenVault;

    /// @dev Maps asset ID to address of corresponding asset handler.
    /// @dev Tracks the address of Asset Handler contracts, where bridged funds are locked for each asset.
    /// @dev P.S. this liquidity was locked directly in SharedBridge before.
    mapping(bytes32 assetId => address assetHandlerAddress) public assetHandlerAddress;

        /// @dev Maps asset ID to the asset deployment tracker address.
    /// @dev Tracks the address of Deployment Tracker contract on L1, which sets Asset Handlers on L2s (ZK chain).
    /// @dev For the asset and stores respective addresses.
    mapping(bytes32 assetId => address assetDeploymentTracker) public assetDeploymentTracker;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyBridgehub() {
        require(msg.sender == address(BRIDGE_HUB), "AR: not BH");
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IBridgehub _bridgehub, address _baseTokenAddress) {
        BRIDGE_HUB = _bridgehub;
        BASE_TOKEN_ADDRESS = _baseTokenAddress;
    }

    /// @notice Sets the L1ERC20Bridge contract address.
    /// @dev Should be called only once by the owner.
    /// @param _nativeTokenVault The address of the native token vault.
    function setNativeTokenVault(INativeTokenVault _nativeTokenVault) external onlyOwner {
        require(address(nativeTokenVault) == address(0), "AR: native token vault already set");
        require(address(_nativeTokenVault) != address(0), "AR: native token vault 0");
        nativeTokenVault = _nativeTokenVault;
    }

    /// @notice Sets the asset handler address for a given asset ID.
    /// @dev No access control on the caller, as msg.sender is encoded in the assetId.
    /// @param _assetData In most cases this parameter is bytes32 encoded token address. However, it can include extra information used by custom asset handlers.
    /// @param _assetHandlerAddress The address of the asset handler, which will hold the token of interest.
    function setAssetHandlerAddressThisChain(bytes32 _assetData, address _assetHandlerAddress) external virtual {
        address sender = msg.sender == address(nativeTokenVault) ? L2_NATIVE_TOKEN_VAULT_ADDRESS : msg.sender;
        bytes32 assetId = keccak256(abi.encode(uint256(block.chainid), sender, _assetData));
        assetHandlerAddress[assetId] = _assetHandlerAddress;
        emit AssetHandlerRegistered(assetId, _assetHandlerAddress, _assetData, sender);
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
    ) public payable virtual override onlyBridgehub whenNotPaused {
        address assetHandler = assetHandlerAddress[_assetId];
        require(l1AssetHandler != address(0), "AR: asset handler not set");

        _transferAllowanceToNTV(_assetId, _amount, _prevMsgSender);
        // slither-disable-next-line unused-return
        IAssetHandler(assetHandler).bridgeBurn{value: msg.value}({
            _chainId: _chainId,
            _msgValue: 0,
            _assetId: _assetId,
            _prevMsgSender: _prevMsgSender,
            _data: abi.encode(_amount, address(0))
        });

        // Note that we don't save the deposited amount, as this is for the base token, which gets sent to the refundRecipient if the tx fails
        emit BridgehubDepositBaseTokenInitiated(_chainId, _prevMsgSender, _assetId, _amount);
    }

    /// @notice Initiates a transfer transaction within Bridgehub, used by `requestL2TransactionTwoBridges`.
    /// @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _value The `msg.value` on the target chain tx.
    /// @param _data The calldata for the second bridge deposit.
    /// @return request The data used by the bridgehub to create L2 transaction request to specific ZK chain.
    function bridgehubDeposit(
        uint256 _chainId,
        address _prevMsgSender,
        uint256 _value,
        bytes calldata _data
    )
        external
        payable
        virtual
        override
        onlyBridgehub
        whenNotPaused
        returns (L2TransactionRequestTwoBridgesInner memory request)
    {
        (bytes32 assetId, bytes memory transferData) = abi.decode(_data[1:], (bytes32, bytes));

        require(BRIDGE_HUB.baseTokenAssetId(_chainId) != assetId, "AR: baseToken deposit not supported");

        bytes memory bridgeMintCalldata = _burn({
            _chainId: _chainId,
            _value: _value,
            _assetId: assetId,
            _prevMsgSender: _prevMsgSender,
            _transferData: transferData
        });
        bytes32 txDataHash = keccak256(bytes.concat(bytes1(0x01), abi.encode(_prevMsgSender, assetId, transferData)));

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

    /// @notice Finalize the withdrawal and release funds.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _assetId The bridged asset ID.
    /// @param _transferData The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    function finalizeDeposit(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _transferData
    ) public virtual override returns (address l1Receiver, uint256 amount) {
        address assetHandler = assetHandlerAddress[_assetId];

        if (assetHandler != address(0)) {
            IAssetHandler(assetHandler).bridgeMint(_chainId, _assetId, _transferData);
        } else {
            IAssetHandler(address(nativeTokenVault)).bridgeMint(_chainId, _assetId, _transferData); // ToDo: Maybe it's better to receive amount and receiver here? transferData may have different encoding
            assetHandlerAddress[_assetId] = address(nativeTokenVault);
        }

        (amount, l1Receiver) = abi.decode(_transferData, (uint256, address));

        emit DepositFinalizedAssetRouter(_chainId, l1Receiver, _assetId, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            Internal Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev The request data that is passed to the bridgehub.
    /// @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _assetId The deposited asset ID.
    /// @param _bridgeMintCalldata The calldata used by remote asset handler to mint tokens for recipient.
    /// @param _txDataHash The keccak256 hash of 0x01 || abi.encode(bytes32, bytes) to identify deposits.
    /// @return request The data used by the bridgehub to create L2 transaction request to specific ZK chain.
    function _requestToBridge(
        // solhint-disable-next-line no-unused-vars
        uint256 _chainId,
        address _prevMsgSender,
        bytes32 _assetId,
        bytes memory _bridgeMintCalldata,
        bytes32 _txDataHash
    ) internal view virtual returns (L2TransactionRequestTwoBridgesInner memory request) {
        bytes memory l2TxCalldata = getDepositL2Calldata(_chainId, _prevMsgSender, _assetId, _bridgeMintCalldata);
        // bytes memory l2TxCalldata = _getDepositL2Calldata(_prevMsgSender, _assetId, _bridgeMintCalldata);

        request = L2TransactionRequestTwoBridgesInner({
            magicValue: TWO_BRIDGES_MAGIC_VALUE,
            l2Contract: L2_ASSET_ROUTER_ADDR,
            l2Calldata: l2TxCalldata,
            factoryDeps: new bytes[](0),
            txDataHash: _txDataHash
        });
    }

    /// @notice Generates a calldata for calling the deposit finalization on the L2 native token contract.
    /// @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _l1Sender The address of the deposit initiator.
    /// @param _assetId The deposited asset ID.
    /// @param _transferData The encoded data, which is used by the asset handler to determine L2 recipient and amount. Might include extra information.
    /// @return Returns calldata used on ZK chain.
    function getDepositL2Calldata(
        uint256 _chainId,
        address _l1Sender,
        bytes32 _assetId,
        bytes memory _transferData
    ) public view override returns (bytes memory) {
        // First branch covers the case when asset is not registered with NTV (custom asset handler)
        // Second branch handles tokens registered with NTV and uses legacy calldata encoding
        if (nativeTokenVault.tokenAddress(_assetId) == address(0)) {
            return abi.encodeCall(IAssetRouterBase.finalizeDeposit, (_chainId, _assetId, _transferData));
            // return abi.encodeCall(IL2Bridge.finalizeDeposit, (_assetId, _assetData));
        } else {
            // slither-disable-next-line unused-return
            (, address _l2Receiver, address _parsedL1Token, uint256 _amount, bytes memory _gettersData) = DataEncoding
                .decodeBridgeMintData(_assetData);
            return
                abi.encodeCall(
                    IL2BridgeLegacy.finalizeDeposit,
                    (_l1Sender, _l2Receiver, _parsedL1Token, _amount, _gettersData)
                );
        }
    }

    /// @dev send the burn message to the asset
    /// @notice Forwards the burn request for specific asset to respective asset handler.
    /// @param _chainId The chain ID of the ZK chain to which to deposit.
    /// @param _value The L2 `msg.value` from the L1 -> L2 deposit transaction.
    /// @param _assetId The deposited asset ID.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _transferData The encoded data, which is used by the asset handler to determine L2 recipient and amount. Might include extra information.
    /// @param _passValue Boolean indicating whether to pass msg.value in the call.
    /// @return bridgeMintCalldata The calldata used by remote asset handler to mint tokens for recipient.
    function _burn(
        uint256 _chainId,
        uint256 _value,
        bytes32 _assetId,
        address _prevMsgSender,
        bytes memory _transferData,
        bool _passValue
    ) internal returns (bytes memory bridgeMintCalldata) {
        address l1AssetHandler = assetHandlerAddress[_assetId];
        uint256 msgValue = _passValue ? msg.value : 0;
        
        bridgeMintCalldata = IAssetHandler(l1AssetHandler).bridgeBurn{value: msgValue}({
            _chainId: _chainId,
            _mintValue: _value,
            _assetId: _assetId,
            _prevMsgSender: _prevMsgSender,
            _data: _transferData
        });
    }

    /// @notice Deposits allowance to Native Token Vault, if the asset is registered with it. Does nothing for ETH or non-registered tokens.
    /// @dev assetId is not the padded address, but the correct encoded ID (NTV stores respective format for IDs).
    /// @param _assetId The encoding of asset ID.
    /// @param _amount The asset amount to be transferred to native token vault.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    function _transferAllowanceToNTV(bytes32 _assetId, uint256 _amount, address _prevMsgSender) internal {
        address tokenAddress = nativeTokenVault.tokenAddress(_assetId);
        if (tokenAddress == address(0) || tokenAddress == BASE_TOKEN_ADDRESS) {
            return;
        }
        IERC20 token = IERC20(tokenAddress);

        // Do the transfer if allowance to Shared bridge is bigger than amount
        // And if there is not enough allowance for the NTV
        if (
            token.allowance(_prevMsgSender, address(this)) >= _amount &&
            token.allowance(_prevMsgSender, address(nativeTokenVault)) < _amount
        ) {
            // slither-disable-next-line arbitrary-send-erc20
            token.safeTransferFrom(_prevMsgSender, address(this), _amount);
            token.safeIncreaseAllowance(address(nativeTokenVault), _amount);
        }
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
