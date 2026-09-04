// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";
import {IUpgradePreconditionChecker} from "contracts/upgrades/IUpgradePreconditionChecker.sol";

import {
    MigrationPaused,
    MigrationsNotPaused,
    ProtocolIdMismatch,
    UpgradePreconditionCheckerMismatch,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";

/// @notice Mock ChainTypeManager for testing
contract MockChainTypeManager {
    address public immutable BRIDGE_HUB;
    address public immutable serverNotifierAddress;
    uint256 public protocolVersion;

    constructor(address _bridgehub, address _serverNotifier, uint256 _protocolVersion) {
        BRIDGE_HUB = _bridgehub;
        serverNotifierAddress = _serverNotifier;
        protocolVersion = _protocolVersion;
    }

    function setProtocolVersion(uint256 _version) external {
        protocolVersion = _version;
    }
}

contract MockServerNotifier {
    mapping(uint256 _oldProtocolVersion => IUpgradePreconditionChecker checker) public upgradePreconditionChecker;

    function setUpgradePreconditionChecker(uint256 _oldProtocolVersion, IUpgradePreconditionChecker _checker) external {
        upgradePreconditionChecker[_oldProtocolVersion] = _checker;
    }
}

/// @notice Mock ChainAssetHandler for testing
contract MockChainAssetHandler {
    bool public migrationPaused;

    function setMigrationPaused(bool _paused) external {
        migrationPaused = _paused;
    }
}

/// @notice Mock Bridgehub for testing
contract MockBridgehub {
    address public chainAssetHandler;

    constructor(address _chainAssetHandler) {
        chainAssetHandler = _chainAssetHandler;
    }
}

/// @notice Unit tests for UpgradeStageValidator contract
contract UpgradeStageValidatorTest is Test {
    UpgradeStageValidator internal validator;
    MockChainTypeManager internal mockCTM;
    MockBridgehub internal mockBridgehub;
    MockChainAssetHandler internal mockChainAssetHandler;
    MockServerNotifier internal mockServerNotifier;

    uint256 internal constant NEW_PROTOCOL_VERSION = 12345;

    function setUp() public {
        // Create mock chain asset handler
        mockChainAssetHandler = new MockChainAssetHandler();

        // Create mock bridgehub
        mockBridgehub = new MockBridgehub(address(mockChainAssetHandler));

        mockServerNotifier = new MockServerNotifier();

        // Create mock CTM
        mockCTM = new MockChainTypeManager(address(mockBridgehub), address(mockServerNotifier), NEW_PROTOCOL_VERSION);

        // Create validator
        validator = new UpgradeStageValidator(address(mockCTM), NEW_PROTOCOL_VERSION);
    }

    // ============ Constructor Tests ============

    function test_constructor_setsBridgehub() public view {
        assertEq(address(validator.BRIDGEHUB()), address(mockBridgehub));
    }

    function test_constructor_setsChainTypeManager() public view {
        assertEq(address(validator.CHAIN_TYPE_MANAGER()), address(mockCTM));
    }

    function test_constructor_setsNewProtocolVersion() public view {
        assertEq(validator.NEW_PROTOCOL_VERSION(), NEW_PROTOCOL_VERSION);
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(ZeroAddress.selector);
        new UpgradeStageValidator(address(0), NEW_PROTOCOL_VERSION);
    }

    function test_constructor_fuzz(uint256 protocolVersion) public {
        UpgradeStageValidator fuzzValidator = new UpgradeStageValidator(address(mockCTM), protocolVersion);
        assertEq(fuzzValidator.NEW_PROTOCOL_VERSION(), protocolVersion);
    }

    // ============ checkMigrationsPaused Tests ============

    function test_checkMigrationsPaused_succeedsWhenPaused() public {
        mockChainAssetHandler.setMigrationPaused(true);

        // Should not revert
        validator.checkMigrationsPaused();
    }

    function test_checkMigrationsPaused_revertsWhenNotPaused() public {
        mockChainAssetHandler.setMigrationPaused(false);

        vm.expectRevert(MigrationsNotPaused.selector);
        validator.checkMigrationsPaused();
    }

    // ============ checkMigrationsUnpaused Tests ============

    function test_checkMigrationsUnpaused_succeedsWhenUnpaused() public {
        mockChainAssetHandler.setMigrationPaused(false);

        // Should not revert
        validator.checkMigrationsUnpaused();
    }

    function test_checkMigrationsUnpaused_revertsWhenPaused() public {
        mockChainAssetHandler.setMigrationPaused(true);

        vm.expectRevert(MigrationPaused.selector);
        validator.checkMigrationsUnpaused();
    }

    // ============ checkProtocolUpgradePresence Tests ============

    function test_checkProtocolUpgradePresence_succeedsWhenVersionMatches() public {
        // mockCTM is already set to NEW_PROTOCOL_VERSION
        validator.checkProtocolUpgradePresence();
    }

    function test_checkProtocolUpgradePresence_revertsWhenVersionMismatch() public {
        uint256 differentVersion = NEW_PROTOCOL_VERSION + 1;
        mockCTM.setProtocolVersion(differentVersion);

        vm.expectRevert(abi.encodeWithSelector(ProtocolIdMismatch.selector, NEW_PROTOCOL_VERSION, differentVersion));
        validator.checkProtocolUpgradePresence();
    }

    function test_checkProtocolUpgradePresence_fuzz(uint256 actualVersion) public {
        vm.assume(actualVersion != NEW_PROTOCOL_VERSION);
        mockCTM.setProtocolVersion(actualVersion);

        vm.expectRevert(abi.encodeWithSelector(ProtocolIdMismatch.selector, NEW_PROTOCOL_VERSION, actualVersion));
        validator.checkProtocolUpgradePresence();
    }

    function test_checkUpgradePreconditionChecker_succeedsWhenCheckerMatches() public {
        IUpgradePreconditionChecker expectedChecker = IUpgradePreconditionChecker(makeAddr("expected checker"));
        mockServerNotifier.setUpgradePreconditionChecker(NEW_PROTOCOL_VERSION, expectedChecker);

        validator.checkUpgradePreconditionChecker(NEW_PROTOCOL_VERSION, expectedChecker);
    }

    function test_checkUpgradePreconditionChecker_revertsWhenCheckerDoesNotMatch() public {
        IUpgradePreconditionChecker expectedChecker = IUpgradePreconditionChecker(makeAddr("expected checker"));
        IUpgradePreconditionChecker actualChecker = IUpgradePreconditionChecker(makeAddr("actual checker"));
        mockServerNotifier.setUpgradePreconditionChecker(NEW_PROTOCOL_VERSION, actualChecker);

        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradePreconditionCheckerMismatch.selector,
                address(expectedChecker),
                address(actualChecker)
            )
        );
        validator.checkUpgradePreconditionChecker(NEW_PROTOCOL_VERSION, expectedChecker);
    }

    function test_checkUpgradePreconditionChecker_revertsWhenCheckerIsMissing() public {
        IUpgradePreconditionChecker expectedChecker = IUpgradePreconditionChecker(makeAddr("expected checker"));

        vm.expectRevert(
            abi.encodeWithSelector(UpgradePreconditionCheckerMismatch.selector, address(expectedChecker), address(0))
        );
        validator.checkUpgradePreconditionChecker(NEW_PROTOCOL_VERSION, expectedChecker);
    }
}
