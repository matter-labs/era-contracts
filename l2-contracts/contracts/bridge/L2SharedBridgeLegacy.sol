// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {L2StandardERC20} from "./L2StandardERC20.sol";

import {L2ContractHelper, DEPLOYER_SYSTEM_CONTRACT, L2_ASSET_ROUTER, L2_NATIVE_TOKEN_VAULT, IContractDeployer} from "../L2ContractHelper.sol";
import {SystemContractsCaller} from "../SystemContractsCaller.sol";

import {IL2SharedBridgeLegacy} from "./interfaces/IL2SharedBridgeLegacy.sol";

import {EmptyAddress, EmptyBytes32, DeployFailed, AmountMustBeGreaterThanZero, InvalidCaller} from "../L2ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The "default" bridge implementation for the ERC20 tokens. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
contract L2SharedBridgeLegacy is IL2SharedBridgeLegacy, Initializable {
    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Disable the initialization to prevent Parity hack.
    uint256 public immutable ERA_CHAIN_ID;

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
    address public override l1Bridge;

    modifier onlyNTV() {
        if (msg.sender != address(L2_NATIVE_TOKEN_VAULT)) {
            revert InvalidCaller(msg.sender);
        }
        _;
    }

    constructor(uint256 _eraChainId) {
        ERA_CHAIN_ID = _eraChainId;
        _disableInitializers();
    }

    /// @notice Initializes the bridge contract for later use. Expected to be used in the proxy.
    /// @param _l1SharedBridge The address of the L1 Bridge contract.
    /// @param _l1Bridge The address of the legacy L1 Bridge contract.
    /// @param _l2TokenProxyBytecodeHash The bytecode hash of the proxy for tokens deployed by the bridge.
    /// @param _aliasedOwner The address of the governor contract.
    function initialize(
        address _l1SharedBridge,
        address _l1Bridge,
        bytes32 _l2TokenProxyBytecodeHash,
        address _aliasedOwner
    ) external reinitializer(2) {
        if (_l1SharedBridge == address(0)) {
            revert EmptyAddress();
        }

        if (_l2TokenProxyBytecodeHash == bytes32(0)) {
            revert EmptyBytes32();
        }

        if (_aliasedOwner == address(0)) {
            revert EmptyAddress();
        }

        l1SharedBridge = _l1SharedBridge;

        if (block.chainid != ERA_CHAIN_ID) {
            address l2StandardToken = address(new L2StandardERC20{salt: bytes32(0)}());
            l2TokenBeacon = new UpgradeableBeacon{salt: bytes32(0)}(l2StandardToken);
            l2TokenProxyBytecodeHash = _l2TokenProxyBytecodeHash;
            l2TokenBeacon.transferOwnership(_aliasedOwner);
        } else {
            if (_l1Bridge == address(0)) {
                revert EmptyAddress();
            }
            l1Bridge = _l1Bridge;
            // l2StandardToken and l2TokenBeacon are already deployed on ERA, and stored in the proxy
        }
    }

    /// @notice Initiates a withdrawal by burning funds on the contract and sending the message to L1
    /// where tokens would be unlocked
    /// @param _l1Receiver The account address that should receive funds on L1
    /// @param _l2Token The L2 token address which is withdrawn
    /// @param _amount The total amount of tokens to be withdrawn
    function withdraw(address _l1Receiver, address _l2Token, uint256 _amount) external override {
        if (_amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }
        L2_ASSET_ROUTER.withdrawLegacyBridge(_l1Receiver, _l2Token, _amount, msg.sender);
    }

    /// @return Address of an L2 token counterpart
    function l2TokenAddress(address _l1Token) public view override returns (address) {
        address token = L2_NATIVE_TOKEN_VAULT.l2TokenAddress(_l1Token);
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

    /// @dev Deploy the beacon proxy for the L2 token, while using ContractDeployer system contract.
    /// @dev This function uses raw call to ContractDeployer to make sure that exactly `l2TokenProxyBytecodeHash` is used
    /// for the code of the proxy.
    function deployBeaconProxy(bytes32 salt) external onlyNTV returns (address proxy) {
        (bool success, bytes memory returndata) = SystemContractsCaller.systemCallWithReturndata(
            uint32(gasleft()),
            DEPLOYER_SYSTEM_CONTRACT,
            0,
            abi.encodeCall(
                IContractDeployer.create2,
                (salt, l2TokenProxyBytecodeHash, abi.encode(address(l2TokenBeacon), ""))
            )
        );

        // The deployment should be successful and return the address of the proxy
        if (!success) {
            revert DeployFailed();
        }
        proxy = abi.decode(returndata, (address));
    }
}
