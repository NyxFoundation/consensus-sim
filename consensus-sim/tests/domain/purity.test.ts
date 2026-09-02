// Architectural boundaries: the domain layer is pure — it must not import
// UI, infrastructure, React, or anything outside src/domain (ESSENCE.md,
// DDD) — and it is two modules with a one-way dependency: sim/ (the
// simulator's constraints) may import model/ (the essential specification),
// model/ never imports sim/. The type catalog (型一覧) bundles model/ only.
import { describe, expect, it } from "vitest";

const sources = import.meta.glob("../../src/domain/**/*.ts", {
  query: "?raw",
  import: "default",
  eager: true,
}) as Record<string, string>;

const modelSources = import.meta.glob("../../src/domain/model/*.ts", {
  query: "?raw",
  import: "default",
  eager: true,
}) as Record<string, string>;

const specifiersOf = (source: string): string[] =>
  [...source.matchAll(/from\s+["']([^"']+)["']/g)].map((m) => m[1]!);

describe("domain layer purity", () => {
  it("has source files in both modules", () => {
    const files = Object.keys(sources);
    expect(files.some((f) => f.includes("/model/"))).toBe(true);
    expect(files.some((f) => f.includes("/sim/"))).toBe(true);
  });

  it("imports only from inside src/domain", () => {
    for (const [file, source] of Object.entries(sources)) {
      for (const spec of specifiersOf(source)) {
        expect(spec, `${file} imports ${spec}`).toMatch(/^\.\.?\//);
        expect(spec, `${file} escapes the domain layer via ${spec}`).not.toMatch(
          /^\.\.\/\.\.\//,
        );
        expect(spec, `${file} escapes the domain layer via ${spec}`).not.toMatch(
          /^\.\.\/(?!model\/|sim\/)/,
        );
      }
    }
  });

  it("model/ (本質的仕様) never imports sim/ (シミュレーション上の制約)", () => {
    for (const [file, source] of Object.entries(modelSources)) {
      for (const spec of specifiersOf(source)) {
        expect(spec, `${file} reaches into sim via ${spec}`).toMatch(/^\.\//);
      }
    }
  });

  it("every domain file is re-exported by the index, and nothing else is", () => {
    const index = sources["../../src/domain/index.ts"] ?? "";
    const exported = [...index.matchAll(/from\s+"\.\/(model|sim)\/(\w+)"/g)].map(
      (m) => `../../src/domain/${m[1]}/${m[2]}.ts`,
    );
    const files = Object.keys(sources).filter((f) => !f.endsWith("/index.ts"));
    expect(exported.sort()).toEqual(files.sort());
  });
});
