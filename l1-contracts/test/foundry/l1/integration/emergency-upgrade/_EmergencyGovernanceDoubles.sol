// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable gas-custom-errors, reason-string

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {EIP712} from "@openzeppelin/contracts-v4/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts-v4/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts-v4/utils/cryptography/SignatureChecker.sol";
import {IERC1271} from "@openzeppelin/contracts-v4/interfaces/IERC1271.sol";
import {Address} from "@openzeppelin/contracts-v4/utils/Address.sol";

import {EmergencyStageUpgradeCalldata} from "deploy-scripts/upgrade/EmergencyStageUpgradeCalldata.s.sol";
import {IEmergencyUpgrageBoard} from "deploy-scripts/interfaces/IEmergencyUpgrageBoard.sol";
import {IProtocolUpgradeHandler} from "deploy-scripts/interfaces/IProtocolUpgradeHandler.sol";
import {ISafe} from "deploy-scripts/interfaces/ISafe.sol";
import {GUARDIANS_SIZE, SECURITY_COUNCIL_SIZE} from "deploy-scripts/utils/Utils.sol";

/*//////////////////////////////////////////////////////////////
    TEST DOUBLES OF THE zk-governance EMERGENCY PATH
//////////////////////////////////////////////////////////////*/

// The ProtocolUpgradeHandler, its EmergencyUpgradeBoard and multisigs live in the zk-governance
// repository, which this one does not vendor. These doubles restate the parts the emergency
// tooling depends on — the board's EIP-712 domain and checks, the multisigs' member-ordered
// EIP-1271 check, a 1-of-1 Safe's message hash and signature rules, and the handler's
// emergency execution — so the digests and calldata the scripts emit are checked against an
// independent statement of them rather than against the scripts' own code.

/// @dev zk-governance `Guardians`: `Multisig(_members, 5)`.
uint256 constant GUARDIANS_EIP1271_THRESHOLD = 5;
/// @dev zk-governance `SecurityCouncil`: `Multisig(_members, 6)`.
uint256 constant SECURITY_COUNCIL_EIP1271_THRESHOLD = 6;
/// @dev zk-governance `SecurityCouncil.APPROVE_UPGRADE_SECURITY_COUNCIL_THRESHOLD`.
uint256 constant SECURITY_COUNCIL_APPROVE_UPGRADE_THRESHOLD = 4;

/// @notice A 1-of-1 Gnosis Safe (v1.3 with the CompatibilityFallbackHandler) as an approving member:
///         `getMessageHash`, `approveHash` and the EIP-1271 check over that message hash, accepting
///         the owner's ECDSA signature or its "approved hash" marker (r = owner, s = 0, v = 1).
contract OneOwnerSafeDouble is IERC1271 {
    bytes32 private constant DOMAIN_SEPARATOR_TYPEHASH =
        keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");
    bytes32 private constant SAFE_MSG_TYPEHASH = keccak256("SafeMessage(bytes message)");
    uint8 private constant APPROVED_HASH_V = 1;
    uint256 private constant SIGNATURE_LENGTH = 65;

    address private immutable OWNER;

    mapping(address owner => mapping(bytes32 hash => uint256 approved)) public approvedHashes;

    constructor(address _owner) {
        OWNER = _owner;
    }

    function getOwners() external view returns (address[] memory owners) {
        owners = new address[](1);
        owners[0] = OWNER;
    }

    function getThreshold() external pure returns (uint256) {
        return 1;
    }

    function approveHash(bytes32 _hashToApprove) external {
        require(msg.sender == OWNER, "GS030");
        approvedHashes[msg.sender][_hashToApprove] = 1;
    }

    function getMessageHash(bytes memory _message) public view returns (bytes32) {
        bytes32 domainSeparator = keccak256(abi.encode(DOMAIN_SEPARATOR_TYPEHASH, block.chainid, address(this)));
        bytes32 safeMessageHash = keccak256(abi.encode(SAFE_MSG_TYPEHASH, keccak256(_message)));
        return keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), domainSeparator, safeMessageHash));
    }

    function isValidSignature(bytes32 _dataHash, bytes memory _signature) external view override returns (bytes4) {
        bytes32 messageHash = getMessageHash(abi.encode(_dataHash));
        require(_signature.length == SIGNATURE_LENGTH, "GS020");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(_signature, 0x20))
            s := mload(add(_signature, 0x40))
            v := byte(0, mload(add(_signature, 0x60)))
        }
        address signer;
        if (v == APPROVED_HASH_V) {
            signer = address(uint160(uint256(r)));
            require(approvedHashes[signer][messageHash] != 0, "GS025");
        } else {
            signer = ECDSA.recover(messageHash, v, r, s);
        }
        require(signer == OWNER, "GS026");
        return IERC1271.isValidSignature.selector;
    }
}

