// Machine check for the essential-specification comments (必須 32, 成功条件
// 10): every comment in src/domain/model is written in Japanese, and every
// type the type catalog (型一覧) shows carries an attached Japanese doc
// comment. The sim module, the UI and the tests keep English comments and
// are out of scope. The catalog side reads the same extractor the page
// uses, so "every displayed type has a comment" is checked on the real
// declarations, not on a hand-kept list.
import { describe, expect, it } from "vitest";
import { DOMAIN_SOURCES } from "../../src/ui/domainSources";
import { extractTypeGraph } from "../../src/ui/typeGraph";

const JAPANESE = /[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}]/u;

/**
 * Every comment of a source, as one text each: a block comment is one
 * comment; consecutive `//` lines (whether they open a line or trail code)
 * are one comment, so a formula line inside a header block does not stand
 * alone. Comment markers inside string literals are skipped.
 */
function commentsOf(source: string): { line: number; text: string }[] {
  const found: { line: number; text: string; block: boolean }[] = [];
  let i = 0;
  let line = 1;
  while (i < source.length) {
    const two = source.slice(i, i + 2);
    if (two === "//") {
      const end = source.indexOf("\n", i);
      const stop = end === -1 ? source.length : end;
      found.push({ line, text: source.slice(i + 2, stop), block: false });
      i = stop;
    } else if (two === "/*") {
      const end = source.indexOf("*/", i + 2);
      const stop = end === -1 ? source.length : end + 2;
      const text = source.slice(i, stop);
      found.push({ line, text, block: true });
      line += text.split("\n").length - 1;
      i = stop;
    } else if (source[i] === '"' || source[i] === "'" || source[i] === "`") {
      const quote = source[i];
      let k = i + 1;
      while (k < source.length && source[k] !== quote) {
        if (source[k] === "\\") k++;
        if (source[k] === "\n") line++;
        k++;
      }
      i = Math.min(k + 1, source.length);
    } else {
      if (source[i] === "\n") line++;
      i++;
    }
  }
  // Consecutive `//` lines form one comment.
  const out: { line: number; text: string }[] = [];
  let lastLineComment: { line: number; text: string; last: number } | undefined;
  for (const c of found) {
    if (c.block) {
      lastLineComment = undefined;
      out.push({ line: c.line, text: c.text });
    } else if (lastLineComment && c.line === lastLineComment.last + 1) {
      lastLineComment.text += `\n${c.text}`;
      lastLineComment.last = c.line;
    } else {
      lastLineComment = { line: c.line, text: c.text, last: c.line };
      out.push(lastLineComment);
    }
  }
  return out;
}

describe("本質的仕様モジュールのコメント (必須 32)", () => {
  it("bundles every model source", () => {
    expect(Object.keys(DOMAIN_SOURCES).length).toBeGreaterThan(10);
  });

  it("every comment in src/domain/model contains Japanese", () => {
    const englishOnly: string[] = [];
    for (const [module, source] of Object.entries(DOMAIN_SOURCES)) {
      for (const c of commentsOf(source)) {
        if (!JAPANESE.test(c.text)) {
          englishOnly.push(`${module}.ts:${c.line}: ${c.text.trim().split("\n")[0]}`);
        }
      }
    }
    expect(englishOnly, `comments without Japanese:\n${englishOnly.join("\n")}`).toEqual([]);
  });

  it("every type of the catalog carries an attached Japanese doc comment (成功条件 10)", () => {
    const nodes = extractTypeGraph(DOMAIN_SOURCES);
    expect(nodes.length).toBeGreaterThan(30);
    const missing: string[] = [];
    for (const node of nodes) {
      const declaration = node.declaration;
      const opensWithDoc = declaration.startsWith("/**");
      const docEnd = declaration.indexOf("*/");
      const doc = opensWithDoc && docEnd !== -1 ? declaration.slice(0, docEnd) : "";
      if (!opensWithDoc || !JAPANESE.test(doc)) {
        missing.push(`${node.module}.${node.name}`);
      }
    }
    expect(missing, `catalog types without a Japanese doc comment:\n${missing.join("\n")}`).toEqual([]);
  });
});
