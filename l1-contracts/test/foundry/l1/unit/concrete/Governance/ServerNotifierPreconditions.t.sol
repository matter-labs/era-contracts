// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {IServerNotifier} from "contracts/governance/IServerNotifier.sol";
import {DummyChainTypeManager} from "contracts/dev-contracts/test/DummyChainTypeManagerForServerNotifier.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IUpgradePreconditionChecker} from "contracts/upgrades/IUpgradePreconditionChecker.sol";
import {V32UpgradePreconditionChecker} from "contracts/upgrades/V32UpgradePreconditionChecker.sol";
import {PriorityOpLowerBound} from "contracts/upgrades/PriorityOpLowerBound.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {
    BaseTokenPreV31TotalSupplyNotSet,
    CutDataForProtocolVersionNotAvailable,
    LowerBoundNotRecorded,
    PriorityQueueNotReady,
    UpgradePreconditionCheckerMagicMismatch
} from "contracts/common/L1ContractErrors.sol";

/// @dev Checker stub with an invalid magic value.
contract WrongMagicChecker {
    function getSupportsUpgradePreconditionCheckerMagic() external pure returns (bytes32) {
        return keccak256("NotAnUpgradePreconditionChecker");
    }
}

/// @notice Tests ServerNotifier checker registration and scheduling.
/// @dev Chain getters are mocked to isolate notifier-to-checker behavior; the checker and registry are real.
contract ServerNotifierPreconditionsTest is Test {
    ServerNotifier internal serverNotifier;
    DummyChainTypeManager internal chainTypeManager;
    V32UpgradePreconditionChecker internal checker;
    PriorityOpLowerBound internal registry;

    address internal owner;
    address internal chainAdmin;
    address internal chain;
    uint256 internal chainId;
    uint256 internal protocolVersion;

    uint256 internal constant TOTAL_PRIORITY_TXS_AT_RECORD_TIME = 7;

    function setUp() public {
        chainId = 1;
        protocolVersion = 42;
        owner = makeAddr("owner");
        chainAdmin = makeAddr("chainAdmin");
        chain = makeAddr("chainDiamond");

        chainTypeManager = new DummyChainTypeManager();
        chainTypeManager.setChainAdmin(chainId, chainAdmin);
        chainTypeManager._setChainProtocolVersion(chainId, protocolVersion);
        chainTypeManager.setZKChain(chainId, chain);
        chainTypeManager.setUpgradeCutHash(protocolVersion, keccak256("upgradeCutHash"));

        ServerNotifier implementation = new ServerNotifier();
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            abi.encodeWithSelector(ServerNotifier.initialize.selector, owner)
        );
        serverNotifier = ServerNotifier(address(proxy));
        vm.prank(owner);
        serverNotifier.setChainTypeManager(IChainTypeManager(address(chainTypeManager)));

        registry = new PriorityOpLowerBound();
        checker = new V32UpgradePreconditionChecker(registry);

        _mockBackfilled(true);
        vm.mockCall(
            chain,
            abi.encodeWithSelector(IGetters.getTotalPriorityTxs.selector),
            abi.encode(TOTAL_PRIORITY_TXS_AT_RECORD_TIME)
        );
        registry.lowerBoundPriorityOp(chain);
        _mockFirstUnprocessedPriorityTx(TOTAL_PRIORITY_TXS_AT_RECORD_TIME);
    }

    function _mockBackfilled(bool _v) internal {
        vm.mockCall(chain, abi.encodeWithSelector(IGetters.baseTokenSupportsTotalSupply.selector), abi.encode(_v));
    }

    function _mockFirstUnprocessedPriorityTx(uint256 _value) internal {
        vm.mockCall(chain, abi.encodeWithSelector(IGetters.getFirstUnprocessedPriorityTx.selector), abi.encode(_value));
    }

    function _registerChecker() internal {
        vm.prank(owner);
        serverNotifier.setUpgradePreconditionChecker(protocolVersion, checker);
    }

    /*//////////////////////////////////////////////////////////////
                        setUpgradePreconditionChecker
    //////////////////////////////////////////////////////////////*/

    function test_setCheckerRegistersAndEmits() public {
        vm.expectEmit(true, false, false, true, address(serverNotifier));
        emit IServerNotifier.UpgradePreconditionCheckerSet(protocolVersion, address(checker));

        vm.prank(owner);
        serverNotifier.setUpgradePreconditionChecker(protocolVersion, checker);

        assertEq(address(serverNotifier.upgradePreconditionChecker(protocolVersion)), address(checker));
    }

    function test_setCheckerCanDeregister() public {
        _registerChecker();

        vm.expectEmit(true, false, false, true, address(serverNotifier));
        emit IServerNotifier.UpgradePreconditionCheckerSet(protocolVersion, address(0));

        vm.prank(owner);
        serverNotifier.setUpgradePreconditionChecker(protocolVersion, IUpgradePreconditionChecker(address(0)));

        assertEq(address(serverNotifier.upgradePreconditionChecker(protocolVersion)), address(0));

        uint256 deadline = block.timestamp + 7 days;
        _mockBackfilled(false);
        vm.prank(chainAdmin);
        serverNotifier.setUpgradeTimestamp(chainId, deadline);

        assertEq(serverNotifier.protocolVersionToUpgradeTimestamp(chainId, protocolVersion), deadline);
    }

    function test_setCheckerRevertsIfNotOwner() public {
        vm.prank(chainAdmin);
        vm.expectRevert("Ownable: caller is not the owner");
        serverNotifier.setUpgradePreconditionChecker(protocolVersion, checker);
    }

    function test_setCheckerRevertsOnWrongMagic() public {
        WrongMagicChecker wrongMagic = new WrongMagicChecker();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UpgradePreconditionCheckerMagicMismatch.selector, address(wrongMagic)));
        serverNotifier.setUpgradePreconditionChecker(protocolVersion, IUpgradePreconditionChecker(address(wrongMagic)));
    }

    function test_setCheckerRevertsOnContractWithoutMagicGetter() public {
        vm.prank(owner);
        vm.expectRevert();
        serverNotifier.setUpgradePreconditionChecker(
            protocolVersion,
            IUpgradePreconditionChecker(address(chainTypeManager))
        );
    }

    /*//////////////////////////////////////////////////////////////
                    setUpgradeTimestamp with a checker
    //////////////////////////////////////////////////////////////*/

    function test_setUpgradeTimestampPassesWhenPreconditionsHold() public {
        _registerChecker();
        uint256 deadline = block.timestamp + 7 days;

        vm.expectEmit(true, true, true, true, address(serverNotifier));
        emit IServerNotifier.UpgradeTimestampUpdated(chainId, protocolVersion, deadline);

        vm.prank(chainAdmin);
        serverNotifier.setUpgradeTimestamp(chainId, deadline);

        assertEq(serverNotifier.protocolVersionToUpgradeTimestamp(chainId, protocolVersion), deadline);
    }

    function test_setUpgradeTimestampRevertsWhenBaseTokenNotBackfilled() public {
        _registerChecker();
        _mockBackfilled(false);

        vm.prank(chainAdmin);
        vm.expectRevert(BaseTokenPreV31TotalSupplyNotSet.selector);
        serverNotifier.setUpgradeTimestamp(chainId, block.timestamp + 7 days);

        assertEq(
            serverNotifier.protocolVersionToUpgradeTimestamp(chainId, protocolVersion),
            0,
            "no timestamp may be recorded when scheduling reverts"
        );
    }

    function test_setUpgradeTimestampRevertsWhenLowerBoundNotRecorded() public {
        registry = new PriorityOpLowerBound();
        checker = new V32UpgradePreconditionChecker(registry);
        _registerChecker();

        vm.prank(chainAdmin);
        vm.expectRevert(LowerBoundNotRecorded.selector);
        serverNotifier.setUpgradeTimestamp(chainId, block.timestamp + 7 days);

        assertEq(serverNotifier.protocolVersionToUpgradeTimestamp(chainId, protocolVersion), 0);
    }

    function test_setUpgradeTimestampRevertsWhenPriorityQueueNotReady() public {
        _registerChecker();
        _mockFirstUnprocessedPriorityTx(TOTAL_PRIORITY_TXS_AT_RECORD_TIME - 1);

        vm.prank(chainAdmin);
        vm.expectRevert(PriorityQueueNotReady.selector);
        serverNotifier.setUpgradeTimestamp(chainId, block.timestamp + 7 days);

        assertEq(serverNotifier.protocolVersionToUpgradeTimestamp(chainId, protocolVersion), 0);
    }

    function test_checkerForOtherVersionDoesNotAffectScheduling() public {
        vm.prank(owner);
        serverNotifier.setUpgradePreconditionChecker(protocolVersion + 1, checker);
        _mockBackfilled(false);

        uint256 deadline = block.timestamp + 7 days;
        vm.prank(chainAdmin);
        serverNotifier.setUpgradeTimestamp(chainId, deadline);

        assertEq(serverNotifier.protocolVersionToUpgradeTimestamp(chainId, protocolVersion), deadline);
    }

    /*//////////////////////////////////////////////////////////////
                        previewUpgradePreconditions
    //////////////////////////////////////////////////////////////*/

    function test_previewReportsMissingCutData() public {
        chainTypeManager.setUpgradeCutHash(protocolVersion, bytes32(0));

        bytes4[] memory failed = serverNotifier.previewUpgradePreconditions(chainId);
        assertEq(failed.length, 1);
        assertEq(failed[0], CutDataForProtocolVersionNotAvailable.selector);
    }

    function test_previewEmptyWithoutChecker() public view {
        assertEq(serverNotifier.previewUpgradePreconditions(chainId).length, 0);
    }

    function test_previewEmptyWhenPreconditionsHold() public {
        _registerChecker();
        assertEq(serverNotifier.previewUpgradePreconditions(chainId).length, 0);
    }

    function test_previewReportsFailedPrecondition() public {
        _registerChecker();
        _mockBackfilled(false);

        bytes4[] memory failed = serverNotifier.previewUpgradePreconditions(chainId);
        assertEq(failed.length, 1);
        assertEq(failed[0], BaseTokenPreV31TotalSupplyNotSet.selector);
    }
}

