// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEIP7702Checker} from "../../state-transition/chain-interfaces/IEIP7702Checker.sol";
import {MailboxFacet} from "../../state-transition/chain-deps/facets/Mailbox.sol";
import {FeeParams, PubdataPricingMode} from "../../state-transition/chain-deps/ZKChainStorage.sol";

contract DummyZKChain is MailboxFacet {
    constructor(
        address bridgeHubAddress,
        uint256 _l1ChainId,
        address _chainAssetHandler,
        IEIP7702Checker _eip7702Checker
    ) MailboxFacet(_l1ChainId, _chainAssetHandler, _eip7702Checker, false) {
        s.bridgehub = bridgeHubAddress;
    }

    function setBridgeHubAddress(address bridgeHubAddress) public {
        s.bridgehub = bridgeHubAddress;
    }

    function setBaseTokenGasMultiplierPrice(uint128 nominator, uint128 denominator) public {
        s.baseTokenGasPriceMultiplierNominator = nominator;
        s.baseTokenGasPriceMultiplierDenominator = denominator;
    }

    function getBridgeHubAddress() public view returns (address) {
        return s.bridgehub;
    }

    function setFeeParams() external {
        FeeParams memory _feeParams = _randomFeeParams();
        s.feeParams = _feeParams;
        s.priorityTxMaxGasLimit = type(uint256).max;
    }

    function _randomFeeParams() internal pure returns (FeeParams memory) {
        return
            FeeParams({
                pubdataPricingMode: PubdataPricingMode.Rollup,
                batchOverheadL1Gas: 1_000_000,
                maxPubdataPerBatch: 110_000,
                maxL2GasPerBatch: 80_000_000,
                priorityTxMaxPubdata: 99_000,
                minimalL2GasPrice: 250_000_000
            });
    }

    function genesisUpgrade(
        address _l1GenesisUpgrade,
        bytes calldata _forceDeploymentData,
        bytes[] calldata _factoryDeps
    ) external {}

    // add this to be excluded from coverage report
    function test() internal {}
}
