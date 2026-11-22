// Run the pinned rft sources unchanged against their upstream alien adapter shape.
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const [rft, alien, caseId] = process.argv.slice(2);
if (!rft || !alien) {
  throw new Error("Usage: bun conformance/tool/js_baseline.ts <rft checkout> <alien checkout>");
}
const load = (root: string, path: string) => import(pathToFileURL(resolve(root, path)).href);
const { correctness, behaviors, runCase, runProbe } = await load(rft, "src/index.ts");
const lib = await load(alien, "src/index.ts");

const adapter = {
  name: "alien-signals",
  effectCleanup: true,
  signal(initial: unknown) {
    const signal = lib.signal(initial);
    return { read: () => signal(), write: (value: unknown) => signal(value) };
  },
  computed(read: () => unknown) {
    const computed = lib.computed(read);
    return { read: () => computed() };
  },
  effect: lib.effect,
  run(action: () => void) {
    lib.effectScope(action)();
  },
  batch(action: () => void) {
    lib.startBatch();
    try {
      action();
    } finally {
      lib.endBatch();
    }
  },
  untracked<T>(action: () => T): T {
    const previous = lib.setActiveSub(undefined);
    try {
      return action();
    } finally {
      lib.setActiveSub(previous);
    }
  },
};

if (caseId) {
  const test = correctness.flatMap((section) => section.cases).find((test) => test.id === Number(caseId));
  if (!test) throw new Error(`Unknown case #${caseId}`);
  console.log(JSON.stringify(runCase(adapter, test)));
} else {
  const results = [];
  for (const section of [...correctness, behaviors]) {
    const probe = section === behaviors;
    for (const test of section.cases) {
      let result;
      if (section.mayNotTerminate) {
        const child = Bun.spawn([process.execPath, import.meta.path, rft, alien, String(test.id)], {
          stdout: "pipe",
          stderr: "inherit",
          timeout: 5000,
          killSignal: "SIGKILL",
        });
        const output = await new Response(child.stdout).text();
        const code = await child.exited;
        result = code === 0 ? JSON.parse(output) : { status: "fail", error: `worker exit ${code}` };
      } else {
        result = (probe ? runProbe : runCase)(adapter, test);
      }
      results.push({ id: test.id, title: test.title, probe, ...result });
    }
  }
  console.log(JSON.stringify(results, null, 2));
}
