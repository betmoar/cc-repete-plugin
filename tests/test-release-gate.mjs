// Tests for scripts/release-gate.mjs (run: node --test tests/test-release-gate.mjs).
// The gate is exercised for real only on a tag push — the worst moment to first
// discover a regression (2026-08-31 audit F06) — so it gets a suite like everything else.
// Fixtures are written to a temp dir; gate(root, tag) and extractSection are
// imported (the CLI guard in the script keeps main() from running on import).
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { gate, extractSection } from "../scripts/release-gate.mjs";

function fixture({ pluginVersion = "0.3.0", changelog }) {
	const root = mkdtempSync(join(tmpdir(), "rg-"));
	mkdirSync(join(root, ".claude-plugin"));
	writeFileSync(
		join(root, ".claude-plugin", "plugin.json"),
		JSON.stringify({ name: "cc-repete", version: pluginVersion }),
	);
	if (changelog != null) writeFileSync(join(root, "CHANGELOG.md"), changelog);
	return root;
}

const GOOD_CHANGELOG = `# Changelog
header prose.

## [0.3.0] — 2026-09-01

### Fixed
- first note line
[MEASURED: benchmark] a body line starting with a bracket
- last note line

## [0.2.1] — 2026-08-30
older notes

[Unreleased]: https://example.com/compare/v0.3.0...HEAD
[0.3.0]: https://example.com/compare/v0.2.1...v0.3.0
`;

test("happy path: tag == plugin.json == newest heading, notes extracted", () => {
	const root = fixture({ changelog: GOOD_CHANGELOG });
	const { problems, notes } = gate(root, "v0.3.0");
	assert.deepEqual(problems, []);
	assert.ok(notes.includes("first note line"));
	assert.ok(notes.includes("last note line"));
	assert.ok(!notes.includes("older notes"));
	rmSync(root, { recursive: true, force: true });
});

test("F07: a body line starting with '[' does not truncate the notes; the link-ref block does stop them", () => {
	const root = fixture({ changelog: GOOD_CHANGELOG });
	const { notes } = gate(root, "v0.3.0");
	assert.ok(notes.includes("[MEASURED: benchmark]"), "bracket-leading body line must stay in the notes");
	assert.ok(!notes.includes("[Unreleased]:"), "link-reference block must not leak into the notes");
	rmSync(root, { recursive: true, force: true });
});

test("malformed tag is rejected with guidance", () => {
	const root = fixture({ changelog: GOOD_CHANGELOG });
	const { problems } = gate(root, "0.3.0");
	assert.equal(problems.length, 1);
	assert.match(problems[0], /not v<x\.y\.z>/);
	rmSync(root, { recursive: true, force: true });
});

test("tag != plugin.json version fails", () => {
	const root = fixture({ pluginVersion: "0.2.9", changelog: GOOD_CHANGELOG });
	const { problems } = gate(root, "v0.3.0");
	assert.ok(problems.some((p) => p.includes("plugin.json")));
	rmSync(root, { recursive: true, force: true });
});

test("tag version not the newest CHANGELOG heading fails", () => {
	const root = fixture({
		pluginVersion: "0.2.1",
		changelog: GOOD_CHANGELOG, // newest heading is 0.3.0
	});
	const { problems } = gate(root, "v0.2.1");
	assert.ok(problems.some((p) => p.includes("newest CHANGELOG heading")));
	rmSync(root, { recursive: true, force: true });
});

test("an '## [Unreleased]' heading is not a semver heading and does not confuse the gate", () => {
	const root = fixture({
		changelog: `# Changelog\n\n## [Unreleased]\n- pending\n\n${GOOD_CHANGELOG.split("# Changelog\nheader prose.\n")[1]}`,
	});
	const { problems } = gate(root, "v0.3.0");
	assert.deepEqual(problems, []);
	rmSync(root, { recursive: true, force: true });
});

test("empty section for the tagged version fails (notes are the release body)", () => {
	const root = fixture({
		changelog: `# Changelog\n## [0.3.0] — 2026-09-01\n## [0.2.1] — 2026-08-30\nold\n`,
	});
	const { problems } = gate(root, "v0.3.0");
	assert.ok(problems.some((p) => p.includes("empty")));
	rmSync(root, { recursive: true, force: true });
});

test("missing CHANGELOG.md fails loud", () => {
	const root = fixture({ changelog: null });
	const { problems } = gate(root, "v0.3.0");
	assert.ok(problems.some((p) => p.includes("CHANGELOG.md")));
	rmSync(root, { recursive: true, force: true });
});

test("extractSection: unknown version yields empty string", () => {
	assert.equal(extractSection(GOOD_CHANGELOG, "9.9.9"), "");
});
