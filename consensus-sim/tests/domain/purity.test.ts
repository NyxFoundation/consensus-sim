// Architectural boundary: the domain layer is pure. It must not import UI,
// infrastructure, React, or anything outside src/domain (ESSENCE.md, DDD).
import { describe, expect, it } from "vitest";

const sources = import.meta.glob("../../src/domain/**/*.ts", {
  query: "?raw",
  import: "default",
  eager: true,
}) as Record<string, string>;

describe("domain layer purity", () => {
  it("has source files", () => {
    expect(Object.keys(sources).length).toBeGreaterThan(0);
  });

  it("imports only from inside src/domain", () => {
    for (const [file, source] of Object.entries(sources)) {
      const specifiers = [...source.matchAll(/from\s+["']([^"']+)["']/g)].map(
        (m) => m[1],
      );
      for (const spec of specifiers) {
        expect(spec, `${file} imports ${spec}`).toMatch(/^\.\.?\//);
        expect(spec, `${file} escapes the domain layer via ${spec}`).not.toMatch(
          /^\.\.\//,
        );
      }
    }
  });
});
