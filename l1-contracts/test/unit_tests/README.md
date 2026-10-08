# Tips

- To print deployment logs, set `verbose: true` in `defaultDeployerForTests` (used by `initialTestnetDeploymentProcess`) or `defaultEraDeployerForTests` (used by `initialEraTestnetDeploymentProcess` and `initialPreUpgradeContractsDeployment`) in `l1-contracts/src.ts/deploy-test-process.ts`.
