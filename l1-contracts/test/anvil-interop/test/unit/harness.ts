/**
 * Minimal test runner shared by the unit suites, so each one is just its cases.
 *
 * Deliberately not mocha: these suites must run without hardhat or a network, and `ts-node file.ts`
 * keeps them usable from any directory and from a workflow step.
 */

type Case = [string, () => void];

export function createSuite(name: string): { test: (title: string, fn: () => void) => void; run: () => void } {
  const cases: Case[] = [];

  return {
    test: (title, fn) => cases.push([title, fn]),
    run: () => {
      let failed = 0;
      for (const [title, fn] of cases) {
        try {
          fn();
          console.log(`  ✓ ${title}`);
        } catch (error) {
          failed++;
          console.error(`  ✗ ${title}`);
          console.error(`    ${(error as Error).message}`);
        }
      }
      console.log(`\n${cases.length - failed}/${cases.length} ${name} tests passed`);
      if (failed > 0) process.exit(1);
    },
  };
}
