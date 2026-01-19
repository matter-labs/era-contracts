// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IChainAssetHandler} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {MigrationPaused, MigrationsNotPaused, ProtocolIdMismatch, ZeroAddress} from "contracts/common/L1ContractErrors.sol";

/// @notice Mock ChainTypeManager for testing
contract MockChainTypeManager {
    address public immutable BRIDGE_HUB;
    uint256 public protocolVersion;

    constructor(address _bridgehub, uint256 _protocolVersion) {
        BRIDGE_HUB = _bridgehub;
        protocolVersion = _protocolVersion;
    }

    function setProtocolVersion(uint256 _version) external {
        protocolVersion = _version;
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

    uint256 internal constant NEW_PROTOCOL_VERSION = 12345;

    function setUp() public {
        // Create mock chain asset handler
        mockChainAssetHandler = new MockChainAssetHandler();

        // Create mock bridgehub
        mockBridgehub = new MockBridgehub(address(mockChainAssetHandler));

        // Create mock CTM
        mockCTM = new MockChainTypeManager(address(mockBridgehub), NEW_PROTOCOL_VERSION);

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
}
