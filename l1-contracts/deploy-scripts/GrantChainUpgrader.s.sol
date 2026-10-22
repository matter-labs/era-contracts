// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";

/// @notice Prepare a grant of only UPGRADER_ROLE through an Ownable ChainAdmin.
/// @dev No broadcast cheatcodes: even --broadcast cannot submit this transaction.
///      run() simulates the exact wallet calldata as the current owner, checks the
///      resulting membership, then writes the transaction and its execution runbook.
contract GrantChainUpgrader is Script {
    error WrongL1Chain();
    error InvalidChain();
    error InvalidAccount();
    error InvalidTimelock();
    error MissingRoleAdmin();
    error AlreadyGranted();
    error GrantNotApplied();

    struct Transaction {
        address sender;
        address chainAdmin;
        address chainAddress;
        bytes32 role;
        bytes data;
    }

    function prepare(
        uint256 _l1ChainId,
        address _bridgehub,
        uint256 _chainId,
        address _validatorTimelock,
        address _account
    ) public view returns (Transaction memory transaction) {
        if (block.chainid != _l1ChainId) revert WrongL1Chain();
        if (_account == address(0)) revert InvalidAccount();

        transaction.chainAddress = IL1Bridgehub(_bridgehub).getZKChain(_chainId);
        if (transaction.chainAddress == address(0)) revert InvalidChain();
        IGetters chain = IGetters(transaction.chainAddress);
        if (chain.getChainId() != _chainId) revert InvalidChain();

        ValidatorTimelock timelock = ValidatorTimelock(_validatorTimelock);
        if (address(timelock.BRIDGE_HUB()) != _bridgehub || !chain.isValidator(_validatorTimelock)) {
            revert InvalidTimelock();
        }
        transaction.chainAdmin = chain.getAdmin();
        transaction.sender = Ownable2Step(transaction.chainAdmin).owner();
        if (transaction.sender == address(0)) revert InvalidAccount();
        transaction.role = timelock.UPGRADER_ROLE();
        if (
            !timelock.hasRole(
                transaction.chainAddress,
                timelock.getRoleAdmin(transaction.chainAddress, transaction.role),
                transaction.chainAdmin
            )
        ) revert MissingRoleAdmin();
        if (timelock.hasRole(transaction.chainAddress, transaction.role, _account)) revert AlreadyGranted();

        IChainAdminOwnable.Call[] memory calls = new IChainAdminOwnable.Call[](1);
        calls[0] = IChainAdminOwnable.Call({
            target: _validatorTimelock,
            value: 0,
            data: abi.encodeCall(timelock.grantRole, (transaction.chainAddress, transaction.role, _account))
        });
        transaction.data = abi.encodeCall(IChainAdminOwnable.multicall, (calls, true));
    }

    function run(
        uint256 _l1ChainId,
        address _bridgehub,
        uint256 _chainId,
        address _validatorTimelock,
        address _account,
        string calldata _output
    ) external returns (Transaction memory transaction) {
        transaction = prepare({
            _l1ChainId: _l1ChainId,
            _bridgehub: _bridgehub,
            _chainId: _chainId,
            _validatorTimelock: _validatorTimelock,
            _account: _account
        });

        // A successful multicall alone is insufficient: an all-false
        // addValidatorRoles payload succeeds without granting anything.
        vm.prank(transaction.sender);
        (bool success, bytes memory returnData) = transaction.chainAdmin.call(transaction.data);
        if (!success) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        if (!ValidatorTimelock(_validatorTimelock).hasRole(transaction.chainAddress, transaction.role, _account)) {
            revert GrantNotApplied();
        }

        string memory key = "grant-chain-upgrader";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeUint(key, "zkChainId", _chainId);
        vm.serializeAddress(key, "from", transaction.sender);
        vm.serializeAddress(key, "to", transaction.chainAdmin);
        vm.serializeUint(key, "value", 0);
        vm.serializeAddress(key, "chainAddress", transaction.chainAddress);
        vm.serializeAddress(key, "validatorTimelock", _validatorTimelock);
        vm.serializeAddress(key, "account", _account);
        vm.serializeBytes32(key, "role", transaction.role);
        vm.writeJson(vm.serializeBytes(key, "data", transaction.data), _output);
        vm.writeFile(string.concat(_output, ".calldata"), vm.toString(transaction.data));
        vm.writeFile(
            string.concat(_output, ".md"),
            _runbook({
                _transaction: transaction,
                _chainId: _chainId,
                _validatorTimelock: _validatorTimelock,
                _account: _account
            })
        );
    }

    // string.concat is variadic and does not accept named arguments.
    // solhint-disable func-named-parameters
    function _runbook(
        Transaction memory _transaction,
        uint256 _chainId,
        address _validatorTimelock,
        address _account
    ) internal view returns (string memory book) {
        book = string.concat(
            "# Grant chain upgrader\n\nLocal simulation passed; no transaction was broadcast.\n\n",
            "- L1 chain ID: ",
            vm.toString(block.chainid),
            "\n- ZK chain ID: ",
            vm.toString(_chainId),
            "\n- From: ",
            vm.toString(_transaction.sender)
        );
        book = string.concat(
            book,
            "\n- To (ChainAdmin): ",
            vm.toString(_transaction.chainAdmin),
            "\n- Value: 0 ETH\n- ValidatorTimelock: ",
            vm.toString(_validatorTimelock),
            "\n- Chain diamond: ",
            vm.toString(_transaction.chainAddress)
        );
        book = string.concat(
            book,
            "\n- Grantee: ",
            vm.toString(_account),
            "\n- Role: UPGRADER_ROLE (",
            vm.toString(_transaction.role),
            ")\n\n",
            "Send the exact data from the adjacent .calldata file through your wallet. ",
            "The ChainAdmin forwards grantRole(chain diamond, UPGRADER_ROLE, grantee).\n\n",
            "After confirmation, require hasRole(chain diamond, role, grantee) = true on the ",
            "ValidatorTimelock and check its RoleGranted event. Receipt success alone is insufficient.\n"
        );
    }
    // solhint-enable func-named-parameters
}
