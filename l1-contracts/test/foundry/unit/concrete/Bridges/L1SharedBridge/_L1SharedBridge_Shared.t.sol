// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1AssetRouter} from "contracts/bridge/L1AssetRouter.sol";
import {IL1AssetRouter} from "contracts/bridge/interfaces/IL1AssetRouter.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {L1NativeTokenVault} from "contracts/bridge/L1NativeTokenVault.sol";
import {IL1NativeTokenVault} from "contracts/bridge/interfaces/IL1NativeTokenVault.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDRESS, L2_ASSET_ROUTER_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

contract L1AssetRouterTest is Test {
    using stdStorage for StdStorage;

    event BridgehubDepositBaseTokenInitiated(
        uint256 indexed chainId,
        address indexed from,
        bytes32 assetId,
        uint256 amount
    );

    event BridgehubDepositInitiated(
        uint256 indexed chainId,
        bytes32 indexed txDataHash,
        address indexed from,
        bytes32 assetId,
        bytes bridgeMintCalldata
    );

    event BridgehubDepositFinalized(
        uint256 indexed chainId,
        bytes32 indexed txDataHash,
        bytes32 indexed l2DepositTxHash
    );

    event WithdrawalFinalizedSharedBridge(
        uint256 indexed chainId,
        address indexed to,
        bytes32 indexed assetId,
        uint256 amount
    );

    event ClaimedFailedDepositSharedBridge(
        uint256 indexed chainId,
        address indexed to,
        bytes32 indexed assetId,
        bytes assetData
    );

    event LegacyDepositInitiated(
        uint256 indexed chainId,
        bytes32 indexed l2DepositTxHash,
        address indexed from,
        address to,
        address l1Token,
        uint256 amount
    );

    L1AssetRouter sharedBridgeImpl;
    L1AssetRouter sharedBridge;
    L1NativeTokenVault nativeTokenVaultImpl;
    L1NativeTokenVault nativeTokenVault;
    address bridgehubAddress;
    address l1ERC20BridgeAddress;
    address l1WethAddress;
    address l2SharedBridge;
    TestnetERC20Token token;
    bytes32 tokenAssetId;
    uint256 eraPostUpgradeFirstBatch;

    address owner;
    address admin;
    address zkSync;
    address alice;
    address bob;
    uint256 chainId;
    uint256 amount = 100;
    uint256 mintValue = 1;
    bytes32 txHash;
    uint256 gas = 1_000_000;

    uint256 eraChainId;
    uint256 randomChainId;
    address eraDiamondProxy;
    address eraErc20BridgeAddress;

    uint256 l2BatchNumber;
    uint256 l2MessageIndex;
    uint16 l2TxNumberInBatch;
    bytes32[] merkleProof;
    uint256 legacyBatchNumber = 0;

    uint256 isWithdrawalFinalizedStorageLocation = uint256(8 - 1 + (1 + 49) + 0 + (1 + 49) + 50 + 1 + 50);
    bytes32 ETH_TOKEN_ASSET_ID = keccak256(abi.encode(block.chainid, L2_NATIVE_TOKEN_VAULT_ADDRESS, ETH_TOKEN_ADDRESS));

    function setUp() public {
        owner = makeAddr("owner");
        admin = makeAddr("admin");
        // zkSync = makeAddr("zkSync");
        bridgehubAddress = makeAddr("bridgehub");
        alice = makeAddr("alice");
        // bob = makeAddr("bob");
        l1WethAddress = makeAddr("weth");
        l1ERC20BridgeAddress = makeAddr("l1ERC20Bridge");
        l2SharedBridge = makeAddr("l2SharedBridge");

        txHash = bytes32(uint256(uint160(makeAddr("txHash"))));
        l2BatchNumber = 3; //uint256(uint160(makeAddr("l2BatchNumber")));
        l2MessageIndex = uint256(uint160(makeAddr("l2MessageIndex")));
        l2TxNumberInBatch = uint16(uint160(makeAddr("l2TxNumberInBatch")));
        merkleProof = new bytes32[](1);
        eraPostUpgradeFirstBatch = 1;

        chainId = 1;
        eraChainId = 9;
        randomChainId = 999;
        eraDiamondProxy = makeAddr("eraDiamondProxy");
        eraErc20BridgeAddress = makeAddr("eraErc20BridgeAddress");

        token = new TestnetERC20Token("TestnetERC20Token", "TET", 18);
        sharedBridgeImpl = new L1AssetRouter({
            _l1WethAddress: l1WethAddress,
            _bridgehub: IBridgehub(bridgehubAddress),
            _eraChainId: eraChainId,
            _eraDiamondProxy: eraDiamondProxy
        });
        TransparentUpgradeableProxy sharedBridgeProxy = new TransparentUpgradeableProxy(
            address(sharedBridgeImpl),
            admin,
            abi.encodeWithSelector(L1AssetRouter.initialize.selector, owner, 1, 1, 1, 0)
        );
        sharedBridge = L1AssetRouter(payable(sharedBridgeProxy));
        nativeTokenVaultImpl = new L1NativeTokenVault({
            _l1WethAddress: l1WethAddress,
            _l1SharedBridge: IL1AssetRouter(address(sharedBridge))
        });
        TransparentUpgradeableProxy nativeTokenVaultProxy = new TransparentUpgradeableProxy(
            address(nativeTokenVaultImpl),
            admin,
            abi.encodeWithSelector(L1NativeTokenVault.initialize.selector, owner)
        );
        nativeTokenVault = L1NativeTokenVault(payable(nativeTokenVaultProxy));
        vm.prank(owner);
        sharedBridge.setL1Erc20Bridge(l1ERC20BridgeAddress);
        tokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, address(token));
        vm.prank(owner);
        sharedBridge.setNativeTokenVault(IL1NativeTokenVault(address(nativeTokenVault)));
        vm.prank(address(nativeTokenVault));
        nativeTokenVault.registerToken(address(token));
        nativeTokenVault.registerToken(ETH_TOKEN_ADDRESS);

        vm.store(
            address(sharedBridge),
            bytes32(isWithdrawalFinalizedStorageLocation),
            bytes32(eraPostUpgradeFirstBatch)
        );
        vm.store(
            address(sharedBridge),
            bytes32(isWithdrawalFinalizedStorageLocation + 1),
            bytes32(eraPostUpgradeFirstBatch)
        );
        vm.store(address(sharedBridge), bytes32(isWithdrawalFinalizedStorageLocation + 2), bytes32(uint256(1)));
        vm.store(address(sharedBridge), bytes32(isWithdrawalFinalizedStorageLocation + 3), bytes32(0));

        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseTokenAssetId.selector),
            abi.encode(ETH_TOKEN_ASSET_ID)
        );
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseTokenAssetId.selector, chainId),
            abi.encode(ETH_TOKEN_ASSET_ID)
        );
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.requestL2TransactionDirect.selector),
            abi.encode(txHash)
        );
        // vm.mockCall(
        //     address(bridgehubAddress),
        //     abi.encodeWithSelector(IBridgehub.baseTokenAssetId.selector, address(token)),
        //     abi.encode(nativeTokenVault.getAssetId(address(token)))
        // );

        token.mint(address(nativeTokenVault), amount);

        /// storing chainBalance
        _setNativeTokenVaultChainBalance(chainId, address(token), 1000 * amount);
        _setNativeTokenVaultChainBalance(chainId, ETH_TOKEN_ADDRESS, amount);
        // console.log("chainBalance %s, %s", address(token), nativeTokenVault.chainBalance(chainId, address(token)));
        _setSharedBridgeChainBalance(chainId, address(token), amount);
        _setSharedBridgeChainBalance(chainId, ETH_TOKEN_ADDRESS, amount);

        vm.deal(bridgehubAddress, amount);
        vm.deal(address(sharedBridge), amount);
        vm.deal(address(nativeTokenVault), amount);
        token.mint(alice, amount);
        token.mint(address(sharedBridge), amount);
        token.mint(address(nativeTokenVault), amount);
        vm.prank(alice);
        token.approve(address(sharedBridge), amount);
        vm.prank(alice);
        token.approve(address(nativeTokenVault), amount);

        _setBaseTokenAssetId(ETH_TOKEN_ASSET_ID);
        _setNativeTokenVaultChainBalance(chainId, address(token), amount);

        vm.mockCall(
            address(nativeTokenVault),
            abi.encodeWithSelector(IL1NativeTokenVault.tokenAddress.selector, tokenAssetId),
            abi.encode(address(token))
        );
        vm.mockCall(
            address(nativeTokenVault),
            abi.encodeWithSelector(IL1NativeTokenVault.tokenAddress.selector, ETH_TOKEN_ASSET_ID),
            abi.encode(address(ETH_TOKEN_ADDRESS))
        );
    }

    function _setSharedBridgeDepositHappened(uint256 _chainId, bytes32 _txHash, bytes32 _txDataHash) internal {
        stdstore
            .target(address(sharedBridge))
            .sig(sharedBridge.depositHappened.selector)
            .with_key(_chainId)
            .with_key(_txHash)
            .checked_write(_txDataHash);
    }

    function _setNativeTokenVaultChainBalance(uint256 _chainId, address _token, uint256 _value) internal {
        stdstore
            .target(address(nativeTokenVault))
            .sig(nativeTokenVault.chainBalance.selector)
            .with_key(_chainId)
            .with_key(_token)
            .checked_write(_value);
    }

    function _setSharedBridgeChainBalance(uint256 _chainId, address _token, uint256 _value) internal {
        stdstore
            .target(address(sharedBridge))
            .sig(sharedBridge.chainBalance.selector)
            .with_key(_chainId)
            .with_key(_token)
            .checked_write(_value);
    }

    function _setBaseTokenAssetId(bytes32 _assetId) internal {
        // vm.prank(bridgehubAddress);
        vm.mockCall(
            bridgehubAddress,
            abi.encodeWithSelector(IBridgehub.baseTokenAssetId.selector, chainId),
            abi.encode(_assetId)
        );
    }
}
