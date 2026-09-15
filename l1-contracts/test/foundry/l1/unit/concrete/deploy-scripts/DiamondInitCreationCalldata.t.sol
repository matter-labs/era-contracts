// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CTMContract, CTMCoreDeploymentConfig, DeployCTML1OrGateway} from "deploy-scripts/ctm/DeployCTML1OrGateway.sol";

/// @notice `DiamondInit` takes the Airbender lane as a constructor bool, and the deploy scripts are the only
/// thing that sets it.
/// @dev The struct carries both an `airbenderVerifier` address and an `airbenderLane` bool. Encoding the
/// address into the bool argument compiles, and reverts only once the constructor decodes it — during a real
/// CTM deployment. Decoding here catches that without one.
contract DiamondInitCreationCalldataTest is Test {
    function _config(bool _airbenderLane, bool _isZKsyncOS) internal pure returns (CTMCoreDeploymentConfig memory) {
        return
            CTMCoreDeploymentConfig({
                isZKsyncOS: _isZKsyncOS,
                testnetVerifier: false,
                eraChainId: 9,
                l1ChainId: 1,
                bridgehubProxy: address(0),
                interopCenterProxy: address(0),
                rollupDAManager: address(0),
                chainAssetHandler: address(0),
                l1BytecodesSupplier: address(0),
                eip7702Checker: address(0),
                verifierFflonk: address(0),
                verifierPlonk: address(0),
                airbenderVerifierPlonk: address(0),
                // Deliberately set: the bug this guards against is encoding this address instead of the flag.
                airbenderVerifier: address(0xA1B2),
                airbenderLane: _airbenderLane,
                boojumVerifier: address(0),
                verifierOwner: address(0),
                permissionlessValidator: address(0)
            });
    }

    function _decode(bool _airbenderLane, bool _isZKsyncOS, bool _isZKBytecode) internal view returns (bool, bool) {
        bytes memory args = DeployCTML1OrGateway.getCreationCalldata(
            _config(_airbenderLane, _isZKsyncOS),
            _isZKsyncOS,
            CTMContract.DiamondInit,
            _isZKBytecode
        );
        return abi.decode(args, (bool, bool));
    }

    function test_carriesTheLaneFlagForAnEraCTM() public view {
        (bool isZKsyncOS, bool hasLane) = _decode({_airbenderLane: true, _isZKsyncOS: false, _isZKBytecode: false});
        assertFalse(isZKsyncOS);
        assertTrue(hasLane);
    }

    function test_carriesTheAbsenceOfTheLane() public view {
        (, bool hasLane) = _decode({_airbenderLane: false, _isZKsyncOS: false, _isZKBytecode: false});
        assertFalse(hasLane);
    }

    /// A ZK bytecode is a CTM deployed onto Gateway, and that flow wires no Airbender lane, so the config's
    /// answer must not reach `DiamondInit`.
    function test_gatewayDeploymentNeverClaimsTheLane() public view {
        (, bool hasLane) = _decode({_airbenderLane: true, _isZKsyncOS: false, _isZKBytecode: true});
        assertFalse(hasLane);
    }

    function test_zksyncOSPassesItsOwnFlagThrough() public view {
        (bool isZKsyncOS, ) = _decode({_airbenderLane: false, _isZKsyncOS: true, _isZKBytecode: false});
        assertTrue(isZKsyncOS);
    }

    function test_hasAirbenderLaneIsOffForZKsyncOS() public pure {
        assertFalse(DeployCTML1OrGateway.hasAirbenderLane({_airbenderRequested: true, _isZKsyncOS: true}));
        assertTrue(DeployCTML1OrGateway.hasAirbenderLane({_airbenderRequested: true, _isZKsyncOS: false}));
        assertFalse(DeployCTML1OrGateway.hasAirbenderLane({_airbenderRequested: false, _isZKsyncOS: false}));
    }
}
