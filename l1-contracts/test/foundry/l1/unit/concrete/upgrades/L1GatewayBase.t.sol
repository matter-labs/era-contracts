// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {L1FixedForceDeploymentsHelper} from "contracts/upgrades/L1FixedForceDeploymentsHelper.sol"; // Adjust the import path accordingly
import {ZKChainStorage} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IL1SharedBridgeLegacy} from "contracts/bridge/interfaces/IL1SharedBridgeLegacy.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {ZKChainSpecificForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";

// Concrete implementation of L1FixedForceDeploymentsHelper for testing
contract TestL1FixedForceDeploymentsHelper is L1FixedForceDeploymentsHelper {
    ZKChainStorage s;

    // For testing, we need to be able to call the internal function from outside
    function requestGetZKChainSpecificForceDeploymentsData(
        address _wrappedBaseTokenStore,
        address _baseTokenAddress
    ) external view returns (bytes memory) {
        return getZKChainSpecificForceDeploymentsData(s, _wrappedBaseTokenStore, _baseTokenAddress);
    }

    function setChainId(uint256 _chainId) external {
        s.chainId = _chainId;
    }

    function setBaseTokenAssetId(bytes32 _assetId) external {
        s.baseTokenAssetId = _assetId;
    }

    function setBrideghub(address _bridgehub) external {
        s.bridgehub = _bridgehub;
    }
}

contract MockERC20TokenWithMetadata {
    string private _name;
    string private _symbol;

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }
}

contract MockERC20TokenWithoutMetadata {}

contract L1FixedForceDeploymentsHelperTest is Test {
    TestL1FixedForceDeploymentsHelper testGateway;
    // Mocks for dependencies
    address bridgehubMock;
    address sharedBridgeMock;
    // MockL2WrappedBaseTokenStore wrappedBaseTokenStoreMock;

    // Addresses
    address sharedBridgeAddress;
    address legacySharedBridgeAddress;

    // Chain ID for testing
    uint256 chainId = 123;
    bytes32 baseTokenAssetId;

    function setUp() public {
        baseTokenAssetId = bytes32("baseTokenAssetId");
        bridgehubMock = makeAddr("bridgehubMock");
        sharedBridgeMock = makeAddr("sharedBridgeMock");
        legacySharedBridgeAddress = makeAddr("legacySharedBridgeAddress");

        testGateway = new TestL1FixedForceDeploymentsHelper();

        // Initialize ZKChainStorage
        testGateway.setChainId(chainId);
        testGateway.setBrideghub(bridgehubMock);
        // Set base token asset ID
        testGateway.setBaseTokenAssetId(baseTokenAssetId);

        vm.mockCall(bridgehubMock, abi.encodeCall(IBridgehub.sharedBridge, ()), abi.encode(sharedBridgeMock));
        vm.mockCall(
            sharedBridgeMock,
            abi.encodeCall(IL1SharedBridgeLegacy.l2BridgeAddress, (chainId)),
            abi.encode(address(legacySharedBridgeAddress))
        );
    }

    // Test with ETH as the base token
    function testWithETH() public {
        // No wrapped base token store
        address _wrappedBaseTokenStore = address(0);

        // Call the function
        bytes memory data = testGateway.requestGetZKChainSpecificForceDeploymentsData(
            _wrappedBaseTokenStore,
            ETH_TOKEN_ADDRESS
        );

        // Decode the returned data
        ZKChainSpecificForceDeploymentsData memory chainData = abi.decode(data, (ZKChainSpecificForceDeploymentsData));

        // Check the values
        assertEq(chainData.baseTokenAssetId, baseTokenAssetId);
        assertEq(chainData.l2LegacySharedBridge, legacySharedBridgeAddress);
        assertEq(chainData.predeployedL2WethAddress, address(0));
        assertEq(chainData.baseTokenL1Address, ETH_TOKEN_ADDRESS);
        assertEq(chainData.baseTokenName, "Ether");
        assertEq(chainData.baseTokenSymbol, "ETH");
    }

    // Test with ERC20 that correctly implements metadata
    function testWithERC20TokenWithMetadata() public {
        // Deploy a mock ERC20 token that implements name() and symbol()
        MockERC20TokenWithMetadata token = new MockERC20TokenWithMetadata("Test Token", "TTK");

        // No wrapped base token store
        address _wrappedBaseTokenStore = address(0);

        // Call the function
        bytes memory data = testGateway.requestGetZKChainSpecificForceDeploymentsData(
            _wrappedBaseTokenStore,
            address(token)
        );

        // Decode the returned data
        ZKChainSpecificForceDeploymentsData memory chainData = abi.decode(data, (ZKChainSpecificForceDeploymentsData));

        // Check the values
        assertEq(chainData.baseTokenAssetId, baseTokenAssetId);
        assertEq(chainData.l2LegacySharedBridge, legacySharedBridgeAddress);
        assertEq(chainData.predeployedL2WethAddress, address(0));
        assertEq(chainData.baseTokenL1Address, address(token));
        assertEq(chainData.baseTokenName, "Test Token");
        assertEq(chainData.baseTokenSymbol, "TTK");
    }

    // Test with ERC20 that does not implement metadata
    function testWithERC20TokenWithoutMetadata() public {
        // Deploy a mock ERC20 token that does not implement name() and symbol()
        MockERC20TokenWithoutMetadata token = new MockERC20TokenWithoutMetadata();

        // No wrapped base token store
        address _wrappedBaseTokenStore = address(0);

        // Call the function
        bytes memory data = testGateway.requestGetZKChainSpecificForceDeploymentsData(
            _wrappedBaseTokenStore,
            address(token)
        );

        // Decode the returned data
        ZKChainSpecificForceDeploymentsData memory chainData = abi.decode(data, (ZKChainSpecificForceDeploymentsData));

        // Check the values
        assertEq(chainData.baseTokenAssetId, baseTokenAssetId);
        assertEq(chainData.l2LegacySharedBridge, legacySharedBridgeAddress);
        assertEq(chainData.predeployedL2WethAddress, address(0));
        assertEq(chainData.baseTokenL1Address, address(token));
        assertEq(chainData.baseTokenName, "Base Token");
        assertEq(chainData.baseTokenSymbol, "BT");
    }
}
