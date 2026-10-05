// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {console2 as console} from "forge-std/Script.sol";

import {Test} from "forge-std/Test.sol";

import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {L1InteropCenter} from "contracts/interop/interop-center/L1InteropCenter.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {
    L1L2MessageParams,
    L1L2IndirectMessageParams
} from "../../../../../../deploy-scripts/utils/L1InteropRequests.sol";
import {DummyChainTypeManagerWBH} from "contracts/dev-contracts/test/DummyChainTypeManagerWithBridgeHubAddress.sol";
import {DummyZKChain} from "contracts/dev-contracts/test/DummyZKChain.sol";
import {DummyBridgehubSetter} from "contracts/dev-contracts/test/DummyBridgehubSetter.sol";
import {SimpleExecutor} from "contracts/dev-contracts/SimpleExecutor.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";

import {L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {Utils} from "../Utils/Utils.sol";

import {IEIP7702Checker} from "contracts/state-transition/chain-interfaces/IEIP7702Checker.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {
    ETH_TOKEN_ADDRESS,
    HARD_CODED_CHAIN_ID,
    MAINNET_CHAIN_ID,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    SEPOLIA_CHAIN_ID
} from "contracts/common/Config.sol";

import {SlotOccupied} from "contracts/common/L1ContractErrors.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

