#!/usr/bin/env node

/**
 * Runs the unit suites in one process, so there is one script rather than one per suite and one
 * ts-node startup rather than six.
 *
 * Each suite file calls its own `run()` at import, which reports its cases and sets `process.exitCode`
 * on failure — so requiring them in turn is all this has to do.
 *
 * Usage:
 *   yarn test:unit            all suites
 *   yarn test:unit trace       only suites whose filename contains "trace"
 */

import * as fs from "fs";
import * as path from "path";

const suiteDir = __dirname;
const filter = process.argv[2];

const suites = fs
  .readdirSync(suiteDir)
  .filter((f) => f.endsWith(".test.ts"))
  .filter((f) => !filter || f.includes(filter))
  .sort();

if (suites.length === 0) {
  console.error(filter ? `No unit suite matches "${filter}"` : `No unit suites found in ${suiteDir}`);
  process.exit(1);
}

for (const suite of suites) {
  console.log(`\n── ${suite}`);
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires -- sequential, by design
    require(path.join(suiteDir, suite));
  } catch (error) {
    // A suite that throws outside a case (bad import, module-level setup) would otherwise abort the
    // whole run and hide the suites after it.
    console.error(`  ✗ ${suite} failed to run`);
    console.error(`    ${(error as Error).message}`);
    process.exitCode = 1;
  }
}
