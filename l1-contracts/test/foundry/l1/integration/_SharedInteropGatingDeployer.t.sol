// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";

/// @notice Deploys an ecosystem whose CTM uses the multi-proof verifier, with Era and one more chain, so
/// the chains can satisfy the interop preconditions. See {protocol-docs/interop-gating.md}.
abstract contract InteropGatingDeployer is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    /// @dev `zisk_plonk_verifier_addr` of the multi-proof config. The tests only submit testnet proofs, which
    /// never reach the ZiSK Plonk verifier, so any code there serves.
    address internal constant ZISK_PLONK_VERIFIER = address(0xFe11);

    string internal constant MULTI_PROOF_CTM_CONFIG_PATH =
        "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-ctm-multi-proof.toml";

    L1MessageRoot internal messageRoot;

    function _deployInteropGatingEcosystem() internal {
        vm.etch(ZISK_PLONK_VERIFIER, hex"fe");
        _deployL1Contracts(MULTI_PROOF_CTM_CONFIG_PATH);
        _deployTokens();
        _registerNewTokens(tokens);

        _deployEra();
        _deployZKChain(ETH_TOKEN_ADDRESS);

        messageRoot = L1MessageRoot(address(ecosystemAddresses.bridgehub.proxies.messageRoot));
    }

    function _chainAdmin(uint256 _chainId) internal view returns (address) {
        return IGetters(getZKChainAddress(_chainId)).getAdmin();
    }

    function _permanentlyRequireSecondProofSystem(uint256 _chainId) internal {
        address chain = getZKChainAddress(_chainId);
        vm.prank(IGetters(chain).getAdmin());
        IAdmin(chain).permanentlyRequireSecondProofSystem();
    }

    /// @notice The chain admin turns on the L1SLOAD chain-config flag, which interop gating reads L1 through.
    function _enableL1Sload(uint256 _chainId) internal {
        address chain = getZKChainAddress(_chainId);
        vm.prank(IGetters(chain).getAdmin());
        IAdmin(chain).setZKsyncOSL1SloadEnabled(true);
    }

    /// @notice Runs the full enabling procedure: the chain admin permanently requires the second proof system and turns
    /// on L1SLOAD, then the Bridgehub owner enables interop.
    function _enableInterop(uint256 _chainId) internal {
        _permanentlyRequireSecondProofSystem(_chainId);
        _enableL1Sload(_chainId);
        vm.prank(addresses.bridgehubOwnerAddress);
        messageRoot.enableInterop(_chainId, true);
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