abstract contract ExperimentalBridgeTestBase is Test {
    address internal weth;
    L1Bridgehub internal bridgehub;
    L1InteropCenter internal l1InteropCenter;
    DummyBridgehubSetter internal dummyBridgehub;
    address public bridgeOwner;
    address public testTokenAddress;
    DummyChainTypeManagerWBH internal mockCTM;
    DummyZKChain internal mockChainContract;
    // These are real `L1AssetRouter` instances used as stand-in asset routers in the
    // bridgehub tests; the legacy `DummySharedBridge` dev stub has been removed.
    L1AssetRouter internal mockSharedBridge;
    L1AssetRouter internal mockSecondSharedBridge;
    L1AssetRouter internal sharedBridge;
    address internal sharedBridgeAddress;
    address internal crossChainSender;
    address internal l1NullifierAddress;
    L1AssetRouter internal crossChainSenderRouter;
    TestnetERC20Token internal testToken;
    L1NativeTokenVault internal ntv;
    IMessageRootBase internal messageRoot;
    L1Nullifier internal l1Nullifier;
    SimpleExecutor internal simpleExecutor;

    bytes32 internal tokenAssetId;

    bytes32 internal ETH_TOKEN_ASSET_ID =
        keccak256(abi.encode(block.chainid, L2_NATIVE_TOKEN_VAULT_ADDR, bytes32(uint256(uint160(ETH_TOKEN_ADDRESS)))));

    TestnetERC20Token internal testToken6;
    TestnetERC20Token internal testToken8;
    TestnetERC20Token internal testToken18;

    address internal mockL2Contract;

    uint256 internal gatewayChainId;

    address internal deployerAddress;

    event NewChain(uint256 indexed chainId, address chainTypeManager, address indexed chainGovernance);

    modifier useRandomToken(uint256 randomValue) {
        _setRandomToken(randomValue);

        _;
    }

    function _setRandomToken(uint256 randomValue) internal {
        uint256 tokenIndex = randomValue % 3;
        if (tokenIndex == 0) {
            testToken = testToken18;
        } else if (tokenIndex == 1) {
            testToken = testToken6;
        } else {
            testToken = testToken8;
        }

        tokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, address(testToken));
    }

    function setUp() public {
        gatewayChainId = 506;
        deployerAddress = makeAddr("DEPLOYER_ADDRESS");
        bridgeOwner = makeAddr("BRIDGE_OWNER");
        dummyBridgehub = new DummyBridgehubSetter(bridgeOwner, type(uint256).max);
        bridgehub = L1Bridgehub(address(dummyBridgehub));
        l1InteropCenter = L1InteropCenter(
            address(
                new TransparentUpgradeableProxy(
                    address(new L1InteropCenter(IL1Bridgehub(address(bridgehub)))),
                    address(uint160(1)),
                    abi.encodeCall(L1InteropCenter.initialize, (bridgeOwner))
                )
            )
        );
        vm.prank(bridgeOwner);
        bridgehub.setInteropCenter(address(l1InteropCenter));
        messageRoot = L1MessageRoot(
            address(
                new TransparentUpgradeableProxy(
                    address(new L1MessageRoot(address(bridgehub), 1, makeAddr("chainAssetHandler"))),
                    address(uint160(1)),
                    abi.encodeCall(L1MessageRoot.initialize, ())
                )
            )
        );
        weth = makeAddr("WETH");
        mockCTM = new DummyChainTypeManagerWBH(address(bridgehub));
        IEIP7702Checker eip7702Checker = IEIP7702Checker(Utils.deployEIP7702Checker());
        mockChainContract = new DummyZKChain(address(bridgehub), block.chainid, address(0), eip7702Checker);

        mockL2Contract = makeAddr("mockL2Contract");
        // mocks to use in bridges instead of using a dummy one
        address mockL1WethAddress = makeAddr("Weth");

        l1Nullifier = new L1Nullifier(bridgehub, messageRoot);
        l1NullifierAddress = address(l1Nullifier);

        mockSharedBridge = _deployAssetRouter(mockL1WethAddress);
        mockSecondSharedBridge = _deployAssetRouter(mockL1WethAddress);

        // kl todo: clean this up. NTV id deployed below in deployNTV. its was a mess before this upgrade.
        ntv = _deployNTVWithoutEthToken(address(mockSharedBridge));
        ntv.registerEthToken();

        vm.prank(bridgeOwner);
        mockSecondSharedBridge.setNativeTokenVault(ntv);

        testToken = new TestnetERC20Token("ZKSTT", "ZkSync Test Token", 18);
        testTokenAddress = address(testToken);
        ntv.registerToken(address(testToken));
        tokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, address(testToken));

        messageRoot = L1MessageRoot(
            address(
                new TransparentUpgradeableProxy(
                    address(new L1MessageRoot(address(bridgehub), gatewayChainId, makeAddr("chainAssetHandler"))),
                    address(uint160(1)),
                    abi.encodeCall(L1MessageRoot.initialize, ())
                )
            )
        );

        sharedBridge = _deployAssetRouter(mockL1WethAddress);
        crossChainSenderRouter = _deployAssetRouter(mockL1WethAddress);

        sharedBridgeAddress = address(sharedBridge);
        crossChainSender = address(crossChainSenderRouter);
        testToken18 = new TestnetERC20Token("ZKSTT", "ZkSync Test Token", 18);
        testToken6 = new TestnetERC20Token("USDC", "USD Coin", 6);
        testToken8 = new TestnetERC20Token("WBTC", "Wrapped Bitcoin", 8);

        // test if the ownership of the bridgehub is set correctly or not
        address defaultOwner = bridgehub.owner();

        // Now, the `reentrancyGuardInitializer` should prevent anyone from calling `initialize` since we have called the constructor of the contract
        vm.expectRevert(SlotOccupied.selector);
        bridgehub.initialize(bridgeOwner);

        mockChainContract.setBaseTokenGasMultiplierPrice(1, 1);
        // The ownership can only be transferred by the current owner to a new owner via the two-step approach

        // Default owner calls transferOwnership
        vm.prank(defaultOwner);
        bridgehub.transferOwnership(bridgeOwner);

        // bridgeOwner calls acceptOwnership
        vm.prank(bridgeOwner);
        bridgehub.acceptOwnership();

        // Ownership should have changed
        assertEq(bridgehub.owner(), bridgeOwner);

        simpleExecutor = new SimpleExecutor();
    }

    /// @dev Deploys a real `L1AssetRouter` and transfers ownership to `bridgeOwner`,
    /// mirroring the production ownership handover. Used everywhere the tests previously
    /// relied on the (now removed) `DummySharedBridge` dev stub.
    function _deployAssetRouter(address _l1WethAddress) internal returns (L1AssetRouter assetRouter) {
        assetRouter = new L1AssetRouter(_l1WethAddress, address(bridgehub), l1NullifierAddress);
        address defaultOwner = assetRouter.owner();
        vm.prank(defaultOwner);
        assetRouter.transferOwnership(bridgeOwner);
        vm.prank(bridgeOwner);
        assetRouter.acceptOwnership();
    }

    function _deployNTVWithoutEthToken(address _sharedBridgeAddr) internal returns (L1NativeTokenVault addr) {
        L1NativeTokenVault ntvImpl = new L1NativeTokenVault(weth, _sharedBridgeAddr, l1Nullifier);
        TransparentUpgradeableProxy ntvProxy = new TransparentUpgradeableProxy(
            address(ntvImpl),
            address(deployerAddress),
            abi.encodeCall(ntvImpl.initialize, (bridgeOwner, address(0)))
        );
        addr = L1NativeTokenVault(payable(ntvProxy));

        vm.prank(bridgeOwner);
        L1AssetRouter(_sharedBridgeAddr).setNativeTokenVault(addr);
    }

    function _deployNTV(address _sharedBridgeAddr) internal returns (L1NativeTokenVault addr) {
        addr = _deployNTVWithoutEthToken(_sharedBridgeAddr);

        addr.registerEthToken();
    }

    function _useFullSharedBridge() internal {
        ntv = _deployNTV(address(sharedBridge));

        crossChainSender = address(sharedBridge);
    }

    function _useMockSharedBridge() internal {
        sharedBridgeAddress = address(mockSharedBridge);
    }

    function _initializeBridgehub() internal {
        vm.prank(bridgeOwner);
        bridgehub.setPendingAdmin(deployerAddress);
        vm.prank(deployerAddress);
        bridgehub.acceptAdmin();

        vm.startPrank(bridgeOwner);
        bridgehub.addChainTypeManager(address(mockCTM));
        bridgehub.addTokenAssetId(tokenAssetId);
        bridgehub.setAddresses({
            _assetRouter: sharedBridgeAddress,
            _l1CtmDeployer: ICTMDeploymentTracker(address(0)),
            _messageRoot: messageRoot,
            _chainAssetHandler: address(0),
            _chainRegistrationSender: address(0)
        });
        vm.stopPrank();

        vm.prank(l1Nullifier.owner());
        l1Nullifier.setL1NativeTokenVault(ntv);
        vm.prank(l1Nullifier.owner());
        l1Nullifier.setL1AssetRouter(sharedBridgeAddress);
    }

    function _prepareETHL2TransactionDirectRequest(
        uint256 mockChainId,
        uint256 mockMintValue,
        address _mockL2Contract,
        uint256 mockL2Value,
        bytes memory mockL2Calldata,
        uint256 mockL2GasLimit
    ) internal returns (L1L2MessageParams memory l2TxnReqDirect, bytes32 canonicalHash) {
        // The L1 Interop Center rejects direct calls without a recipient.
        vm.assume(_mockL2Contract != address(0));
        l2TxnReqDirect = _createMockL2TransactionRequestDirect({
            mockChainId: mockChainId,
            mockMintValue: mockMintValue,
            _mockL2Contract: _mockL2Contract,
            mockL2Value: mockL2Value,
            mockL2Calldata: mockL2Calldata,
            mockL2GasLimit: mockL2GasLimit,
            mockRefundRecipient: address(0)
        });

        l2TxnReqDirect.chainId = _setUpZKChainForChainId(l2TxnReqDirect.chainId, ETH_TOKEN_ADDRESS);

        assertTrue(bridgehub.baseTokenAssetId(l2TxnReqDirect.chainId) == ETH_TOKEN_ASSET_ID);
        console.log(bridgehub.assetRouter().assetHandlerAddress(ETH_TOKEN_ASSET_ID));
        assertTrue(bridgehub.baseToken(l2TxnReqDirect.chainId) == ETH_TOKEN_ADDRESS);

        assertTrue(bridgehub.getZKChain(l2TxnReqDirect.chainId) == address(mockChainContract));
        canonicalHash = keccak256(abi.encode("CANONICAL_TX_HASH"));

        vm.mockCall(
            address(mockChainContract),
            abi.encodeWithSelector(mockChainContract.bridgehubRequestL2Transaction.selector),
            abi.encode(canonicalHash)
        );

        mockChainContract.setFeeParams();
        mockChainContract.setBaseTokenGasMultiplierPrice(uint128(1), uint128(1));
        mockChainContract.setBridgeHubAddress(address(bridgehub));
        assertTrue(mockChainContract.getBridgeHubAddress() == address(bridgehub));
    }

    function _createMockL2TransactionRequestIndirectOuter(
        uint256 chainId,
        uint256 mintValue,
        uint256 l2Value,
        uint256 l2GasLimit,
        uint256 l2GasPerPubdataByteLimit,
        address refundRecipient,
        uint256 indirectCallValue,
        bytes memory indirectCallData
    ) internal view returns (L1L2IndirectMessageParams memory) {
        L1L2IndirectMessageParams memory l2Req;

        // Keep the total ETH funding within uint256.

        mintValue = bound(mintValue, 0, (type(uint256).max) / 2);
        indirectCallValue = bound(indirectCallValue, 0, (type(uint256).max) / 2);

        l2Req.chainId = chainId;
        l2Req.mintValue = mintValue;
        l2Req.l2Value = l2Value;
        l2Req.l2GasLimit = l2GasLimit;
        l2Req.l2GasPerPubdataByteLimit = l2GasPerPubdataByteLimit;
        l2Req.refundRecipient = refundRecipient;
        l2Req.crossChainSender = crossChainSender;
        l2Req.indirectCallValue = indirectCallValue;
        l2Req.indirectCallData = indirectCallData;

        return l2Req;
    }

    function _setUpZKChainForChainId(uint256 _chainId, address _baseToken) internal returns (uint256 chainId) {
        chainId = bound(_chainId, 1, type(uint48).max);
        vm.assume(chainId != block.chainid);
        if (block.chainid == MAINNET_CHAIN_ID || block.chainid == SEPOLIA_CHAIN_ID) {
            vm.assume(chainId != HARD_CODED_CHAIN_ID);
        }
        if (_baseToken != ETH_TOKEN_ADDRESS) {
            ntv.registerToken(_baseToken);
        }
        bytes32 baseTokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, _baseToken);
        if (!bridgehub.assetIdIsRegistered(baseTokenAssetId)) {
            vm.prank(bridgeOwner);
            bridgehub.addTokenAssetId(baseTokenAssetId);
        }

        // Registry and custody tests isolate CTM deployment and genesis; requests use a mocked Mailbox.
        vm.mockCall(
            address(mockCTM),
            abi.encodeWithSelector(mockCTM.createNewChain.selector),
            abi.encode(address(mockChainContract))
        );
        vm.mockCall(
            address(mockChainContract),
            abi.encodeWithSelector(IGetters.l2LogsRootHash.selector, uint256(0)),
            abi.encode(ChainBatchRootTree.genesisChainBatchRoot())
        );
        vm.prank(bridgeOwner);
        IL1Bridgehub(address(bridgehub)).createNewChain({
            _chainId: chainId,
            _chainTypeManager: address(mockCTM),
            _baseTokenAssetId: baseTokenAssetId,
            _salt: 0,
            _admin: bridgeOwner,
            _initData: hex"",
            _factoryDeps: new bytes[](0)
        });
    }

    function _createMockL2TransactionRequestDirect(
        uint256 mockChainId,
        uint256 mockMintValue,
        address _mockL2Contract,
        uint256 mockL2Value,
        bytes memory mockL2Calldata,
        uint256 mockL2GasLimit,
        address mockRefundRecipient
    ) internal pure returns (L1L2MessageParams memory) {
        L1L2MessageParams memory l2TxnReqDirect;

        l2TxnReqDirect.chainId = mockChainId;
        l2TxnReqDirect.mintValue = mockMintValue;
        l2TxnReqDirect.l2Contract = _mockL2Contract;
        l2TxnReqDirect.l2Value = mockL2Value;
        l2TxnReqDirect.l2Calldata = mockL2Calldata;
        l2TxnReqDirect.l2GasLimit = mockL2GasLimit;
        l2TxnReqDirect.l2GasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        l2TxnReqDirect.refundRecipient = mockRefundRecipient;

        return l2TxnReqDirect;
    }
}
