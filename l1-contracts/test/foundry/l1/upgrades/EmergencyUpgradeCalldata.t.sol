// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {EmergencyUpgradeCalldata} from "deploy-scripts/upgrade/EmergencyUpgradeCalldata.s.sol";
import {IProtocolUpgradeHandler} from "deploy-scripts/interfaces/IProtocolUpgradeHandler.sol";
import {IEmergencyUpgrageBoard} from "deploy-scripts/interfaces/IEmergencyUpgrageBoard.sol";
import {EIP712Utils} from "deploy-scripts/utils/EIP712Utils.sol";
import {
    EXECUTE_EMERGENCY_UPGRADE_GUARDIANS_TYPEHASH,
    EXECUTE_EMERGENCY_UPGRADE_SECURITY_COUNCIL_TYPEHASH,
    EXECUTE_EMERGENCY_UPGRADE_ZK_FOUNDATION_TYPEHASH
} from "deploy-scripts/utils/Utils.sol";

// The governance contracts (ProtocolUpgradeHandler, EmergencyUpgradeBoard, Guardians, SecurityCouncil) and the
// Gnosis Safe live outside this repo, so the tests stand them in with contracts that only expose the getters the
// script reads. The script is only a calldata generator: these tests check what it reads and what it emits, not
// that the board accepts it (that was checked by executing its output on stage).

contract BridgehubStandIn {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }
}

contract ProtocolUpgradeHandlerStandIn {
    address public emergencyUpgradeBoard;
    address public guardians;
    address public securityCouncil;

    constructor(address _emergencyUpgradeBoard, address _guardians, address _securityCouncil) {
        emergencyUpgradeBoard = _emergencyUpgradeBoard;
        guardians = _guardians;
        securityCouncil = _securityCouncil;
    }
}

contract EmergencyUpgradeBoardStandIn {
    address public PROTOCOL_UPGRADE_HANDLER;
    address public GUARDIANS;
    address public SECURITY_COUNCIL;
    address public ZK_FOUNDATION_SAFE;

    function set(address _handler, address _guardians, address _securityCouncil, address _zkFoundationSafe) external {
        PROTOCOL_UPGRADE_HANDLER = _handler;
        GUARDIANS = _guardians;
        SECURITY_COUNCIL = _securityCouncil;
        ZK_FOUNDATION_SAFE = _zkFoundationSafe;
    }
}

contract MultisigStandIn {
    address[] public members;
    uint256 public EIP1271_THRESHOLD;

    constructor(address[] memory _members, uint256 _threshold) {
        members = _members;
        EIP1271_THRESHOLD = _threshold;
    }
}

contract SafeStandIn {
    address[] internal owners;
    uint256 internal threshold;

    constructor(address[] memory _owners, uint256 _threshold) {
        owners = _owners;
        threshold = _threshold;
    }

    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function getThreshold() external view returns (uint256) {
        return threshold;
    }

    /// @dev Any hash that depends on both the Safe and the message is enough to see that the script asks
    /// the right Safe about the right board digest.
    function getMessageHash(bytes memory _message) external view returns (bytes32) {
        return keccak256(abi.encode(address(this), _message));
    }
}

