pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {L2_ASSET_ROUTER_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";


contract L1AssetRouterActorHandler is Test {
    address l1Token;
    address l1Router;
    address vault;
    // ghost variables
    // https://book.getfoundry.sh/forge/invariant-testing#handler-ghost-variables
    uint256 public totalDeposits;
    // constants
    // borrowed from https://github.com/matter-labs/era-contracts/blob/16dedf6d77695ce00f81fce35a3066381b97fca1/l1-contracts/test/foundry/l1/integration/l2-tests-in-l1-context/_SharedL2ContractDeployer.sol#L64-L68
    address internal constant L1_TOKEN_ADDRESS = 0x1111100000000000000000000000000000011111;
    string internal constant TOKEN_DEFAULT_NAME = "TestnetERC20Token";
    string internal constant TOKEN_DEFAULT_SYMBOL = "TET";
    uint8 internal constant TOKEN_DEFAULT_DECIMALS = 18;
    address internal l1AssetRouter;
    address internal aliasedL1AssetRouter;

    constructor(address _l1AssetRouter) {
        l1AssetRouter = _l1AssetRouter;
        aliasedL1AssetRouter = AddressAliasHelper.applyL1ToL2Alias(l1AssetRouter);
        l1Token = L1_TOKEN_ADDRESS;
    }

    function finalizeDeposit(uint256 _amount, address _sender, uint256 _receiverUint) public {
        _amount = bound(_amount, 0, 1e30);
        address _receiver = address(uint160(bound(_receiverUint, 1, type(uint160).max)));

        // vm.prank(aliasedL1AssetRouter);
        // address _s = makeAddr("_s");
        // address _r = makeAddr("_r");

        L2AssetRouter(L2_ASSET_ROUTER_ADDR).finalizeDeposit({
            _l1Sender: _sender,
            _l2Receiver: _receiver,
            _l1Token: l1Token,
            _amount: _amount,
            _data: encodeTokenData(TOKEN_DEFAULT_NAME, TOKEN_DEFAULT_SYMBOL, TOKEN_DEFAULT_DECIMALS)
        });

        totalDeposits += _amount;
    }

    function withdraw(uint256 _amount, address _receiver) public {
        _amount = bound(_amount, 0, 1e30);

        address l2Token = L2AssetRouter(L2_ASSET_ROUTER_ADDR).l2TokenAddress(l1Token);
        uint256 l1ChainId = L2AssetRouter(L2_ASSET_ROUTER_ADDR).L1_CHAIN_ID();
        bytes32 assetId = DataEncoding.encodeNTVAssetId(l1ChainId, l1Token);
        bytes memory data = DataEncoding.encodeBridgeBurnData(_amount, _receiver, l2Token);

        L2AssetRouter(L2_ASSET_ROUTER_ADDR).withdraw(assetId, data);

        totalDeposits -= _amount;
    }

    // borrowed from https://github.com/matter-labs/era-contracts/blob/16dedf6d77695ce00f81fce35a3066381b97fca1/l1-contracts/test/foundry/l1/integration/l2-tests-in-l1-context/_SharedL2ContractDeployer.sol#L203-L217
    /// @notice Encodes the token data.
    /// @param name The name of the token.
    /// @param symbol The symbol of the token.
    /// @param decimals The decimals of the token.
    function encodeTokenData(
        string memory name,
        string memory symbol,
        uint8 decimals
    ) internal pure returns (bytes memory) {
        bytes memory encodedName = abi.encode(name);
        bytes memory encodedSymbol = abi.encode(symbol);
        bytes memory encodedDecimals = abi.encode(decimals);

        return abi.encode(encodedName, encodedSymbol, encodedDecimals);
    }
}