/// @notice Guards ServerNotifier's proxy storage layout against reordering.
contract ServerNotifierStorageLayoutTest is Test {
    /// @dev `Ownable._owner`.
    uint256 internal constant OWNER_SLOT = 0;
    /// @dev `_pendingOwner`, packed with `_initialized` and `_initializing`.
    uint256 internal constant PENDING_OWNER_SLOT = 1;
    /// @dev `chainTypeManager`.
    uint256 internal constant CHAIN_TYPE_MANAGER_SLOT = 2;
    /// @dev `protocolVersionToUpgradeTimestamp` mapping base slot.
    uint256 internal constant UPGRADE_TIMESTAMP_SLOT = 3;
    /// @dev `upgradePreconditionChecker` mapping base slot.
    uint256 internal constant PRECONDITION_CHECKER_SLOT = 4;

    ServerNotifier internal serverNotifier;
    DummyChainTypeManager internal chainTypeManager;

    address internal owner;
    uint256 internal chainId;
    uint256 internal protocolVersion;

    function setUp() public {
        owner = makeAddr("owner");
        chainId = 1;
        protocolVersion = 42;

        chainTypeManager = new DummyChainTypeManager();
        chainTypeManager.setChainAdmin(chainId, owner);
        chainTypeManager._setChainProtocolVersion(chainId, protocolVersion);
        chainTypeManager.setUpgradeCutHash(protocolVersion, keccak256("upgradeCutHash"));

        ServerNotifier implementation = new ServerNotifier();
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            abi.encodeWithSelector(ServerNotifier.initialize.selector, owner)
        );
        serverNotifier = ServerNotifier(address(proxy));
        vm.prank(owner);
        serverNotifier.setChainTypeManager(IChainTypeManager(address(chainTypeManager)));
    }

    function _load(uint256 _slot) internal view returns (bytes32) {
        return vm.load(address(serverNotifier), bytes32(_slot));
    }

    function test_ownerSlot() public view {
        assertEq(_load(OWNER_SLOT), bytes32(uint256(uint160(owner))));
    }

    function test_pendingOwnerAndInitializedSlot() public {
        address pendingOwner = makeAddr("pendingOwner");
        vm.prank(owner);
        serverNotifier.transferOwnership(pendingOwner);

        // `_pendingOwner` occupies the low 20 bytes; `_initialized = 1` starts at byte 20.
        bytes32 expected = bytes32((uint256(1) << 160) | uint256(uint160(pendingOwner)));
        assertEq(_load(PENDING_OWNER_SLOT), expected);
    }

    function test_chainTypeManagerSlot() public view {
        assertEq(_load(CHAIN_TYPE_MANAGER_SLOT), bytes32(uint256(uint160(address(chainTypeManager)))));
    }

    function test_upgradeTimestampMappingSlot() public {
        uint256 deadline = block.timestamp + 7 days;
        vm.prank(owner);
        serverNotifier.setUpgradeTimestamp(chainId, deadline);

        bytes32 innerSlot = keccak256(abi.encode(chainId, UPGRADE_TIMESTAMP_SLOT));
        bytes32 valueSlot = keccak256(abi.encode(protocolVersion, innerSlot));
        assertEq(uint256(_load(uint256(valueSlot))), deadline);
    }

    function test_preconditionCheckerMappingSlot() public {
        PriorityOpLowerBound registry = new PriorityOpLowerBound();
        V32UpgradePreconditionChecker checker = new V32UpgradePreconditionChecker(registry);
        vm.prank(owner);
        serverNotifier.setUpgradePreconditionChecker(protocolVersion, checker);

        bytes32 valueSlot = keccak256(abi.encode(protocolVersion, PRECONDITION_CHECKER_SLOT));
        assertEq(uint256(_load(uint256(valueSlot))), uint256(uint160(address(checker))));
    }
}