/// @notice zk-governance `Multisig`: sorted members, and an EIP-1271 check that takes
///         `abi.encode(signers, signatures)` with at least `EIP1271_THRESHOLD` valid signatures
///         from distinct members in member order.
contract MultisigDouble is IERC1271 {
    address[] public members;
    uint256 public immutable EIP1271_THRESHOLD;

    constructor(address[] memory _members, uint256 _eip1271Threshold) {
        require(_eip1271Threshold > 0 && _eip1271Threshold <= _members.length, "bad threshold");
        EIP1271_THRESHOLD = _eip1271Threshold;
        address lastAddress;
        for (uint256 i = 0; i < _members.length; ++i) {
            require(lastAddress < _members[i], "Members not sorted or duplicate found");
            members.push(_members[i]);
            lastAddress = _members[i];
        }
    }

    function checkSignatures(
        bytes32 _digest,
        address[] memory _signers,
        bytes[] memory _signatures,
        uint256 _threshold
    ) public view {
        require(_signatures.length >= _threshold, "Insufficient valid signatures");
        require(_signers.length == _signatures.length, "Inconsistent signers/signatures length");
        uint256 currentMember;
        for (uint256 i = 0; i < _signatures.length; ++i) {
            require(
                SignatureChecker.isValidSignatureNow(_signers[i], _digest, _signatures[i]),
                "Signature verification failed"
            );
            while (members[currentMember] != _signers[i]) {
                ++currentMember;
            }
            ++currentMember;
        }
    }

    function isValidSignature(bytes32 _digest, bytes memory _signature) external view override returns (bytes4) {
        (address[] memory signers, bytes[] memory signatures) = abi.decode(_signature, (address[], bytes[]));
        checkSignatures(_digest, signers, signatures, EIP1271_THRESHOLD);
        return IERC1271.isValidSignature.selector;
    }
}

/// @notice zk-governance `SecurityCouncil`, reduced to the standard-path upgrade approval.
contract SecurityCouncilDouble is MultisigDouble, EIP712 {
    bytes32 private constant APPROVE_UPGRADE_SECURITY_COUNCIL_TYPEHASH =
        keccak256("ApproveUpgradeSecurityCouncil(bytes32 id)");

    ProtocolUpgradeHandlerDouble public immutable PROTOCOL_UPGRADE_HANDLER;

    constructor(
        ProtocolUpgradeHandlerDouble _protocolUpgradeHandler,
        address[] memory _members
    ) MultisigDouble(_members, SECURITY_COUNCIL_EIP1271_THRESHOLD) EIP712("SecurityCouncil", "1") {
        PROTOCOL_UPGRADE_HANDLER = _protocolUpgradeHandler;
    }

    function approveUpgradeSecurityCouncil(
        bytes32 _id,
        address[] calldata _signers,
        bytes[] calldata _signatures
    ) external {
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(APPROVE_UPGRADE_SECURITY_COUNCIL_TYPEHASH, _id)));
        checkSignatures(digest, _signers, _signatures, SECURITY_COUNCIL_APPROVE_UPGRADE_THRESHOLD);
        PROTOCOL_UPGRADE_HANDLER.approveUpgradeSecurityCouncil(_id);
    }
}

