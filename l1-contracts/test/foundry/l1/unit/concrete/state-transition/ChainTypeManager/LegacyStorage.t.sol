// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";

/// @notice Stands in for the pre-v35 CTM implementation a live proxy runs before the bootstrap
///         swaps it: it writes the two pre-v35 fields the registry model only keeps, exactly as
///         `setProtocolVersionVerifier` / `setDefaultUpgrade` of `draft/v0.34.0` did.
/// @dev The pre-v35 implementation is not part of this build, so the stand-in writes through the
///      declarations the current implementation retains. That they sit where the v34 layout put
///      them is what the slot assertions of {ChainTypeManagerLegacyStorageTest} pin.
contract PreV35ChainTypeManagerStandIn is ChainTypeManager {
    constructor(
        address _bridgehub,
        address _interopCenter,
        address _l1BytecodesSupplier,
        address _permissionlessValidator,
        address _l1InteropFeeManager
    )
        ChainTypeManager(
            _bridgehub,
            _interopCenter,
            _l1BytecodesSupplier,
            _permissionlessValidator,
            _l1InteropFeeManager
        )
    {}

    /// @param _protocolVersion The version the verifier is recorded for.
    /// @param _verifier The verifier recorded.
    function setProtocolVersionVerifier(uint256 _protocolVersion, address _verifier) external onlyOwner {
        __LEGACY_protocolVersionVerifier[_protocolVersion] = _verifier;
    }

    /// @param _defaultUpgrade The verifier-only upgrade engine recorded.
    function setDefaultUpgrade(address _defaultUpgrade) external onlyOwner {
        __DEPRECATED_defaultUpgrade = _defaultUpgrade;
    }
}

