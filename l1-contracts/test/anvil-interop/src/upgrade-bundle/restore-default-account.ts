import { restoreCanonicalDefaultAccountArtifact } from "./default-account";
import { runCli } from "./common";

function usage(): never {
  throw new Error(
    "usage: yarn bundle:restore-default-account <artifact.json> <environment.toml> <AllContractsHashes.json>"
  );
}

runCli(() => {
  const [artifactPath, environmentPath, hashesPath, extra] = process.argv.slice(2);
  if (!artifactPath || !environmentPath || !hashesPath || extra) usage();
  restoreCanonicalDefaultAccountArtifact(artifactPath, environmentPath, hashesPath);
});
