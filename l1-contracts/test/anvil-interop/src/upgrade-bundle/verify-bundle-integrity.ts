import { runCli, verifyBundleIntegrity } from "./common";

runCli(() => {
  const [bundleDirectory, extra] = process.argv.slice(2);
  if (!bundleDirectory || extra) throw new Error("usage: yarn bundle:verify <deploy-bundle-directory>");
  verifyBundleIntegrity(bundleDirectory);
});
