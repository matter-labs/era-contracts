import { packDeployBundle } from "./pack";
import { runCli } from "./common";

runCli(() => {
  const [environment, extra] = process.argv.slice(2);
  if (!environment || extra) throw new Error("usage: yarn bundle:pack <stage | testnet | mainnet>");
  packDeployBundle(environment);
});
