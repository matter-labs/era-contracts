// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {BridgehubInvariantTests} from "./BridgehubTests.t.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";
import {NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {ETH_TOKEN_ADDRESS, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {
    L1InteropRequests,
    L1L2MessageParams,
    L1L2IndirectMessageParams
} from "../../../../deploy-scripts/utils/L1InteropRequests.sol";

contract RegistryAuthorizationProbe {
    IBridgehubBase internal immutable BRIDGEHUB;
    constructor(IBridgehubBase _bridgehub) {
        BRIDGEHUB = _bridgehub;
    }
    function authorized(address _caller) external view returns (bool) {
        return _caller == BRIDGEHUB.interopCenter();
    }
}
contract StoredAuthorizationProbe {
    address internal center;
    constructor(address _center) {
        center = _center;
    }
    function authorized(address _caller) external view returns (bool) {
        return _caller == center;
    }
}

contract L1RequestGasTest is BridgehubInvariantTests {
    function setUp() public {
        prepare();
    }
    function test_gasDirect() public {
        _measure(false);
    }
    function test_gasIndirect() public {
        _measure(true);
    }

    function test_gasRegistryAuthorization() public {
        RegistryAuthorizationProbe dynamicProbe = new RegistryAuthorizationProbe(
            IBridgehubBase(address(addresses.bridgehub))
        );
        StoredAuthorizationProbe storedProbe = new StoredAuthorizationProbe(address(addresses.interopCenter));
        address caller = address(addresses.interopCenter);
        vm.cool(address(dynamicProbe));
        vm.cool(address(storedProbe));
        vm.cool(address(addresses.bridgehub));
        vm.cool(ecosystemAddresses.bridgehub.implementations.bridgehub);
        assertTrue(dynamicProbe.authorized(caller));
        uint256 dynamicCold = vm.snapshotGasLastCall("EVM1521", "registry-cold");
        assertTrue(storedProbe.authorized(caller));
        uint256 storedCold = vm.snapshotGasLastCall("EVM1521", "stored-cold");
        assertTrue(dynamicProbe.authorized(caller));
        uint256 dynamicWarm = vm.snapshotGasLastCall("EVM1521", "registry-warm");
        assertTrue(storedProbe.authorized(caller));
        uint256 storedWarm = vm.snapshotGasLastCall("EVM1521", "stored-warm");
        emit log_named_uint("additional cold registry authorization gas", dynamicCold - storedCold);
        emit log_named_uint("additional warm registry authorization gas", dynamicWarm - storedWarm);
    }

    function _measure(bool _indirect) private {
        uint256 chainId = zkChainIds[0];
        assertEq(getZKChainBaseToken(chainId), ETH_TOKEN_ADDRESS);
        address caller = users[0];
        bytes memory payload;
        if (_indirect) {
            TestnetERC20Token token = TestnetERC20Token(tokens[0]);
            token.mint(caller, 1 ether);
            vm.prank(caller);
            token.approve(address(addresses.l1NativeTokenVault), 1 ether);
            payload = bytes.concat(
                NEW_ENCODING_VERSION,
                abi.encode(
                    DataEncoding.encodeNTVAssetId(block.chainid, address(token)),
                    DataEncoding.encodeBridgeBurnData(1 ether, caller, address(token))
                )
            );
        }
        bytes memory data = _encodeRequest(chainId, caller, _indirect, payload);
        address target = address(addresses.interopCenter);
        vm.deal(caller, 1 ether);
        vm.txGasPrice(1 gwei);
        vm.recordLogs();
        vm.prank(caller, caller);
        (bool success, bytes memory result) = target.call{value: 1 ether}(data);
        uint256 requestGas = vm.snapshotGasLastCall("EVM1521", _indirect ? "indirect" : "direct");
        assertTrue(success);
        bytes32 txHash = abi.decode(result, (bytes32));
        NewPriorityRequest memory request = _getNewPriorityQueueFromLogs(vm.getRecordedLogs());
        assertEq(txHash, request.txHash);
        assertEq(caller.balance, 0);
        emit log_named_uint(_indirect ? "indirect request gas" : "direct request gas", requestGas);
    }
    function _encodeRequest(
        uint256 _chainId,
        address _caller,
        bool _indirect,
        bytes memory _payload
    ) private view returns (bytes memory) {
        if (_indirect) {
            return
                L1InteropRequests.encodeIndirectCalldata(
                    L1L2IndirectMessageParams({
                        chainId: _chainId,
                        mintValue: 1 ether,
                        l2Value: 0,
                        l2GasLimit: 1_000_000,
                        l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                        refundRecipient: _caller,
                        crossChainSender: address(addresses.sharedBridge),
                        indirectCallValue: 0,
                        indirectCallData: _payload
                    })
                );
        }
        return
            L1InteropRequests.encodeDirectCalldata(
                L1L2MessageParams({
                    chainId: _chainId,
                    mintValue: 1 ether,
                    l2Contract: users[1],
                    l2Value: 0,
                    l2Calldata: hex"",
                    l2GasLimit: 1_000_000,
                    l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                    factoryDeps: new bytes[](0),
                    refundRecipient: _caller
                })
            );
    }
}
