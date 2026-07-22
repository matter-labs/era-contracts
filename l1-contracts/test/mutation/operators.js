// SPDX-License-Identifier: MIT
"use strict";

/**
 * AST-based mutation operators for Solidity, tuned for the atomic-interop suite.
 *
 * Each operator inspects the parsed AST and emits zero or more mutation candidates. A candidate is a
 * pure text-span replacement `{ start, end, replacement }` (character offsets into the source, `end`
 * inclusive) plus metadata (operator name, human-readable description). The generator (generate.js)
 * applies the region filter, dedupes, and assigns ids.
 *
 * Operators implemented:
 *   ROR   relational operator replacement (boundary flip, logical complement, force true/false)
 *   COR   conditional/logical operator replacement (&& <-> ||, remove unary !)
 *   AOR   arithmetic/bitwise/shift operator replacement
 *   LVR   literal value replacement (numbers, booleans)
 *   ICR   increment/decrement replacement (++ <-> --)
 *   GRD   guard disabling (force an if-guard / require condition to not fire)
 *   SDL   statement deletion (assignments, emits, standalone calls)
 *   RVR   boolean return value replacement
 *   SWP   domain-specific symbol swap (begin/end leaf index, LegState members)
 */

const parser = require("@solidity-parser/parser");

/** Text of a node from its inclusive range. */
function nodeText(src, node) {
  return src.slice(node.range[0], node.range[1] + 1);
}

/**
 * Locate the operator token of a BinaryOperation between its two operands and return the absolute
 * offsets of that token. Relies on both operands carrying ranges.
 */
function operatorSpan(src, node) {
  if (!node.left || !node.right || !node.left.range || !node.right.range) return null;
  const gapStart = node.left.range[1] + 1;
  const gapEnd = node.right.range[0]; // exclusive
  const gap = src.slice(gapStart, gapEnd);
  const idx = gap.indexOf(node.operator);
  if (idx < 0) return null;
  return { start: gapStart + idx, end: gapStart + idx + node.operator.length - 1 };
}

const RELATIONAL = new Set(["<", "<=", ">", ">=", "==", "!="]);
const BOUNDARY = { "<": "<=", "<=": "<", ">": ">=", ">=": ">" };
const COMPLEMENT = { "<": ">=", ">=": "<", ">": "<=", "<=": ">", "==": "!=", "!=": "==" };
const ARITH = { "+": "-", "-": "+", "*": "/", "/": "*", "%": "*" };
const SHIFT = { ">>": "<<", "<<": ">>" };
const BITWISE = { "&": "|", "|": "&" };

/** True when an if-statement body is only a revert or a return — i.e. a guard. */
function isGuardBody(body) {
  if (!body) return false;
  let stmts;
  if (body.type === "Block") stmts = body.statements || [];
  else stmts = [body];
  if (stmts.length !== 1) return false;
  const s = stmts[0];
  return s.type === "RevertStatement" || s.type === "ReturnStatement";
}

/**
 * Generate all raw candidates for a source file.
 * @param {string} src Source text.
 * @param {object} opts { swapGroups: string[][] }
 * @returns {Array<{start:number,end:number,replacement:string,operator:string,description:string,orig:string}>}
 */
