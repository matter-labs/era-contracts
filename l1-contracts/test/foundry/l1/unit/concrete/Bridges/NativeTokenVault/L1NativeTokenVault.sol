import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {AssetTrackerBase} from "contracts/bridge/asset-tracker/AssetTrackerBase.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {AssetIdAlreadyRegistered} from "contracts/common/L1ContractErrors.sol";

contract SomeToken {
    constructor() {}

    function name() external {
        // Just some function so that the bytecode is not empty,
        // the actional functionality is not used.
    }
}

contract L1NativeTokenVaultTest is Test {
    address assetRouter;

    L1NativeTokenVault ntv;
    SomeToken token;
    address assetTracker;

    function setUp() public {
        assetRouter = makeAddr("assetRouter");

        ntv = new L1NativeTokenVault(makeAddr("wethToken"), assetRouter, IL1Nullifier(address(0)));
        assetTracker = makeAddr("assetTracker");
        vm.prank(address(0));
        ntv.setAssetTracker(assetTracker);

        token = new SomeToken();
    }

    function test_revertWhenRegisteringSameAddressTwice() external {
        vm.mockCall(
            assetRouter,
            abi.encodeCall(
                L1AssetRouter.setAssetHandlerAddressThisChain,
                (bytes32(uint256(uint160(address(token)))), address(ntv))
            ),
            hex""
        );
        bytes[] memory zeros = new bytes[](2);
        zeros[0] = abi.encode(0);
        zeros[1] = abi.encode(0);
        vm.mockCalls(assetTracker, abi.encodeWithSelector(AssetTrackerBase.registerNewToken.selector), zeros);
        ntv.registerToken(address(token));

        vm.expectRevert(AssetIdAlreadyRegistered.selector);
        ntv.registerToken(address(token));
    }
}
