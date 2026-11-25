// Runs the three parts in a row. `docker compose run --rm demo` runs this once the chains are ready.
import { main as call } from "./call";
import { main as refund } from "./refund";
import { main as swap } from "./swap";

async function demo() {
  console.log("\n== Part 1: an atomic cross-chain call from chain A (506) to chain B (507)\n");
  await call();
  console.log("\n== Part 2: a missed deadline and a refund (waits about 30 seconds for the deadline)\n");
  await refund();
  console.log("\n== Part 3: an atomic token swap between chain A and chain B\n");
  await swap();
  console.log(
    "\nAll three flows completed. The chains keep running: try `npm run call`, or stop them with `docker compose down`."
  );
}

demo().catch((e) => {
  console.error(e);
  process.exit(1);
});