function generateCandidates(src, opts = {}) {
  const swapGroups = opts.swapGroups || [];
  const out = [];
  const push = (start, end, replacement, operator, description) => {
    const orig = src.slice(start, end + 1);
    if (orig === replacement) return; // no-op mutation
    out.push({ start, end, replacement, operator, description, orig });
  };

  let ast;
  try {
    ast = parser.parse(src, { loc: true, range: true, tolerant: true });
  } catch (e) {
    throw new Error("parse failed: " + e.message);
  }

  parser.visit(ast, {
    BinaryOperation(node) {
      const op = node.operator;

      // Assignments are handled by SDL (statement deletion), not operator replacement.
      if (op === "=") return;

      // --- ROR: relational -------------------------------------------------------------------
      if (RELATIONAL.has(op)) {
        const span = operatorSpan(src, node);
        if (span) {
          if (BOUNDARY[op]) {
            push(span.start, span.end, BOUNDARY[op], "ROR", `relational ${op} -> ${BOUNDARY[op]} (boundary)`);
          }
          if (COMPLEMENT[op]) {
            push(span.start, span.end, COMPLEMENT[op], "ROR", `relational ${op} -> ${COMPLEMENT[op]} (complement)`);
          }
        }
        // Force the whole comparison to a constant (guard always/never fires).
        push(node.range[0], node.range[1], "true", "ROR", `comparison (${op}) -> true`);
        push(node.range[0], node.range[1], "false", "ROR", `comparison (${op}) -> false`);
        return;
      }

      // --- COR: logical ----------------------------------------------------------------------
      if (op === "&&" || op === "||") {
        const span = operatorSpan(src, node);
        if (span) {
          const to = op === "&&" ? "||" : "&&";
          push(span.start, span.end, to, "COR", `logical ${op} -> ${to}`);
        }
        return;
      }

      // --- AOR: arithmetic / shift / bitwise -------------------------------------------------
      const arithMap = ARITH[op] ? ARITH : SHIFT[op] ? SHIFT : BITWISE[op] ? BITWISE : null;
      if (arithMap) {
        const span = operatorSpan(src, node);
        if (span) {
          const to = arithMap[op];
          push(span.start, span.end, to, "AOR", `arithmetic ${op} -> ${to}`);
        }
        return;
      }
    },

    UnaryOperation(node) {
      // --- ICR: ++ / -- ----------------------------------------------------------------------
      if (node.operator === "++" || node.operator === "--") {
        // Find the operator token (may be prefix or postfix). Search around the sub-expression.
        const sub = node.subExpression;
        if (sub && sub.range) {
          const to = node.operator === "++" ? "--" : "++";
          // Prefix: operator before sub; Postfix: operator after sub.
          if (node.isPrefix) {
            const start = node.range[0];
            push(start, start + 1, to, "ICR", `${node.operator} -> ${to}`);
          } else {
            const end = node.range[1];
            push(end - 1, end, to, "ICR", `${node.operator} -> ${to}`);
          }
        }
        return;
      }
      // --- COR: remove unary ! ---------------------------------------------------------------
      if (node.operator === "!" && node.isPrefix && node.subExpression && node.subExpression.range) {
        push(
          node.range[0],
          node.range[1],
          nodeText(src, node.subExpression),
          "COR",
          "remove unary ! (negate condition)"
        );
        return;
      }
    },

    NumberLiteral(node) {
      // --- LVR: numbers ----------------------------------------------------------------------
      const raw = (node.number || "").toString();
      // Skip hex and literals with subdenominations / underscores we can't safely arithmetic on.
      if (/^0x/i.test(raw) || node.subdenomination) return;
      if (!/^[0-9]+$/.test(raw)) return;
      const start = node.range[0];
      const end = start + raw.length - 1; // NumberLiteral range may include subdenomination; pin to digits
      let n;
      try {
        n = BigInt(raw);
      } catch {
        return;
      }
      if (n === 0n) {
        push(start, end, "1", "LVR", "number 0 -> 1");
      } else if (n === 1n) {
        push(start, end, "0", "LVR", "number 1 -> 0");
        push(start, end, "2", "LVR", "number 1 -> 2");
      } else {
        push(start, end, (n + 1n).toString(), "LVR", `number ${raw} -> ${n + 1n}`);
        push(start, end, (n - 1n).toString(), "LVR", `number ${raw} -> ${n - 1n}`);
        push(start, end, "0", "LVR", `number ${raw} -> 0`);
      }
    },

    BooleanLiteral(node) {
      // --- LVR: booleans ---------------------------------------------------------------------
      const to = node.value ? "false" : "true";
      push(node.range[0], node.range[1], to, "LVR", `boolean ${node.value} -> ${to}`);
    },

    IfStatement(node) {
      // --- GRD: disable a guard --------------------------------------------------------------
      if (isGuardBody(node.trueBody) && node.condition && node.condition.range) {
        const c = node.condition;
        // Force the guard to never fire. (Forcing it to always fire is trivially killed and noisy.)
        push(c.range[0], c.range[1], "false", "GRD", "disable if-guard (condition -> false)");
      }
    },

    FunctionCall(node) {
      // --- GRD: disable a require(cond, ...) --------------------------------------------------
      if (
        node.expression &&
        node.expression.type === "Identifier" &&
        node.expression.name === "require" &&
        node.arguments &&
        node.arguments.length >= 1 &&
        node.arguments[0].range
      ) {
        const cond = node.arguments[0];
        push(cond.range[0], cond.range[1], "true", "GRD", "disable require (condition -> true)");
      }
    },

    ReturnStatement(node) {
      // --- RVR: boolean return flip ----------------------------------------------------------
      const e = node.expression;
      if (e && e.type === "BooleanLiteral") {
        const to = e.value ? "false" : "true";
        push(e.range[0], e.range[1], to, "RVR", `return ${e.value} -> ${to}`);
      }
    },

    MemberAccess(node) {
      // --- SWP: domain-specific symbol swaps -------------------------------------------------
      for (const group of swapGroups) {
        if (group.includes(node.memberName)) {
          for (const sibling of group) {
            if (sibling === node.memberName) continue;
            // Replace only the member name token (after the dot).
            const start = node.range[1] - node.memberName.length + 1;
            const end = node.range[1];
            if (src.slice(start, end + 1) === node.memberName) {
              push(start, end, sibling, "SWP", `symbol ${node.memberName} -> ${sibling}`);
            }
          }
        }
      }
    },
  });

  // --- SDL: statement deletion (assignments, emits, standalone calls) -----------------------
  // Done via a second pass so we can look at ExpressionStatement / EmitStatement nodes with ranges.
  parser.visit(ast, {
    ExpressionStatement(node) {
      const e = node.expression;
      if (!e || !node.range) return;
      let isDeletable = false;
      let label = "";
      if (e.type === "BinaryOperation" && /^(=|\+=|-=|\*=|\/=|%=|\|=|&=|\^=)$/.test(e.operator)) {
        isDeletable = true;
        label = "assignment";
      } else if (e.type === "FunctionCall") {
        // Skip require/revert-style guards — deleting those is covered by GRD and would be trivial.
        const callee = e.expression;
        const name = callee && callee.type === "Identifier" ? callee.name : null;
        if (name !== "require" && name !== "assert" && name !== "revert") {
          isDeletable = true;
          label = "call";
        }
      }
      if (isDeletable) {
        // Replace the statement with an empty statement, preserving offsets minimally.
        push(node.range[0], node.range[1], "", "SDL", `delete ${label} statement`);
      }
    },
    EmitStatement(node) {
      if (node.range) {
        push(node.range[0], node.range[1], "", "SDL", "delete emit statement");
      }
    },
  });

  return out;
}

/**
 * Compute inclusive character offset ranges for the named functions in a source file. Used to
 * restrict mutation to atomic-only functions in large entry-point contracts.
 */
function functionRanges(src, functionNames) {
  const wanted = new Set(functionNames);
  const ranges = [];
  const ast = parser.parse(src, { loc: true, range: true, tolerant: true });
  parser.visit(ast, {
    FunctionDefinition(node) {
      if (node.name && wanted.has(node.name) && node.range) {
        ranges.push([node.range[0], node.range[1]]);
      }
    },
  });
  return ranges;
}

/** Given source, return {line, col} for a character offset (1-based line). */
function offsetToLine(src, offset) {
  let line = 1;
  for (let i = 0; i < offset && i < src.length; i++) {
    if (src[i] === "\n") line++;
  }
  return line;
}

module.exports = { generateCandidates, functionRanges, offsetToLine, nodeText };