/// @notice The storage a v35 CTM inherits from the pre-v35 implementation it replaces in place:
///         every v34 slot keeps its meaning, the registry fields take FRESH slots after them, and
///         the one v34 value deployed upgrade engines still read is still served.
/// @dev Slot numbers are the `forge inspect ... storageLayout` of `ChainTypeManager` on
///      `draft/v0.34.0`: `protocolVersionVerifier` at 168 and `defaultUpgrade` at 169, the last
///      v34 slot.
contract ChainTypeManagerLegacyStorageTest is ChainTypeManagerTest {
    uint256 internal constant V34_PROTOCOL_VERSION_VERIFIER_SLOT = 168;
    uint256 internal constant V34_DEFAULT_UPGRADE_SLOT = 169;
    uint256 internal constant CURRENT_RELEASE_SLOT = 170;
    uint256 internal constant UPGRADE_TRANSITION_SLOT = 171;

    uint256 internal constant LEGACY_VERSION = uint256(34) << 32;
    uint256 internal constant NEW_VERSION = uint256(1) << 32;

    PreV35ChainTypeManagerStandIn internal preV35Implementation;

    function setUp() public {
        deploy();
        preV35Implementation = new PreV35ChainTypeManagerStandIn(
            address(bridgehub),
            interopCenterAddress,
            address(bytecodesSupplier),
            address(0),
            address(0)
        );
    }

    function _swapImplementation(address _implementation) internal {
        vm.prank(admin);
        ITransparentUpgradeableProxy(address(chainContractAddress)).upgradeTo(_implementation);
    }

    /// @dev Runs the pre-v35 writes on the live proxy, then swaps it to the registry-model
    ///      implementation — the order the bootstrap's `migrate()` performs the swap in.
    function _writePreV35StateThenSwap(address _verifier, address _defaultUpgrade) internal {
        _swapImplementation(address(preV35Implementation));
        vm.startPrank(governor);
        PreV35ChainTypeManagerStandIn(address(chainContractAddress)).setProtocolVersionVerifier(
            LEGACY_VERSION,
            _verifier
        );
        PreV35ChainTypeManagerStandIn(address(chainContractAddress)).setDefaultUpgrade(_defaultUpgrade);
        vm.stopPrank();
        _swapImplementation(address(chainTypeManager));
    }

    /// @dev Deployed pre-v35 upgrade engines read `protocolVersionVerifier(newVersion)` off the CTM
    ///      when a lagging chain crosses a legacy edge after the bootstrap, so the value the
    ///      pre-v35 implementation recorded must still be served by the v35 one.
    function test_verifierRecordedBeforeTheSwapIsServedAfterIt() public {
        address legacyVerifier = makeAddr("legacyVerifier");
        _writePreV35StateThenSwap(legacyVerifier, makeAddr("legacyDefaultUpgrade"));

        assertEq(
            chainContractAddress.protocolVersionVerifier(LEGACY_VERSION),
            legacyVerifier,
            "the pre-v35 verifier is served after the swap"
        );
        assertEq(
            vm.load(
                address(chainContractAddress),
                keccak256(abi.encode(LEGACY_VERSION, V34_PROTOCOL_VERSION_VERIFIER_SLOT))
            ),
            bytes32(uint256(uint160(legacyVerifier))),
            "the getter reads the v34 `protocolVersionVerifier` mapping"
        );
        assertEq(
            chainContractAddress.protocolVersionVerifier(NEW_VERSION),
            address(0),
            "the registry model records no verifier per version"
        );
    }

    /// @dev A v34 CTM carries a nonzero `defaultUpgrade`. Were `currentRelease` declared in its
    ///      slot, that address would read back as the release between the bootstrap's swap and
    ///      its commit — and after any rollback of the implementation.
    function test_theV34DefaultUpgradeSlotIsNotTheCurrentRelease() public {
        address legacyDefaultUpgrade = makeAddr("legacyDefaultUpgrade");
        _writePreV35StateThenSwap(makeAddr("legacyVerifier"), legacyDefaultUpgrade);

        assertEq(chainContractAddress.currentRelease(), Utils.TEST_GENESIS_REGISTRY, "the release is unaffected");
        assertEq(
            vm.load(address(chainContractAddress), bytes32(V34_DEFAULT_UPGRADE_SLOT)),
            bytes32(uint256(uint160(legacyDefaultUpgrade))),
            "the v34 value stays in its own slot"
        );
        assertEq(
            vm.load(address(chainContractAddress), bytes32(CURRENT_RELEASE_SLOT)),
            bytes32(uint256(uint160(Utils.TEST_GENESIS_REGISTRY))),
            "currentRelease sits in the first slot past the v34 layout"
        );
    }

    /// @dev Pins the registry fields' slots, so a declaration added above them fails here rather
    ///      than on a live CTM.
    function test_registryFieldsSitPastTheV34Layout() public {
        address newRelease = _releaseAt(NEW_VERSION);
        ICTMTransition transition = ICTMTransition(makeAddr("transition"));
        vm.etch(address(transition), hex"00");
        vm.mockCall(
            address(transition),
            abi.encodeCall(ICTMTransition.fromRelease, ()),
            abi.encode(Utils.TEST_GENESIS_REGISTRY)
        );
        vm.mockCall(address(transition), abi.encodeCall(ICTMTransition.oldProtocolVersion, ()), abi.encode(0));
        vm.mockCall(
            address(transition),
            abi.encodeCall(ICTMTransition.newProtocolVersion, ()),
            abi.encode(NEW_VERSION)
        );
        vm.mockCall(address(transition), abi.encodeCall(ICTMTransition.newRelease, ()), abi.encode(newRelease));
        vm.mockCall(
            address(transition),
            abi.encodeCall(ICTMTransition.upgradeEngine, ()),
            abi.encode(makeAddr("upgradeEngine"))
        );

        vm.prank(governor);
        chainContractAddress.setNewVersionUpgradeFromTransition(transition);

        assertEq(
            vm.load(address(chainContractAddress), bytes32(CURRENT_RELEASE_SLOT)),
            bytes32(uint256(uint160(newRelease))),
            "currentRelease slot"
        );
        assertEq(
            vm.load(address(chainContractAddress), keccak256(abi.encode(uint256(0), UPGRADE_TRANSITION_SLOT))),
            bytes32(uint256(uint160(address(transition)))),
            "upgradeTransition slot"
        );
        assertEq(
            vm.load(address(chainContractAddress), bytes32(V34_DEFAULT_UPGRADE_SLOT)),
            bytes32(0),
            "the registry model never writes the v34 defaultUpgrade slot"
        );
    }
}
