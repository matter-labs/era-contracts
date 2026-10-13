// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1InteropFeeManager} from "contracts/core/interop-fee/L1InteropFeeManager.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";

import {ChainRegistryStub, ZKChainStub} from "./L1InteropFeeManager.t.sol";

/// @dev Drives the manager through every entry point that moves value or sets the fee, each from its authorized
/// caller, and tracks per token the value that moved through it. The fee token switches between ether and an ERC20.
/// The fee recipient stays fixed: the sweep invariant relies on it.
contract L1InteropFeeManagerHandler is Test {
    L1InteropFeeManager internal immutable MANAGER;
    address internal immutable OWNER;
    address internal immutable WITHDRAWAL_RECEIVER = makeAddr("withdrawalReceiver");
    TestnetERC20Token public immutable TOKEN = new TestnetERC20Token("Fee", "FEE", 18);

    uint256[] internal chainIds;
    mapping(uint256 chainId => address zkChain) internal zkChains;
    mapping(uint256 chainId => address admin) internal admins;

    mapping(address token => uint256 amount) public ghostDeposited;
    mapping(address token => uint256 amount) public ghostWithdrawn;
    mapping(address token => uint256 amount) public ghostCharged;
    mapping(address token => uint256 amount) public ghostSwept;

    constructor(L1InteropFeeManager _manager, address _owner, ChainRegistryStub _registry, uint256[] memory _chainIds) {
        MANAGER = _manager;
        OWNER = _owner;
        chainIds = _chainIds;
        for (uint256 i = 0; i < _chainIds.length; ++i) {
            address admin = makeAddr(string.concat("admin", vm.toString(_chainIds[i])));
            address zkChain = address(new ZKChainStub(admin));
            _registry.register(_chainIds[i], zkChain);
            zkChains[_chainIds[i]] = zkChain;
            admins[_chainIds[i]] = admin;
        }
    }

    function deposit(uint256 _chainSeed, uint96 _amount) external {
        uint256 chainId = _chain(_chainSeed);
        uint256 amount = bound(_amount, 1, type(uint96).max);
        address token = MANAGER.feeToken();
        if (token == ETH_TOKEN_ADDRESS) {
            vm.deal(address(this), amount);
            MANAGER.deposit{value: amount}(chainId, token, amount);
        } else {
            TOKEN.mint(address(this), amount);
            TOKEN.approve(address(MANAGER), amount);
            MANAGER.deposit(chainId, token, amount);
        }
        ghostDeposited[token] += amount;
    }

    function withdraw(uint256 _chainSeed, uint256 _tokenSeed, uint256 _amount) external {
        uint256 chainId = _chain(_chainSeed);
        address token = pickToken(_tokenSeed);
        uint256 balance = MANAGER.chainBalance(chainId, token);
        if (balance == 0) {
            return;
        }
        uint256 amount = bound(_amount, 1, balance);
        vm.prank(admins[chainId]);
        MANAGER.withdraw(chainId, token, WITHDRAWAL_RECEIVER, amount);
        ghostWithdrawn[token] += amount;
    }

    function chargeInteropFee(uint256 _chainSeed, uint256 _batchNumber, uint256 _units) external {
        uint256 chainId = _chain(_chainSeed);
        address token = MANAGER.feeToken();
        uint256 feePerUnit = MANAGER.feePerUnit();
        // Only charges the balance covers: an uncovered one reverts the execution and moves nothing.
        uint256 maxUnits = feePerUnit == 0 ? type(uint32).max : MANAGER.chainBalance(chainId, token) / feePerUnit;
        uint256 units = bound(_units, 0, maxUnits);
        vm.prank(zkChains[chainId]);
        MANAGER.chargeInteropFee(chainId, _batchNumber, units);
        ghostCharged[token] += feePerUnit * units;
    }

    function setFee(uint256 _tokenSeed, uint64 _feePerUnit) external {
        vm.prank(OWNER);
        MANAGER.setFee(pickToken(_tokenSeed), _feePerUnit);
    }

    function sweep(uint256 _tokenSeed) external {
        address token = pickToken(_tokenSeed);
        ghostSwept[token] += MANAGER.accruedFees(token);
        MANAGER.sweep(token);
    }

    function totalChainBalances(address _token) external view returns (uint256 total) {
        for (uint256 i = 0; i < chainIds.length; ++i) {
            total += MANAGER.chainBalance(chainIds[i], _token);
        }
    }

    function balanceOf(address _token, address _account) external view returns (uint256) {
        return _token == ETH_TOKEN_ADDRESS ? _account.balance : TOKEN.balanceOf(_account);
    }

    function pickToken(uint256 _seed) public view returns (address) {
        return _seed % 2 == 0 ? ETH_TOKEN_ADDRESS : address(TOKEN);
    }

    function _chain(uint256 _seed) internal view returns (uint256) {
        return chainIds[_seed % chainIds.length];
    }
}

contract L1InteropFeeManagerInvariantTest is Test {
    L1InteropFeeManager internal manager;
    L1InteropFeeManagerHandler internal handler;
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        address owner = makeAddr("owner");
        ChainRegistryStub registry = new ChainRegistryStub();
        L1InteropFeeManager impl = new L1InteropFeeManager(IBridgehubBase(address(registry)));
        manager = L1InteropFeeManager(
            address(
                new TransparentUpgradeableProxy(
                    address(impl),
                    makeAddr("proxyAdmin"),
                    abi.encodeCall(L1InteropFeeManager.initialize, (owner, recipient))
                )
            )
        );

        uint256[] memory chainIds = new uint256[](3);
        (chainIds[0], chainIds[1], chainIds[2]) = (271, 272, 273);
        handler = new L1InteropFeeManagerHandler(manager, owner, registry, chainIds);
        targetContract(address(handler));
    }

    /// @dev In each token, the manager's holdings always back exactly the prepaid balances plus the fees not yet swept.
    function invariant_holdingsBackLedgers() public view {
        for (uint256 i = 0; i < 2; ++i) {
            address token = handler.pickToken(i);
            assertEq(
                handler.balanceOf(token, address(manager)),
                handler.totalChainBalances(token) + manager.accruedFees(token)
            );
        }
    }

    /// @dev Every charged unit of a token is either still accrued or was swept, and only to the fee recipient.
    function invariant_chargedFeesAreAccruedOrSwept() public view {
        for (uint256 i = 0; i < 2; ++i) {
            address token = handler.pickToken(i);
            assertEq(handler.ghostCharged(token), manager.accruedFees(token) + handler.ghostSwept(token));
            assertEq(handler.balanceOf(token, recipient), handler.ghostSwept(token));
        }
    }

    /// @dev Every deposited unit of a token is still prepaid, was charged, or was withdrawn by a chain admin.
    function invariant_depositsAreConserved() public view {
        for (uint256 i = 0; i < 2; ++i) {
            address token = handler.pickToken(i);
            assertEq(
                handler.ghostDeposited(token),
                handler.totalChainBalances(token) + handler.ghostCharged(token) + handler.ghostWithdrawn(token)
            );
        }
    }
}
