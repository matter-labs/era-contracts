// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Upgrade} from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Upgrade.sol";

import {IBridgedStandardToken} from "./interfaces/IBridgedStandardToken.sol";
import {Unauthorized, NonSequentialVersion, ZeroAddress} from "../common/L1ContractErrors.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "../common/L2ContractAddresses.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {INativeTokenVault} from "../bridge/ntv/INativeTokenVault.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The ERC20 token implementation, that is used in the "default" ERC20 bridge. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
contract BridgedStandardERC20 is ERC20PermitUpgradeable, IBridgedStandardToken, ERC1967Upgrade {
    /// @dev Describes whether there is a specific getter in the token.
    /// @notice Used to explicitly separate which getters the token has and which it does not.
    /// @notice Different tokens in L1 can implement or not implement getter function as `name`/`symbol`/`decimals`,
    /// @notice Our goal is to store all the getters that L1 token implements, and for others, we keep it as an unimplemented method.
    struct ERC20Getters {
        bool ignoreName;
        bool ignoreSymbol;
        bool ignoreDecimals;
    }

    ERC20Getters private availableGetters;

    /// @dev The decimals of the token, that are used as a value for `decimals` getter function.
    /// @notice A private variable is used only for decimals, but not for `name` and `symbol`, because standard
    /// @notice OpenZeppelin token represents `name` and `symbol` as storage variables and `decimals` as constant.
    uint8 private decimals_;

    /// @notice The l2Bridge now is deprecated, use the L2AssetRouter and L2NativeTokenVault instead.
    /// @dev Address of the L2 bridge that is used as trustee who can mint/burn tokens
    address public override l2Bridge;

    /// @dev Address of the token on its origin chain that can be deposited to mint this bridged token
    address public override originToken;

    /// @dev Address of the native token vault that is used as trustee who can mint/burn tokens
    address public nativeTokenVault;

    /// @dev The assetId of the token.
    bytes32 public assetId;

    /// @dev This also sets the native token vault to the default value if it is not set.
    /// It is not set only on the L2s for legacy tokens.
    modifier onlyNTV() {
        address ntv = nativeTokenVault;
        if (ntv == address(0)) {
            ntv = L2_NATIVE_TOKEN_VAULT_ADDR;
            nativeTokenVault = L2_NATIVE_TOKEN_VAULT_ADDR;
            assetId = DataEncoding.encodeNTVAssetId(
                INativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).L1_CHAIN_ID(),
                originToken
            );
        }
        if (msg.sender != ntv) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyNextVersion(uint8 _version) {
        // The version should be incremented by 1. Otherwise, the governor risks disabling
        // future reinitialization of the token by providing too large a version.
        if (_version != _getInitializedVersion() + 1) {
            revert NonSequentialVersion();
        }
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    constructor() {
        // Disable initialization to prevent Parity hack.
        _disableInitializers();
    }

    /// @notice Initializes a contract token for later use. Expected to be used in the proxy.
    /// @dev Stores the L1 address of the bridge and set `name`/`symbol`/`decimals` getters that L1 token has.
    /// @param _assetId The assetId of the token.
    /// @param _originToken Address of the origin token that can be deposited to mint this bridged token
    /// @param _data The additional data that the L1 bridge provide for initialization.
    /// In this case, it is packed `name`/`symbol`/`decimals` of the L1 token.
    function bridgeInitialize(bytes32 _assetId, address _originToken, bytes calldata _data) external initializer {
        if (_originToken == address(0)) {
            revert ZeroAddress();
        }
        originToken = _originToken;
        assetId = _assetId;

        nativeTokenVault = msg.sender;

        bytes memory nameBytes;
        bytes memory symbolBytes;
        bytes memory decimalsBytes;
        // We parse the data exactly as they were created on the L1 bridge
        // slither-disable-next-line unused-return
        (, nameBytes, symbolBytes, decimalsBytes) = DataEncoding.decodeTokenData(_data);

        ERC20Getters memory getters;
        string memory decodedName;
        string memory decodedSymbol;

        // L1 bridge didn't check if the L1 token return values with proper types for `name`/`symbol`/`decimals`
        // That's why we need to try to decode them, and if it works out, set the values as getters.

        // NOTE: Solidity doesn't have a convenient way to try to decode a value:
        // - Decode them manually, i.e. write a function that will validate that data in the correct format
        // and return decoded value and a boolean value - whether it was possible to decode.
        // - Use the standard abi.decode method, but wrap it into an external call in which error can be handled.
        // We use the second option here.

        try this.decodeString(nameBytes) returns (string memory nameString) {
            decodedName = nameString;
        } catch {
            getters.ignoreName = true;
        }

        try this.decodeString(symbolBytes) returns (string memory symbolString) {
            decodedSymbol = symbolString;
        } catch {
            getters.ignoreSymbol = true;
        }

        // Set decoded values for name and symbol.
        __ERC20_init_unchained(decodedName, decodedSymbol);

        // Set the name for EIP-712 signature.
        __ERC20Permit_init(decodedName);

        try this.decodeUint8(decimalsBytes) returns (uint8 decimalsUint8) {
            // Set decoded value for decimals.
            decimals_ = decimalsUint8;
        } catch {
            getters.ignoreDecimals = true;
        }

        availableGetters = getters;
        emit BridgeInitialize(_originToken, decodedName, decodedSymbol, decimals_);
    }

    /// @notice A method to be called by the governor to update the token's metadata.
    /// @param _availableGetters The getters that the token has.
    /// @param _newName The new name of the token.
    /// @param _newSymbol The new symbol of the token.
    /// @param _version The version of the token that will be initialized.
    /// @dev The _version must be exactly the version higher by 1 than the current version. This is needed
    /// to ensure that the governor can not accidentally disable future reinitialization of the token.
    function reinitializeToken(
        ERC20Getters calldata _availableGetters,
        string calldata _newName,
        string calldata _newSymbol,
        uint8 _version
    ) external onlyNextVersion(_version) reinitializer(_version) {
        // It is expected that this token is deployed as a beacon proxy, so we'll
        // allow the governor of the beacon to reinitialize the token.
        address beaconAddress = _getBeacon();
        if (msg.sender != UpgradeableBeacon(beaconAddress).owner()) {
            revert Unauthorized(msg.sender);
        }

        __ERC20_init_unchained(_newName, _newSymbol);
        __ERC20Permit_init(_newName);
        availableGetters = _availableGetters;

        emit BridgeInitialize(originToken, _newName, _newSymbol, decimals_);
    }

    /// @dev Mint tokens to a given account.
    /// @param _to The account that will receive the created tokens.
    /// @param _amount The amount that will be created.
    /// @notice Should be called by bridge after depositing tokens from L1.
    function bridgeMint(address _to, uint256 _amount) external override onlyNTV {
        _mint(_to, _amount);
        emit BridgeMint(_to, _amount);
    }

    /// @dev Burn tokens from a given account.
    /// @param _from The account from which tokens will be burned.
    /// @param _amount The amount that will be burned.
    /// @notice Should be called by bridge before withdrawing tokens to L1.
    function bridgeBurn(address _from, uint256 _amount) external override onlyNTV {
        _burn(_from, _amount);
        emit BridgeBurn(_from, _amount);
    }

    /// @dev External function to decode a string from bytes.
    function decodeString(bytes calldata _input) external pure returns (string memory result) {
        (result) = abi.decode(_input, (string));
    }

    /// @dev External function to decode a uint8 from bytes.
    function decodeUint8(bytes calldata _input) external pure returns (uint8 result) {
        (result) = abi.decode(_input, (uint8));
    }

    function name() public view override returns (string memory) {
        // If method is not available, behave like a token that does not implement this method - revert on call.
        // solhint-disable-next-line reason-string, gas-custom-errors
        if (availableGetters.ignoreName) revert();
        return super.name();
    }

    function symbol() public view override returns (string memory) {
        // If method is not available, behave like a token that does not implement this method - revert on call.
        // solhint-disable-next-line reason-string, gas-custom-errors
        if (availableGetters.ignoreSymbol) revert();
        return super.symbol();
    }

    function decimals() public view override returns (uint8) {
        // If method is not available, behave like a token that does not implement this method - revert on call.
        // solhint-disable-next-line reason-string, gas-custom-errors
        if (availableGetters.ignoreDecimals) revert();
        return decimals_;
    }

    /*//////////////////////////////////////////////////////////////
                            LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the address of the token on its native chain.
    /// Legacy for the l2 bridge.
    function l1Address() public view override returns (address) {
        return originToken;
    }
}
