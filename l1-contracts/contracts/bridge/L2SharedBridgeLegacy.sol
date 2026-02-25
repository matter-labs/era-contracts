// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-v4/proxy/utils/Initializable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";

import {BridgedStandardERC20} from "./BridgedStandardERC20.sol";

import {
    L2_ASSET_ROUTER_ADDR,
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR
} from "../common/l2-helpers/L2ContractAddresses.sol";
import {SystemContractsCaller} from "../common/l2-helpers/SystemContractsCaller.sol";
import {IContractDeployer, L2ContractHelper} from "../common/l2-helpers/L2ContractHelper.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";

import {IL2AssetRouter} from "./asset-router/IL2AssetRouter.sol";
import {IL2NativeTokenVault} from "./ntv/IL2NativeTokenVault.sol";

import {IL2SharedBridgeLegacy} from "./interfaces/IL2SharedBridgeLegacy.sol";
import {
    AmountMustBeGreaterThanZero,
    DeployFailed,
    EmptyBytes32,
    Unauthorized,
    ZeroAddress
} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The "default" bridge implementation for the ERC20 tokens. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
/// @dev Note, that this contract should be compatible with its previous version as it will be
/// the primary bridge to be used during migration.
contract L2SharedBridgeLegacy is IL2SharedBridgeLegacy, Initializable {
    /// @dev The address of the L1 shared bridge counterpart.
    address public override l1SharedBridge;

    /// @dev Contract that stores the implementation address for token.
    /// @dev For more details see https://docs.openzeppelin.com/contracts/3.x/api/proxy#UpgradeableBeacon.
    UpgradeableBeacon public l2TokenBeacon;

    /// @dev Bytecode hash of the proxy for tokens deployed by the bridge.
    bytes32 internal l2TokenProxyBytecodeHash;

    /// @dev A mapping l2 token address => l1 token address
    mapping(address l2TokenAddress => address l1TokenAddress) public override l1TokenAddress;

    /// @dev The address of the legacy L1 erc20 bridge counterpart.
    /// This is non-zero only on Era, and should not be renamed for backward compatibility with the SDKs.
    // slither-disable-next-line uninitialized-state
    address public override l1Bridge;

    modifier onlyNTV() {
        require(msg.sender == L2_NATIVE_TOKEN_VAULT_ADDR, Unauthorized(msg.sender));
        _;
    }

    modifier onlyAssetRouter() {
        require(msg.sender == L2_ASSET_ROUTER_ADDR, Unauthorized(msg.sender));
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the bridge contract for later use. Expected to be used in the proxy.
    /// @param _l1SharedBridge The address of the L1 Bridge contract.
    /// @param _l2TokenProxyBytecodeHash The bytecode hash of the proxy for tokens deployed by the bridge.
    /// @param _aliasedOwner The address of the governor contract.
    function initialize(
        address _l1SharedBridge,
        bytes32 _l2TokenProxyBytecodeHash,
        address _aliasedOwner
    ) external reinitializer(2) {
        require(_l1SharedBridge != address(0), ZeroAddress());

        require(_l2TokenProxyBytecodeHash != bytes32(0), EmptyBytes32());

        require(_aliasedOwner != address(0), ZeroAddress());

        l1SharedBridge = _l1SharedBridge;

        // The following statement is true only in freshly deployed environments. However,
        // for those environments we do not need to deploy this contract at all.
        // This check is primarily for local testing purposes.
        if (l2TokenProxyBytecodeHash == bytes32(0) && address(l2TokenBeacon) == address(0)) {
            address l2StandardToken = address(new BridgedStandardERC20{salt: bytes32(0)}());
            l2TokenBeacon = new UpgradeableBeacon{salt: bytes32(0)}(l2StandardToken);
            l2TokenProxyBytecodeHash = _l2TokenProxyBytecodeHash;
            l2TokenBeacon.transferOwnership(_aliasedOwner);
        }
    }

    /// @notice Initiates a withdrawal by burning funds and sending the message to L1
    /// where tokens would be unlocked
    /// @param _l1Receiver The account address that should receive funds on L1
    /// @param _l2Token The L2 token address which is withdrawn
    /// @param _amount The total amount of tokens to be withdrawn
    function withdraw(address _l1Receiver, address _l2Token, uint256 _amount) external override {
        require(_amount != 0, AmountMustBeGreaterThanZero());
        IL2AssetRouter(L2_ASSET_ROUTER_ADDR).withdrawLegacyBridge(_l1Receiver, _l2Token, _amount, msg.sender);
    }

    /// @notice Finalize the deposit and mint funds
    /// @param _l1Sender The account address that initiated the deposit on L1
    /// @param _l2Receiver The account address that would receive minted tokens
    /// @param _l1Token The address of the token that was locked on the L1
    /// @param _amount Total amount of tokens deposited from L1
    /// @param _data The additional data that user can pass with the deposit
    function finalizeDeposit(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        bytes calldata _data
    ) external {
        // Only the L1 bridge counterpart can initiate and finalize the deposit.
        if (
            AddressAliasHelper.undoL1ToL2Alias(msg.sender) != l1Bridge &&
            AddressAliasHelper.undoL1ToL2Alias(msg.sender) != l1SharedBridge
        ) {
            revert Unauthorized(msg.sender);
        }

        IL2AssetRouter(L2_ASSET_ROUTER_ADDR).finalizeDepositLegacyBridge({
            _l1Sender: _l1Sender,
            _l2Receiver: _l2Receiver,
            _l1Token: _l1Token,
            _amount: _amount,
            _data: _data
        });

        address l2Token = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).l2TokenAddress(_l1Token);

        if (l1TokenAddress[l2Token] == address(0)) {
            l1TokenAddress[l2Token] = _l1Token;
        }

        emit FinalizeDeposit(_l1Sender, _l2Receiver, l2Token, _amount);
    }

    /// @return Address of an L2 token counterpart
    function l2TokenAddress(address _l1Token) public view override returns (address) {
        address token = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).l2TokenAddress(_l1Token);
        if (token != address(0)) {
            return token;
        }
        return _calculateCreate2TokenAddress(_l1Token);
    }

    /// @notice Calculates L2 wrapped token address given the currently stored beacon proxy bytecode hash and beacon address.
    /// @param _l1Token The address of token on L1.
    /// @return Address of an L2 token counterpart.
    function _calculateCreate2TokenAddress(address _l1Token) internal view returns (address) {
        bytes32 constructorInputHash = keccak256(abi.encode(address(l2TokenBeacon), ""));
        bytes32 salt = _getCreate2Salt(_l1Token);
        return
            L2ContractHelper.computeCreate2Address(address(this), salt, l2TokenProxyBytecodeHash, constructorInputHash);
    }

    /// @dev Convert the L1 token address to the create2 salt of deployed L2 token
    function _getCreate2Salt(address _l1Token) internal pure returns (bytes32 salt) {
        salt = bytes32(uint256(uint160(_l1Token)));
    }

    /// @notice Deploys a beacon proxy for an L2 token using the ContractDeployer system contract.
    /// @dev This function uses raw call to ContractDeployer to make sure that exactly `l2TokenProxyBytecodeHash` is used
    /// for the code of the proxy.
    /// @param salt The salt used for CREATE2 deployment to ensure deterministic addresses.
    /// @return proxy The address of the deployed beacon proxy contract.
    function deployBeaconProxy(bytes32 salt) external onlyNTV returns (address proxy) {
        (bool success, bytes memory returndata) = SystemContractsCaller.systemCallWithReturndata(
            uint32(gasleft()),
            L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
            0,
            abi.encodeCall(
                IContractDeployer.create2,
                (salt, l2TokenProxyBytecodeHash, abi.encode(address(l2TokenBeacon), ""))
            )
        );

        // The deployment should be successful and return the address of the proxy
        require(success, DeployFailed());
        proxy = abi.decode(returndata, (address));
    }

    /// @notice Sends a message from to L1.
    /// @param _message The message data to send to L1.
    /// @return The hash of the sent message.
    function sendMessageToL1(bytes calldata _message) external override onlyAssetRouter returns (bytes32) {
        // slither-disable-next-line unused-return
        return L2ContractHelper.sendMessageToL1(_message);
    }
}
