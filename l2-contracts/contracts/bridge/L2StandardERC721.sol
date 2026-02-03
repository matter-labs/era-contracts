// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "./interfaces/IL2StandardERC721Token.sol";

/// @author Matter Labs
/// @notice The ERC721 token implementation, that is used in the "default" ERC721 bridge
contract L2StandardERC721 is ERC721Upgradeable, IL2StandardERC721Token {
    /// @dev Describes whether there is a specific getter in the token.
    /// @notice Used to explicitly separate which getters the token has and which it does not.
    /// @notice Different tokens in L1 can implement or not implement getter function as `name`/`symbol`,
    /// @notice Our goal is to store all the getters that L1 token implements, and for others, we keep it as an unimplemented method.
    struct ERC721Getters {
        bool ignoreName;
        bool ignoreSymbol;
    }

    ERC721Getters availableGetters;

    /// @dev Address of the L2 bridge that is used as trustee who can mint/burn tokens
    address public override l2Bridge;

    /// @dev Address of the L1 token that can be deposited to mint this L2 token
    address public override l1Address;

    /// @dev Mapping of token IDs to tokenURI
    mapping(uint256 => string) public tokenURIs;

    /// @dev Contract is expected to be used as proxy implementation.
    constructor() {
        // Disable initialization to prevent Parity hack.
        _disableInitializers();
    }

    /// @notice Initializes a contract token for later use. Expected to be used in the proxy.
    /// @dev Stores the L1 address of the bridge and set `name`/`symbol` getters that L1 token has.
    /// @param _l1Address Address of the L1 token that can be deposited to mint this L2 token
    /// @param _data The additional data that the L1 bridge provide for initialization.
    /// In this case, it is packed `name`/`symbol` of the L1 token.
    function bridgeInitialize(address _l1Address, bytes memory _data) external initializer {
        require(_l1Address != address(0), "in6"); // Should be non-zero address
        l1Address = _l1Address;

        l2Bridge = msg.sender;

        // We parse the data exactly as they were created on the L1 bridge
        (bytes memory nameBytes, bytes memory symbolBytes) = abi.decode(
            _data,
            (bytes, bytes)
        );

        ERC721Getters memory getters;
        string memory decodedName;
        string memory decodedSymbol;

        // L1 bridge didn't check if the L1 token return values with proper types for `name`/`symbol`
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
        __ERC721_init(decodedName, decodedSymbol);

        availableGetters = getters;
        emit BridgeInitialize(_l1Address, decodedName, decodedSymbol);
    }

    modifier onlyBridge() {
        require(msg.sender == l2Bridge, "xnt"); // Only L2 bridge can call this method
        _;
    }

    /// @dev Mint tokens to a given account.
    /// @param _to The account that will receive the created tokens.
    /// @param _tokenId The token ID to mint.
    /// @param _tokenURI The token URI
    /// @notice Should be called by bridge after depositing tokens from L1.
    function bridgeMint(address _to, uint256 _tokenId, bytes memory _tokenURI) external override onlyBridge {
        _mint(_to, _tokenId);

        tokenURIs[_tokenId] = abi.decode(_tokenURI, (string));
    
        emit BridgeMint(_to, _tokenId);
    }

    /// @dev Burn tokens from a given account.
    /// @param _from The account from which tokens will be burned.
    /// @param _tokenId The token ID to burn
    /// @notice Should be called by bridge before withdrawing tokens to L1.
    function bridgeBurn(address _from, uint256 _tokenId) external override onlyBridge {
        require(ownerOf(_tokenId) == _from, "Invalid owner");

        delete tokenURIs[_tokenId];

        _burn(_tokenId);

        emit BridgeBurn(_from, _tokenId);
    }

    function name() public view override returns (string memory) {
        // If method is not available, behave like a token that does not implement this method - revert on call.
        if (availableGetters.ignoreName) revert();
        return super.name();
    }

    function symbol() public view override returns (string memory) {
        // If method is not available, behave like a token that does not implement this method - revert on call.
        if (availableGetters.ignoreSymbol) revert();
        return super.symbol();
    }

    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        string memory tokenURI_ = tokenURIs[_tokenId];
        return bytes(tokenURI_).length != 0 ? tokenURI_ : super.tokenURI(_tokenId);
    }

    /// @dev External function to decode a string from bytes.
    function decodeString(bytes memory _input) external pure returns (string memory result) {
        (result) = abi.decode(_input, (string));
    }
}
