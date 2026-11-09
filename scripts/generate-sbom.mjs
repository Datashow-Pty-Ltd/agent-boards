import { execFile } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);
const root = path.resolve(".");
const destination = path.resolve(process.argv[2] ?? "release/sbom.cdx.json");
const manifest = JSON.parse(await readFile(path.join(root, "package.json"), "utf8"));
const { stdout } = await run("pnpm", ["list", "-r", "--prod", "--json", "--depth", "Infinity"], {
  cwd: root,
  maxBuffer: 20 * 1024 * 1024,
});
const workspaces = JSON.parse(stdout);
const components = new Map();
const dependencyGraph = new Map();

function purl(name, version) {
  const encodedName = name.startsWith("@")
    ? `${encodeURIComponent(name.split("/")[0])}/${name.split("/").slice(1).join("/")}`
    : name;
  return `pkg:npm/${encodedName}@${version}`;
}

function visitDependencies(dependencies = {}) {
  const refs = [];
  for (const [name, dependency] of Object.entries(dependencies)) {
    if (!dependency.version) continue;
    const ref = purl(name, dependency.version);
    refs.push(ref);
    if (!components.has(ref)) {
      const component = { type: "library", name, version: dependency.version, "bom-ref": ref, purl: ref };
      if (dependency.resolved) {
        component.externalReferences = [{ type: "distribution", url: dependency.resolved }];
      }
      components.set(ref, component);
    }
    const childRefs = visitDependencies(dependency.dependencies);
    const existing = dependencyGraph.get(ref) ?? new Set();
    childRefs.forEach((childRef) => existing.add(childRef));
    dependencyGraph.set(ref, existing);
  }
  return refs;
}

const rootRef = purl(manifest.name, manifest.version);
const rootDependencies = new Set();
for (const workspace of workspaces) {
  visitDependencies(workspace.dependencies).forEach((ref) => rootDependencies.add(ref));
}
dependencyGraph.set(rootRef, rootDependencies);

const document = {
  bomFormat: "CycloneDX",
  specVersion: "1.6",
  version: 1,
  metadata: {
    timestamp: new Date().toISOString(),
    tools: { components: [{ type: "application", name: "agent-boards-sbom-generator", version: manifest.version }] },
    component: { type: "application", name: manifest.name, version: manifest.version, "bom-ref": rootRef, purl: rootRef },
  },
  components: [...components.values()].sort((left, right) => left["bom-ref"].localeCompare(right["bom-ref"])),
  dependencies: [...dependencyGraph.entries()]
    .map(([ref, dependsOn]) => ({ ref, dependsOn: [...dependsOn].sort() }))
    .sort((left, right) => left.ref.localeCompare(right.ref)),
};

await mkdir(path.dirname(destination), { recursive: true });
await writeFile(destination, `${JSON.stringify(document, null, 2)}\n`);
process.stdout.write(`${destination} (${document.components.length} production components)\n`);
