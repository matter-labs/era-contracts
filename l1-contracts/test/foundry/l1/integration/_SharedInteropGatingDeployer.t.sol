// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";

import {LogFinder} from "test-utils/LogFinder.sol";
import {NEW_PRIORITY_REQUEST_SIGNATURE} from "test/foundry/TestConstants.sol";

/// @notice Deploys an ecosystem whose CTM uses the multi-proof verifier, with Era and one more chain, so
/// the chains can satisfy the interop preconditions. See {protocol-docs/interop-gating.md}.
abstract contract InteropGatingDeployer is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    using LogFinder for Vm.Log[];

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

    function _lockSecondProofSystem(uint256 _chainId) internal {
        address chain = getZKChainAddress(_chainId);
        vm.prank(IGetters(chain).getAdmin());
        IAdmin(chain).lockSecondProofSystem();
    }

    /// @notice Runs the full enabling procedure: the chain admin locks the second proof system, then the
    /// Bridgehub owner enables interop.
    function _enableInterop(uint256 _chainId) internal {
        _lockSecondProofSystem(_chainId);
        vm.prank(addresses.bridgehubOwnerAddress);
        messageRoot.enableInterop(_chainId, true);
    }

    /// @notice Returns the L2 calldata of the single priority transaction `_chainId`'s diamond queued in `_logs`.
    function _priorityTxCalldata(Vm.Log[] memory _logs, uint256 _chainId) internal view returns (bytes memory data) {
        (, data) = _priorityTx(_logs, _chainId);
    }

    /// @notice Returns the id and the L2 calldata of the single priority transaction `_chainId`'s diamond
    /// queued in `_logs`.
    function _priorityTx(
        Vm.Log[] memory _logs,
        uint256 _chainId
    ) internal view returns (uint256 txId, bytes memory data) {
        Vm.Log[] memory requests = _logs.findAllFrom(NEW_PRIORITY_REQUEST_SIGNATURE, getZKChainAddress(_chainId));
        assertEq(requests.length, 1, "exactly one priority transaction");
        L2CanonicalTransaction memory transaction;
        (txId, , , transaction, ) = abi.decode(
            requests[0].data,
            (uint256, bytes32, uint64, L2CanonicalTransaction, bytes[])
        );
        data = transaction.data;
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