/// @notice zk-governance `EmergencyUpgradeBoard`, unchanged: the three signature checks over its
///         own EIP-712 domain, then `ProtocolUpgradeHandler.executeEmergencyUpgrade`.
contract EmergencyUpgradeBoardDouble is EIP712 {
    using SignatureChecker for address;

    bytes32 private constant GUARDIANS_TYPEHASH = keccak256("ExecuteEmergencyUpgradeGuardians(bytes32 id)");
    bytes32 private constant SECURITY_COUNCIL_TYPEHASH =
        keccak256("ExecuteEmergencyUpgradeSecurityCouncil(bytes32 id)");
    bytes32 private constant ZK_FOUNDATION_TYPEHASH = keccak256("ExecuteEmergencyUpgradeZKFoundation(bytes32 id)");

    IProtocolUpgradeHandler public immutable PROTOCOL_UPGRADE_HANDLER;
    address public immutable SECURITY_COUNCIL;
    address public immutable GUARDIANS;
    address public immutable ZK_FOUNDATION_SAFE;

    constructor(
        IProtocolUpgradeHandler _protocolUpgradeHandler,
        address _securityCouncil,
        address _guardians,
        address _zkFoundation
    ) EIP712("EmergencyUpgradeBoard", "1") {
        PROTOCOL_UPGRADE_HANDLER = _protocolUpgradeHandler;
        SECURITY_COUNCIL = _securityCouncil;
        GUARDIANS = _guardians;
        ZK_FOUNDATION_SAFE = _zkFoundation;
    }

    function executeEmergencyUpgrade(
        IProtocolUpgradeHandler.Call[] calldata _calls,
        bytes32 _salt,
        bytes calldata _guardiansSignatures,
        bytes calldata _securityCouncilSignatures,
        bytes calldata _zkFoundationSignatures
    ) external {
        IProtocolUpgradeHandler.UpgradeProposal memory upgradeProposal = IProtocolUpgradeHandler.UpgradeProposal({
            calls: _calls,
            salt: _salt,
            executor: address(this)
        });
        bytes32 id = keccak256(abi.encode(upgradeProposal));
        require(
            GUARDIANS.isValidERC1271SignatureNow(typedDigest(GUARDIANS_TYPEHASH, id), _guardiansSignatures),
            "Invalid guardians signatures"
        );
        require(
            SECURITY_COUNCIL.isValidERC1271SignatureNow(
                typedDigest(SECURITY_COUNCIL_TYPEHASH, id),
                _securityCouncilSignatures
            ),
            "Invalid Security Council signatures"
        );
        require(
            ZK_FOUNDATION_SAFE.isValidSignatureNow(typedDigest(ZK_FOUNDATION_TYPEHASH, id), _zkFoundationSignatures),
            "Invalid ZK Foundation signatures"
        );
        PROTOCOL_UPGRADE_HANDLER.executeEmergencyUpgrade(upgradeProposal);
    }

    /// @notice The digest a signer approves: OpenZeppelin's `_hashTypedDataV4` over this board's domain.
    function typedDigest(bytes32 _typehash, bytes32 _id) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(_typehash, _id)));
    }
}

