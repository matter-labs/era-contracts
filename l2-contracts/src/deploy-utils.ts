import * as fs from "fs";
import * as path from "path";

export const testConfigPath = path.join(process.env.ZKSYNC_HOME as string, "etc/test_config/constant");
export const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));
