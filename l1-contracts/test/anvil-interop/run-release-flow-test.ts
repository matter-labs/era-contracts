#!/usr/bin/env node

import { runReleaseFlow } from "./src/helpers/release-flow-runner";

// The release flow (src/helpers/release-flow-runner.ts): in the image PROTOCOL_OPS_TAG names, as
// build-docker.yaml runs it before releasing that image, else from this checkout.
runReleaseFlow()
  .then(() => {
    process.exit(0);
  })
  .catch((error) => {
    console.error("Release flow failed:", error.message || error);
    process.exit(1);
  });