/// @notice zk-governance `ProtocolUpgradeHandler`, reduced to its emergency execution and the
///         Security Council's approval record. Not modelled: the freeze bookkeeping and the
///         `_unfreeze` pre-step of `executeEmergencyUpgrade`, which only lifts ecosystem-wide
///         pauses (a registry operation holds a per-CTM migration pause).
contract ProtocolUpgradeHandlerDouble {
    event EmergencyUpgradeExecuted(bytes32 indexed _id);
    event UpgradeApprovedBySecurityCouncil(bytes32 indexed _id);

    address private immutable DEPLOYER;

    address public guardians;
    address public securityCouncil;
    address public emergencyUpgradeBoard;

    mapping(bytes32 id => bool executed) public emergencyUpgradeExecuted;
    mapping(bytes32 id => bool approved) public securityCouncilApproved;

    constructor() {
        DEPLOYER = msg.sender;
    }

    /// @notice One-time wiring: the multisigs and the board are deployed after the handler.
    function wire(address _guardians, address _securityCouncil, address _emergencyUpgradeBoard) external {
        require(msg.sender == DEPLOYER && emergencyUpgradeBoard == address(0), "already wired");
        guardians = _guardians;
        securityCouncil = _securityCouncil;
        emergencyUpgradeBoard = _emergencyUpgradeBoard;
    }

    function approveUpgradeSecurityCouncil(bytes32 _id) external {
        require(msg.sender == securityCouncil, "Only Security Council is allowed to call this function");
        securityCouncilApproved[_id] = true;
        emit UpgradeApprovedBySecurityCouncil(_id);
    }

    function executeEmergencyUpgrade(IProtocolUpgradeHandler.UpgradeProposal calldata _proposal) external payable {
        require(msg.sender == emergencyUpgradeBoard, "Only Emergency Upgrade Board is allowed to call this function");
        bytes32 id = keccak256(abi.encode(_proposal));
        require(!emergencyUpgradeExecuted[id], "Upgrade already exists");
        require(_proposal.executor == msg.sender, "msg.sender is not authorized to perform the upgrade");
        emergencyUpgradeExecuted[id] = true;
        for (uint256 i = 0; i < _proposal.calls.length; ++i) {
            IProtocolUpgradeHandler.Call calldata upgradeCall = _proposal.calls[i];
            if (upgradeCall.data.length > 0) {
                require(
                    upgradeCall.target.code.length > 0,
                    "Target must be a smart contract if the calldata is not empty"
                );
            }
            (bool success, bytes memory returnData) = upgradeCall.target.call{value: upgradeCall.value}(
                upgradeCall.data
            );
            if (!success) {
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
        }
        emit EmergencyUpgradeExecuted(id);
    }
}

/// @notice Deploys a handler, its board and multisigs, every approving Safe a 1-of-1 Safe of one
///         owner EOA — the shape of the staging governance the approved-hash route is built for —
///         and sends what an operator sends for an emitted proposal.
abstract contract EmergencyUpgradeFixture is Test {
    /// @dev The one owner of every approving Safe.
    Vm.Wallet internal safeOwner = vm.createWallet("emergency-safe-owner");
    ProtocolUpgradeHandlerDouble internal handler;
    EmergencyUpgradeBoardDouble internal board;
    MultisigDouble internal guardians;
    SecurityCouncilDouble internal securityCouncil;
    OneOwnerSafeDouble internal zkFoundation;
    /// @dev The restored calldata tool, deployed as a contract.
    EmergencyStageUpgradeCalldata internal tool;
    /// @dev Whoever sends the board call: anyone may.
    address internal relayer = makeAddr("relayer");

    /// @param _guardiansSafeOwner The owner of the Guardians' member Safes: `safeOwner` for the
    ///        staging shape, anyone else for a board the approved-hash route cannot serve.
    function _deployEmergencyGovernance(address _guardiansSafeOwner) internal {
        handler = new ProtocolUpgradeHandlerDouble();
        guardians = new MultisigDouble(_sortedSafes(GUARDIANS_SIZE, _guardiansSafeOwner), GUARDIANS_EIP1271_THRESHOLD);
        securityCouncil = new SecurityCouncilDouble(handler, _sortedSafes(SECURITY_COUNCIL_SIZE, safeOwner.addr));
        zkFoundation = new OneOwnerSafeDouble(safeOwner.addr);
        board = new EmergencyUpgradeBoardDouble({
            _protocolUpgradeHandler: IProtocolUpgradeHandler(address(handler)),
            _securityCouncil: address(securityCouncil),
            _guardians: address(guardians),
            _zkFoundation: address(zkFoundation)
        });
        handler.wire(address(guardians), address(securityCouncil), address(board));
        tool = new EmergencyStageUpgradeCalldata();
    }

    /// @notice Writes a package's `[governance_calls]` table — entry `_keys[i]` the
    ///         `abi.encode(Call[])` of `_lists[i]`, serialized in the order given — and returns its path.
    function _writePackage(
        string memory _name,
        string[] memory _keys,
        IProtocolUpgradeHandler.Call[][] memory _lists
    ) internal returns (string memory path) {
        string memory dir = string.concat(vm.projectRoot(), "/script-out/emergency-upgrade");
        vm.createDir(dir, true);
        string memory callsKey = string.concat("emergency-package-calls-", _name);
        string memory calls;
        for (uint256 i = 0; i < _keys.length; ++i) {
            calls = vm.serializeBytes(callsKey, _keys[i], abi.encode(_lists[i]));
        }
        string memory root = vm.serializeString(string.concat("emergency-package-", _name), "governance_calls", calls);
        path = string.concat(dir, "/", _name, ".toml");
        vm.writeToml(root, path);
    }

    /// @notice {_writePackage} under today's per-stage keys, in stage order.
    function _writeStagedPackage(
        string memory _name,
        IProtocolUpgradeHandler.Call[] memory _stage0,
        IProtocolUpgradeHandler.Call[] memory _stage1,
        IProtocolUpgradeHandler.Call[] memory _stage2
    ) internal returns (string memory) {
        string[] memory keys = new string[](3);
        keys[0] = "stage0_calls";
        keys[1] = "stage1_calls";
        keys[2] = "stage2_calls";
        IProtocolUpgradeHandler.Call[][] memory lists = new IProtocolUpgradeHandler.Call[][](3);
        lists[0] = _stage0;
        lists[1] = _stage1;
        lists[2] = _stage2;
        return _writePackage(_name, keys, lists);
    }

    /// @notice The board as the tool's interface type.
    function _board() internal view returns (IEmergencyUpgrageBoard) {
        return IEmergencyUpgrageBoard(address(board));
    }

    /// @notice The owner's approveHash transactions, as emitted, except `_skippedApproval`.
    function _approve(
        EmergencyStageUpgradeCalldata.EmergencyProposal memory _proposal,
        uint256 _skippedApproval
    ) internal {
        for (uint256 i = 0; i < _proposal.approvals.length; ++i) {
            if (i == _skippedApproval) {
                continue;
            }
            vm.prank(_proposal.owner);
            Address.functionCall(
                _proposal.approvals[i].safe,
                abi.encodeCall(ISafe.approveHash, (_proposal.approvals[i].safeMessageHash))
            );
        }
    }

    /// @notice The board call, as emitted, sent by an arbitrary account.
    function _execute(EmergencyStageUpgradeCalldata.EmergencyProposal memory _proposal) internal {
        _send(_proposal, tool.executeCalldata(_proposal));
    }

    /// @notice Sends `_executeCalldata` to the proposal's board. Split from {_execute} so a test can
    ///         fetch the calldata from the tool BEFORE it arms `expectRevert`/`expectEmit`, which would
    ///         otherwise apply to that fetch.
    function _send(
        EmergencyStageUpgradeCalldata.EmergencyProposal memory _proposal,
        bytes memory _executeCalldata
    ) internal {
        vm.prank(relayer);
        Address.functionCall(address(_proposal.board), _executeCalldata);
    }

    /// @notice Every approval, then the board call.
    function _approveAndExecute(EmergencyStageUpgradeCalldata.EmergencyProposal memory _proposal) internal {
        _approve(_proposal, type(uint256).max);
        _execute(_proposal);
    }

    function _sortedSafes(uint256 _count, address _owner) private returns (address[] memory safes) {
        safes = new address[](_count);
        for (uint256 i = 0; i < _count; ++i) {
            safes[i] = address(new OneOwnerSafeDouble(_owner));
        }
        for (uint256 i = 1; i < _count; ++i) {
            address current = safes[i];
            uint256 j = i;
            while (j > 0 && safes[j - 1] > current) {
                safes[j] = safes[j - 1];
                --j;
            }
            safes[j] = current;
        }
    }
}