contract EmergencyUpgradeCalldataTest is Test {
    uint256 constant GUARDIANS_MEMBERS = 3;
    uint256 constant GUARDIANS_THRESHOLD = 2;
    uint256 constant COUNCIL_MEMBERS = 4;
    uint256 constant COUNCIL_THRESHOLD = 3;
    /// @dev approveHash on every approving Guardian and Council member and on the ZK Foundation Safe, then execute.
    uint256 constant TX_COUNT = GUARDIANS_THRESHOLD + COUNCIL_THRESHOLD + 2;
    /// @dev `core_contracts.governance_kind` of an env whose bridgehub is owned by a ProtocolUpgradeHandler.
    string constant PUH_GOVERNANCE_KIND = "puh";

    /// @dev Inputs and output of the script, in `script-out/` (git-ignored, writable by scripts). Forge runs the
    /// tests in parallel, so each test names its own files (`_writeInputs`).
    string permanentValues;
    string ecosystemToml;
    string outputJson;

    EmergencyUpgradeCalldata script;
    address owner = makeAddr("owner");
    address stranger = makeAddr("stranger");

    BridgehubStandIn bridgehub;
    ProtocolUpgradeHandlerStandIn handler;
    EmergencyUpgradeBoardStandIn board;
    MultisigStandIn guardians;
    MultisigStandIn council;
    SafeStandIn[] guardianSafes;
    SafeStandIn[] councilSafes;
    SafeStandIn zkFoundationSafe;

    IProtocolUpgradeHandler.Call[] stage0;
    IProtocolUpgradeHandler.Call[] stage1;
    IProtocolUpgradeHandler.Call[] stage2;

    function setUp() public {
        script = new EmergencyUpgradeCalldata();

        for (uint256 i = 0; i < GUARDIANS_MEMBERS; ++i) {
            guardianSafes.push(_safeOf(owner));
        }
        for (uint256 i = 0; i < COUNCIL_MEMBERS - 1; ++i) {
            councilSafes.push(_safeOf(owner));
        }
        // The last Council member is past the threshold, so it never approves and need not be the owner's.
        councilSafes.push(_safeOf(stranger));
        zkFoundationSafe = _safeOf(owner);

        guardians = new MultisigStandIn(_addresses(guardianSafes), GUARDIANS_THRESHOLD);
        council = new MultisigStandIn(_addresses(councilSafes), COUNCIL_THRESHOLD);
        board = new EmergencyUpgradeBoardStandIn();
        handler = new ProtocolUpgradeHandlerStandIn(address(board), address(guardians), address(council));
        board.set(address(handler), address(guardians), address(council), address(zkFoundationSafe));
        bridgehub = new BridgehubStandIn(address(handler));

        // Every stage has its own calls, so a stage that goes missing from the proposal shows.
        stage0.push(IProtocolUpgradeHandler.Call({target: makeAddr("upgradeTimer"), value: 0, data: hex"01"}));
        stage1.push(IProtocolUpgradeHandler.Call({target: makeAddr("ctm"), value: 0, data: hex"0203"}));
        stage1.push(IProtocolUpgradeHandler.Call({target: makeAddr("bridgehub2"), value: 0, data: hex""}));
        stage2.push(IProtocolUpgradeHandler.Call({target: makeAddr("assetRouter"), value: 0, data: hex"04"}));
    }

    /// The whole proposal: one approveHash per approving Safe (the first `EIP1271_THRESHOLD` members of each
    /// multisig, then the ZK Foundation Safe), each of the board digest for that role, and last the execute call
    /// with the calls of all three stages and an approved-hash marker of the owner per approving Safe.
    function test_emergencyUpgradeAllStagesWritesTheWholeProposal() public {
        _writeInputs("whole-proposal", PUH_GOVERNANCE_KIND);
        script.emergencyUpgradeAllStages(permanentValues, ecosystemToml, outputJson);
        string memory json = vm.readFile(string.concat(vm.projectRoot(), outputJson));
        vm.removeFile(string.concat(vm.projectRoot(), outputJson));
        _removeInputs();

        assertEq(vm.parseJsonAddress(json, ".emergency_upgrade_board"), address(board));
        assertEq(vm.parseJsonAddress(json, ".protocol_upgrade_handler"), address(handler));
        assertEq(vm.parseJsonAddress(json, ".owner"), owner);
        assertEq(vm.parseJsonUint(json, ".chain_id"), block.chainid);
        assertTrue(vm.keyExistsJson(json, string.concat(".transactions[", vm.toString(TX_COUNT - 1), "]")));
        assertFalse(vm.keyExistsJson(json, string.concat(".transactions[", vm.toString(TX_COUNT), "]")));

        IProtocolUpgradeHandler.Call[] memory calls = _allCalls();
        bytes32 id = keccak256(
            abi.encode(IProtocolUpgradeHandler.UpgradeProposal({calls: calls, executor: address(board), salt: 0}))
        );
        for (uint256 i = 0; i < GUARDIANS_THRESHOLD; ++i) {
            _assertApproveHash(
                json,
                i,
                string.concat("GUARDIANS ", vm.toString(i + 1)),
                guardianSafes[i],
                EXECUTE_EMERGENCY_UPGRADE_GUARDIANS_TYPEHASH,
                id
            );
        }
        for (uint256 i = 0; i < COUNCIL_THRESHOLD; ++i) {
            _assertApproveHash(
                json,
                GUARDIANS_THRESHOLD + i,
                string.concat("SECURITY_COUNCIL ", vm.toString(i + 1)),
                councilSafes[i],
                EXECUTE_EMERGENCY_UPGRADE_SECURITY_COUNCIL_TYPEHASH,
                id
            );
        }
        _assertApproveHash(
            json,
            TX_COUNT - 2,
            "ZK_FOUNDATION",
            zkFoundationSafe,
            EXECUTE_EMERGENCY_UPGRADE_ZK_FOUNDATION_TYPEHASH,
            id
        );

        bytes memory marker = abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));
        bytes memory expectedExecute = abi.encodeCall(
            IEmergencyUpgrageBoard.executeEmergencyUpgrade,
            (
                calls,
                bytes32(0),
                abi.encode(_first(guardianSafes, GUARDIANS_THRESHOLD), _copies(marker, GUARDIANS_THRESHOLD)),
                abi.encode(_first(councilSafes, COUNCIL_THRESHOLD), _copies(marker, COUNCIL_THRESHOLD)),
                marker
            )
        );
        _assertTx(json, TX_COUNT - 1, "EXECUTE", address(board), expectedExecute);
    }

    function test_revertWhen_envIsNotGovernedByAHandler() public {
        _writeInputs("not-puh", "governance");
        vm.expectRevert(bytes("env is not governed by a ProtocolUpgradeHandler"));
        script.emergencyUpgradeAllStages(permanentValues, ecosystemToml, outputJson);
        _removeInputs();
    }

    function test_revertWhen_boardServesAnotherHandler() public {
        board.set(stranger, address(guardians), address(council), address(zkFoundationSafe));
        _expectAllStagesRevert("other-handler", bytes("board serves another handler"));
    }

    function test_revertWhen_boardNamesOtherGuardians() public {
        board.set(address(handler), stranger, address(council), address(zkFoundationSafe));
        _expectAllStagesRevert("other-guardians", bytes("board and handler name different Guardians"));
    }

    function test_revertWhen_boardNamesAnotherSecurityCouncil() public {
        board.set(address(handler), address(guardians), stranger, address(zkFoundationSafe));
        _expectAllStagesRevert("other-council", bytes("board and handler name different Security Councils"));
    }

    /// The script is written for Safes whose only owner is the owner, and refuses any other Safe among the
    /// approving ones rather than emit calldata for a setup it doesn't know.
    function test_revertWhen_anApprovingSafeHasTwoOwners() public {
        address[] memory owners = new address[](2);
        owners[0] = owner;
        owners[1] = stranger;
        _replaceGuardian(1, new SafeStandIn(owners, 1));
        _expectAllStagesRevert("two-owners", _notOneOfOne(address(guardianSafes[1])));
    }

    function test_revertWhen_anApprovingSafeNeedsTwoSignatures() public {
        address[] memory owners = new address[](1);
        owners[0] = owner;
        _replaceGuardian(0, new SafeStandIn(owners, 2));
        _expectAllStagesRevert("threshold-two", _notOneOfOne(address(guardianSafes[0])));
    }

    function test_revertWhen_anApprovingCouncilSafeHasAnotherOwner() public {
        _replaceCouncilMember(COUNCIL_THRESHOLD - 1, _safeOf(stranger));
        _expectAllStagesRevert("other-owner", _notOneOfOne(address(councilSafes[COUNCIL_THRESHOLD - 1])));
    }

    /// The owner is read off the ZK Foundation Safe, so a second owner there must not slip through either.
    function test_revertWhen_zkFoundationSafeHasTwoOwners() public {
        address[] memory owners = new address[](2);
        owners[0] = owner;
        owners[1] = stranger;
        zkFoundationSafe = new SafeStandIn(owners, 1);
        board.set(address(handler), address(guardians), address(council), address(zkFoundationSafe));
        _expectAllStagesRevert("zk-foundation", _notOneOfOne(address(zkFoundationSafe)));
    }

    /// `printEmergencyBoard` builds nothing, but checks the same Safes before anyone prepares a proposal. It
    /// checks the Guardians, then the Council, then the ZK Foundation Safe, so they are broken in reverse order
    /// to hit each check.
    function test_printEmergencyBoardChecksTheApprovingSafes() public {
        _writeInputs("print", PUH_GOVERNANCE_KIND);
        script.printEmergencyBoard(permanentValues);

        address[] memory owners = new address[](2);
        owners[0] = owner;
        owners[1] = stranger;
        zkFoundationSafe = new SafeStandIn(owners, 1);
        board.set(address(handler), address(guardians), address(council), address(zkFoundationSafe));
        vm.expectRevert(_notOneOfOne(address(zkFoundationSafe)));
        script.printEmergencyBoard(permanentValues);

        _replaceCouncilMember(0, _safeOf(stranger));
        _writeInputs("print", PUH_GOVERNANCE_KIND);
        vm.expectRevert(_notOneOfOne(address(councilSafes[0])));
        script.printEmergencyBoard(permanentValues);

        _replaceGuardian(GUARDIANS_THRESHOLD - 1, _safeOf(stranger));
        _writeInputs("print", PUH_GOVERNANCE_KIND);
        vm.expectRevert(_notOneOfOne(address(guardianSafes[GUARDIANS_THRESHOLD - 1])));
        script.printEmergencyBoard(permanentValues);
        _removeInputs();
    }

    function _assertApproveHash(
        string memory _json,
        uint256 _index,
        string memory _label,
        SafeStandIn _safe,
        bytes32 _typehash,
        bytes32 _id
    ) internal view {
        bytes32 domain = EIP712Utils.buildDomainHash(address(board), "EmergencyUpgradeBoard", "1");
        bytes32 boardDigest = EIP712Utils.buildDigest(domain, keccak256(abi.encode(_typehash, _id)));
        bytes memory expected = abi.encodeWithSignature(
            "approveHash(bytes32)",
            _safe.getMessageHash(abi.encode(boardDigest))
        );
        _assertTx(_json, _index, _label, address(_safe), expected);
    }

    function _assertTx(
        string memory _json,
        uint256 _index,
        string memory _label,
        address _to,
        bytes memory _data
    ) internal view {
        string memory prefix = string.concat(".transactions[", vm.toString(_index), "]");
        assertEq(vm.parseJsonUint(_json, string.concat(prefix, ".step")), _index + 1);
        assertEq(vm.parseJsonString(_json, string.concat(prefix, ".label")), _label);
        assertEq(vm.parseJsonAddress(_json, string.concat(prefix, ".from")), owner);
        assertEq(vm.parseJsonAddress(_json, string.concat(prefix, ".to")), _to);
        assertEq(vm.parseJsonBytes(_json, string.concat(prefix, ".data")), _data);
    }

    function _expectAllStagesRevert(string memory _test, bytes memory _reason) internal {
        _writeInputs(_test, PUH_GOVERNANCE_KIND);
        vm.expectRevert(_reason);
        script.emergencyUpgradeAllStages(permanentValues, ecosystemToml, outputJson);
        _removeInputs();
    }

    function _notOneOfOne(address _safe) internal pure returns (bytes memory) {
        return bytes(string.concat("not a 1-of-1 Safe of the owner: ", vm.toString(_safe)));
    }

    function _replaceGuardian(uint256 _index, SafeStandIn _safe) internal {
        guardianSafes[_index] = _safe;
        guardians = new MultisigStandIn(_addresses(guardianSafes), GUARDIANS_THRESHOLD);
        _rewire();
    }

    function _replaceCouncilMember(uint256 _index, SafeStandIn _safe) internal {
        councilSafes[_index] = _safe;
        council = new MultisigStandIn(_addresses(councilSafes), COUNCIL_THRESHOLD);
        _rewire();
    }

    /// @dev Points the handler, the board and the bridgehub at the current multisigs.
    function _rewire() internal {
        handler = new ProtocolUpgradeHandlerStandIn(address(board), address(guardians), address(council));
        board.set(address(handler), address(guardians), address(council), address(zkFoundationSafe));
        bridgehub = new BridgehubStandIn(address(handler));
    }

    /// @dev The env's permanent values (naming `bridgehub`) and an ecosystem.toml with `stage0`, `stage1` and
    /// `stage2`, in files named after `_test`.
    function _writeInputs(string memory _test, string memory _governanceKind) internal {
        string memory prefix = string.concat("/script-out/emergency-board-test-", _test);
        permanentValues = string.concat(prefix, "-permanent-values.toml");
        ecosystemToml = string.concat(prefix, "-ecosystem.toml");
        outputJson = string.concat(prefix, "-output.json");
        vm.writeFile(
            string.concat(vm.projectRoot(), permanentValues),
            string.concat(
                "[core_contracts]\n",
                'governance_kind = "',
                _governanceKind,
                '"\nbridgehub_proxy_addr = "',
                vm.toString(address(bridgehub)),
                '"\n'
            )
        );
        vm.writeFile(
            string.concat(vm.projectRoot(), ecosystemToml),
            string.concat(
                "[governance_calls]\n",
                'stage0_calls = "',
                vm.toString(abi.encode(stage0)),
                '"\nstage1_calls = "',
                vm.toString(abi.encode(stage1)),
                '"\nstage2_calls = "',
                vm.toString(abi.encode(stage2)),
                '"\n'
            )
        );
    }

    function _removeInputs() internal {
        vm.removeFile(string.concat(vm.projectRoot(), permanentValues));
        vm.removeFile(string.concat(vm.projectRoot(), ecosystemToml));
    }

    function _safeOf(address _owner) internal returns (SafeStandIn) {
        address[] memory owners = new address[](1);
        owners[0] = _owner;
        return new SafeStandIn(owners, 1);
    }

    /// @dev Stages 0, 1 and 2 back to back.
    function _allCalls() internal view returns (IProtocolUpgradeHandler.Call[] memory calls) {
        calls = new IProtocolUpgradeHandler.Call[](stage0.length + stage1.length + stage2.length);
        uint256 next = 0;
        for (uint256 i = 0; i < stage0.length; ++i) {
            calls[next++] = stage0[i];
        }
        for (uint256 i = 0; i < stage1.length; ++i) {
            calls[next++] = stage1[i];
        }
        for (uint256 i = 0; i < stage2.length; ++i) {
            calls[next++] = stage2[i];
        }
    }

    function _addresses(SafeStandIn[] storage _safes) internal view returns (address[] memory) {
        return _first(_safes, _safes.length);
    }

    function _first(SafeStandIn[] storage _safes, uint256 _count) internal view returns (address[] memory first) {
        first = new address[](_count);
        for (uint256 i = 0; i < _count; ++i) {
            first[i] = address(_safes[i]);
        }
    }

    function _copies(bytes memory _value, uint256 _count) internal pure returns (bytes[] memory copies) {
        copies = new bytes[](_count);
        for (uint256 i = 0; i < _count; ++i) {
            copies[i] = _value;
        }
    }
}
