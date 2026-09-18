// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";

library EraForceDeploymentsLib {
    function wrap(
        IL2ContractDeployer.ForceDeployment[] memory _fds
    ) internal pure returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory result) {
        result = new IComplexUpgrader.UniversalContractUpgradeInfo[](_fds.length);
        for (uint256 i = 0; i < _fds.length; i++) {
            result[i] = IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: IComplexUpgrader.ContractUpgradeType.EraForceDeployment,
                deployedBytecodeInfo: abi.encode(_fds[i]),
                newAddress: _fds[i].newAddress
            });
        }
    }

    function unwrap(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _infos
    ) internal pure returns (IL2ContractDeployer.ForceDeployment[] memory result) {
        uint256 count = 0;
        for (uint256 i = 0; i < _infos.length; i++) {
            if (_infos[i].upgradeType == IComplexUpgrader.ContractUpgradeType.EraForceDeployment) {
                count++;
            }
        }

        result = new IL2ContractDeployer.ForceDeployment[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < _infos.length; i++) {
            if (_infos[i].upgradeType == IComplexUpgrader.ContractUpgradeType.EraForceDeployment) {
                result[idx++] = abi.decode(_infos[i].deployedBytecodeInfo, (IL2ContractDeployer.ForceDeployment));
            }
        }
    }
}
