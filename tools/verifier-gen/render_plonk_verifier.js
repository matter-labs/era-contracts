// Render the snarkJS Plonk verifier for the ZiSK SNARK wrap.
//
// `snarkjs zkey export solidityverifier` renders this same template from the
// verification key it reads out of a `.zkey`. A ZiSK release ships that key on
// its own, so this script renders the template from the key directly and the
// full SNARK setup stays out of the build.
//
// Usage: node render_plonk_verifier.js <verification_key.json> <output.sol>
// Run `npm install` in this directory first.

const fs = require("fs");
const path = require("path");
const ejs = require("ejs");

const [vkeyPath, outputPath] = process.argv.slice(2);
if (!vkeyPath || !outputPath) {
  console.error("usage: node render_plonk_verifier.js <verification_key.json> <output.sol>");
  process.exit(1);
}

const templatePath = path.join(__dirname, "node_modules", "snarkjs", "templates", "verifier_plonk.sol.ejs");
const vkey = JSON.parse(fs.readFileSync(vkeyPath, "utf8"));
fs.writeFileSync(outputPath, ejs.render(fs.readFileSync(templatePath, "utf8"), vkey));
console.log(`Rendered ${outputPath} from ${vkeyPath}`);
