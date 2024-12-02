// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1SharedBridge} from "contracts/bridge/L1SharedBridge.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";
import {DummyStateTransitionManagerWBH} from "contracts/dev-contracts/test/DummyStateTransitionManagerWithBridgeHubAddress.sol";

contract L1SharedBridgeTest is Test {
    using stdStorage for StdStorage;

    event BridgehubDepositBaseTokenInitiated(
        uint256 indexed chainId,
        address indexed from,
        address l1Token,
        uint256 amount
    );

    event BridgehubDepositInitiated(
        uint256 indexed chainId,
        bytes32 indexed txDataHash,
        address indexed from,
        address to,
        address l1Token,
        uint256 amount
    );

    event BridgehubDepositFinalized(
        uint256 indexed chainId,
        bytes32 indexed txDataHash,
        bytes32 indexed l2DepositTxHash
    );

    event WithdrawalFinalizedSharedBridge(
        uint256 indexed chainId,
        address indexed to,
        address indexed l1Token,
        uint256 amount
    );

    event ClaimedFailedDepositSharedBridge(
        uint256 indexed chainId,
        address indexed to,
        address indexed l1Token,
        uint256 amount
    );

    event LegacyDepositInitiated(
        uint256 indexed chainId,
        bytes32 indexed l2DepositTxHash,
        address indexed from,
        address to,
        address l1Token,
        uint256 amount
    );

    L1SharedBridge sharedBridgeImpl;
    L1SharedBridge sharedBridge;
    DummyBridgehub bridgeHub;
    DummyStateTransitionManagerWBH stm;
    address bridgehubAddress;
    L1ERC20Bridge l1Erc20Bridge;
    address l1ERC20BridgeAddress;
    address l1WethAddress;
    address l2SharedBridge;
    TestnetERC20Token token;
    uint256 eraPostUpgradeFirstBatch;

    address owner;
    address admin;
    address proxyAdmin;
    address zkSync;
    address alice;
    address bob;
    address stmAddress;
    uint256 chainId;
    uint256 amount = 100;
    bytes32 txHash;

    uint256 eraChainId;
    address eraDiamondProxy;
    address eraErc20BridgeAddress;

    uint256 l2BatchNumber;
    uint256 l2MessageIndex;
    uint16 l2TxNumberInBatch;
    bytes32[] merkleProof;

    modifier testPause() {
        vm.prank(owner);
        sharedBridge.pause();
        assertTrue(sharedBridge.paused());
        vm.expectRevert("Pausable: paused");
        _;
    }

    uint256 isWithdrawalFinalizedStorageLocation = uint256(8 - 1 + (1 + 49) + 0 + (1 + 49) + 50 + 1 + 50);

    function setUp() public {
        owner = makeAddr("owner");
        admin = makeAddr("admin");
        proxyAdmin = makeAddr("proxyAdmin");
        // zkSync = makeAddr("zkSync");
        zkSync = makeAddr("zkSync");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        l1WethAddress = makeAddr("weth");

        l2SharedBridge = makeAddr("l2SharedBridge");

        txHash = bytes32(uint256(uint160(makeAddr("txHash"))));
        l2BatchNumber = uint256(uint160(makeAddr("l2BatchNumber")));
        l2MessageIndex = uint256(uint160(makeAddr("l2MessageIndex")));
        l2TxNumberInBatch = uint16(uint160(makeAddr("l2TxNumberInBatch")));
        merkleProof = new bytes32[](1);
        eraPostUpgradeFirstBatch = 1;

        chainId = 1;
        eraChainId = 9;
        eraDiamondProxy = makeAddr("eraDiamondProxy");
        eraErc20BridgeAddress = makeAddr("eraErc20BridgeAddress");

        bridgeHub = new DummyBridgehub();
        bridgehubAddress = address(bridgeHub);
    
        stm = new DummyStateTransitionManagerWBH(bridgehubAddress);
        stm.setHyperchain(eraChainId, eraDiamondProxy);
        stmAddress = address(stm);
        bridgeHub.setStateTransitionManager(eraChainId, stmAddress);

        token = new TestnetERC20Token("TestnetERC20Token", "TET", 18);
        sharedBridgeImpl = new L1SharedBridge({
            _l1WethAddress: l1WethAddress,
            _bridgehub: IBridgehub(bridgehubAddress),
            _eraChainId: eraChainId,
            _eraDiamondProxy: eraDiamondProxy
        });
        TransparentUpgradeableProxy sharedBridgeProxy = new TransparentUpgradeableProxy(
            address(sharedBridgeImpl),
            proxyAdmin,
            abi.encodeWithSelector(L1SharedBridge.initialize.selector, owner)
        );
        sharedBridge = L1SharedBridge(payable(sharedBridgeProxy));

        l1Erc20Bridge = new L1ERC20Bridge(sharedBridge);
        l1ERC20BridgeAddress = address(l1Erc20Bridge);

        vm.prank(owner);
        sharedBridge.setL1Erc20Bridge(l1ERC20BridgeAddress);
        vm.prank(owner);
        sharedBridge.initializeChainGovernance(chainId, l2SharedBridge);
        assertEq(sharedBridge.l2BridgeAddress(chainId), l2SharedBridge);
        vm.prank(owner);
        sharedBridge.initializeChainGovernance(eraChainId, l2SharedBridge);
        vm.prank(owner);
        sharedBridge.setPendingAdmin(admin);
        vm.prank(admin);
        sharedBridge.acceptAdmin();
    }

    function _setSharedBridgeDepositHappened(uint256 _chainId, bytes32 _txHash, bytes32 _txDataHash) internal {
        stdstore
            .target(address(sharedBridge))
            .sig(sharedBridge.depositHappened.selector)
            .with_key(_chainId)
            .with_key(_txHash)
            .checked_write(_txDataHash);
    }

    function _setSharedBridgeChainBalance(uint256 _chainId, address _token, uint256 _value) internal {
        stdstore
            .target(address(sharedBridge))
            .sig(sharedBridge.chainBalance.selector)
            .with_key(_chainId)
            .with_key(_token)
            .checked_write(_value);
    }
}
