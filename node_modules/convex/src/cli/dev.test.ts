import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import path from "path";
import { nodeFs } from "../bundler/fs.js";
import { dev } from "./dev.js";
import { deploymentCredentialsOrConfigure } from "./configure.js";

// In-memory filesystem — populated in beforeEach.
let testFiles: Map<string, string>;
// Everything written to stderr during a test, so we can assert on error output.
let stderr: string;

vi.mock("../bundler/fs.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../bundler/fs.js")>();
  return {
    ...actual,
    nodeFs: {
      ...actual.nodeFs,
      exists: vi.fn(),
      readUtf8File: vi.fn(),
      writeUtf8File: vi.fn(),
      mkdir: vi.fn(),
    },
  };
});

// `deploymentCredentialsOrConfigure` is where the CLI prompts the user to
// create or select a project. We stub it out so we can assert *whether* it gets
// reached — the whole point of the fast-fail check is that it should not.
vi.mock("./configure.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./configure.js")>();
  return {
    ...actual,
    deploymentCredentialsOrConfigure: vi.fn(),
  };
});

// Avoid actually pushing if the action ever gets that far.
vi.mock("./lib/dev.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./lib/dev.js")>();
  return {
    ...actual,
    devAgainstDeployment: vi.fn(),
  };
});

vi.mock("dotenv", async (importOriginal) => {
  const actual = await importOriginal<typeof import("dotenv")>();
  return {
    ...actual,
    config: vi.fn(),
  };
});

vi.mock("@sentry/node", () => ({
  captureException: vi.fn(),
  captureMessage: vi.fn(),
  close: vi.fn(),
}));

describe("npx convex dev", () => {
  let savedEnv: NodeJS.ProcessEnv;

  beforeEach(() => {
    savedEnv = { ...process.env };
    process.env = {};

    testFiles = new Map();
    stderr = "";

    vi.resetAllMocks();

    vi.mocked(nodeFs.exists).mockImplementation((p: string) =>
      testFiles.has(path.resolve(p)),
    );
    vi.mocked(nodeFs.readUtf8File).mockImplementation((p: string) => {
      const content = testFiles.get(path.resolve(p));
      if (content === undefined) {
        const err: any = new Error(
          `ENOENT: no such file or directory, open '${p}'`,
        );
        err.code = "ENOENT";
        throw err;
      }
      return content;
    });
    vi.mocked(nodeFs.writeUtf8File).mockImplementation(
      (p: string, content: string) => {
        testFiles.set(path.resolve(p), content);
      },
    );

    // `crash` calls `process.exit`; make it throw so `parseAsync` rejects.
    vi.spyOn(process, "exit").mockImplementation((() => {
      throw new Error("the CLI tried to exit the process");
    }) as any);
    vi.spyOn(process.stderr, "write").mockImplementation((chunk: any) => {
      stderr += chunk.toString();
      return true;
    });
  });

  afterEach(() => {
    process.env = savedEnv;
    vi.restoreAllMocks();
  });

  it("fails fast without prompting to create/select a project when run outside a Convex project", async () => {
    // A package.json with no `convex` dependency: this directory is not a
    // Convex project.
    testFiles.set(
      path.resolve("package.json"),
      JSON.stringify({ name: "not-a-convex-app", dependencies: {} }),
    );

    await expect(dev.parseAsync([], { from: "user" })).rejects.toThrow(
      "the CLI tried to exit the process",
    );

    // The error must mention how to fix it...
    expect(stderr).toContain("add `convex` to your package.json");
    // ...and crucially, it must happen *before* we ever ask the user to create
    // or select a project.
    expect(deploymentCredentialsOrConfigure).not.toHaveBeenCalled();
  });

  it("fails fast when there is no package.json at all", async () => {
    // Empty directory: no package.json.
    await expect(dev.parseAsync([], { from: "user" })).rejects.toThrow(
      "the CLI tried to exit the process",
    );

    expect(deploymentCredentialsOrConfigure).not.toHaveBeenCalled();
  });

  it("proceeds to project configuration once the Convex dependency check passes", async () => {
    testFiles.set(
      path.resolve("package.json"),
      JSON.stringify({
        name: "convex-app",
        dependencies: { convex: "^1.0.0" },
      }),
    );

    // Short-circuit right at the project-selection step so we don't run the
    // rest of the dev flow; reaching this proves the dependency check passed.
    const sentinel = new Error("reached project configuration");
    vi.mocked(deploymentCredentialsOrConfigure).mockRejectedValue(sentinel);

    // `--configure` skips deployment selection and goes straight to
    // `deploymentCredentialsOrConfigure`.
    await expect(
      dev.parseAsync(["--configure"], { from: "user" }),
    ).rejects.toThrow("reached project configuration");

    expect(deploymentCredentialsOrConfigure).toHaveBeenCalledTimes(1);
  });
});
