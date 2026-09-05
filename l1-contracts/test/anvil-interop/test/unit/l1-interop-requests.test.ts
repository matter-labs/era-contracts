import * as assert from "assert/strict";
import { ethers } from "ethers";
import { getAbi } from "../../src/core/contracts";
import { encodeDirectInteropRequest, encodeIndirectInteropRequest, formatEvmV1 } from "../../src/core/interop-requests";
import { createSuite } from "./harness";

const { test, run } = createSuite("l1-interop-requests");
const recipient = "0x1111111111111111111111111111111111111111";
const attributes = new ethers.utils.Interface(getAbi("IERC7786Attributes"));
const params = {
  chainId: 256,
  mintValue: 123,
  l2Value: 7,
  l2GasLimit: 1000000,
  l2GasPerPubdataByteLimit: 800,
  refundRecipient: recipient,
};

test("formats canonical ERC-7930 chain-reference boundaries", () => {
  assert.equal(formatEvmV1(0, recipient), `0x00010000010014${recipient.slice(2)}`);
  assert.equal(formatEvmV1(256, recipient), `0x0001000002010014${recipient.slice(2)}`);
  assert.equal(
    formatEvmV1(ethers.constants.MaxUint256, recipient),
    `0x0001000020${"ff".repeat(32)}14${recipient.slice(2)}`
  );
});

test("direct calldata preserves value, dependencies and refund parameters", () => {
  const encoded = encodeDirectInteropRequest({
    ...params,
    l2Contract: recipient,
    l2Calldata: "0x12345678",
    factoryDeps: ["0xabcd"],
  });
  assert.equal(encoded.payload, "0x12345678");
  const parsed = encoded.attributes.map((data) => attributes.parseTransaction({ data }));
  assert.deepEqual(
    parsed.map((item) => item.name),
    ["l1ToL2TransactionParams", "interopCallValue", "factoryDeps"]
  );
  assert.deepEqual(parsed[0].args.map(String), ["123", "1000000", "800", recipient]);
  assert.equal(parsed[1].args[0].toString(), "7");
  assert.deepEqual(Array.from(parsed[2].args[0]), ["0xabcd"]);
});

test("indirect calldata keeps the source sender and its ETH value distinct", () => {
  const encoded = encodeIndirectInteropRequest({
    ...params,
    crossChainSender: recipient,
    indirectCallValue: 17,
    indirectCallData: "0xdeadbeef",
  });
  assert.equal(encoded.recipient, formatEvmV1(256, recipient));
  assert.equal(encoded.payload, "0xdeadbeef");
  const parsed = encoded.attributes.map((data) => attributes.parseTransaction({ data }));
  assert.deepEqual(
    parsed.map((item) => item.name),
    ["l1ToL2TransactionParams", "interopCallValue", "indirectCall"]
  );
  assert.equal(parsed[1].args[0].toString(), "7");
  assert.equal(parsed[2].args[0].toString(), "17");
});

run();
