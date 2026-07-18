import { describe, test, expect, vi, beforeEach, afterEach } from "vitest";
import path from "path";
import { nodeFs } from "../bundler/fs.js";
import { deploymentTokenCreate } from "./deploymentTokenCreate.js";
import { deploymentTokenDelete } from "./deploymentTokenDelete.js";
import { typedPlatformClient } from "./lib/utils/utils.js";
import {
  getDeploymentSelection,
  initializeBigBrainAuth,
} from "./lib/deploymentSelection.js";
import { loadSelectedDeploymentCredentials } from "./lib/api.js";
import type { Context } from "../bundler/context.js";

vi.mock("@sentry/node", () => ({
  captureException: vi.fn(),
  close: vi.fn(),
}));

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

const mockPlatformPost = vi.fn();

vi.mock("./lib/utils/utils.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./lib/utils/utils.js")>();
  return {
    ...actual,
    typedPlatformClient: vi.fn(() => ({ POST: mockPlatformPost })),
  };
});

vi.mock("./lib/deploymentSelection.js", async (importOriginal) => {
  const actual =
    await importOriginal<typeof import("./lib/deploymentSelection.js")>();
  return {
    ...actual,
    initializeBigBrainAuth: vi.fn(),
    getDeploymentSelection: vi.fn(),
  };
});

vi.mock("./lib/api.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./lib/api.js")>();
  return {
    ...actual,
    loadSelectedDeploymentCredentials: vi.fn(),
  };
});

// Default in-memory FS used when not overridden by a specific test.
let testFiles: Map<string, string>;
let consoleLogSpy: ReturnType<typeof vi.spyOn>;

function setAuthKind(
  kind: "accessToken" | "deploymentKey" | "projectKey" | "previewDeployKey",
) {
  vi.mocked(initializeBigBrainAuth).mockImplementation(async (ctx) => {
    const fakeAuth =
      kind === "accessToken"
        ? {
            kind: "accessToken" as const,
            accessToken: "test-token",
            header: "Bearer test-token",
          }
        : kind === "deploymentKey"
          ? {
              kind: "deploymentKey" as const,
              deploymentKey: "dev:foo|secret",
              header: "Bearer dev:foo|secret",
            }
          : kind === "projectKey"
            ? {
                kind: "projectKey" as const,
                projectKey: "project:foo|secret",
                header: "Bearer project:foo|secret",
              }
            : {
                kind: "previewDeployKey" as const,
                previewDeployKey: "preview:t:p|secret",
                header: "Bearer preview:t:p|secret",
              };
    (ctx as Context)._updateBigBrainAuth(fakeAuth);
  });
}

function setNoAuth() {
  vi.mocked(initializeBigBrainAuth).mockImplementation(async (ctx) => {
    (ctx as Context)._updateBigBrainAuth(null);
  });
}

function mockSelectedDeployment(
  deploymentName: string,
  deploymentType: "dev" | "prod" | "preview" | "custom" | "local" | "anonymous",
) {
  const reference =
    deploymentType === "local" || deploymentType === "anonymous"
      ? null
      : deploymentType === "dev"
        ? "dev/nicolas"
        : deploymentType === "prod"
          ? "production"
          : deploymentType === "preview"
            ? "preview/pr-42"
            : "my-custom-ref";
  vi.mocked(getDeploymentSelection).mockResolvedValue({
    kind: "existingDeployment",
    deploymentToActOn: {
      url: `https://${deploymentName}.convex.cloud`,
      adminKey: "admin-key",
      source: "deployKey",
      deploymentFields: {
        deploymentName,
        deploymentType,
        teamSlug: "my-team",
        projectSlug: "my-project",
        reference,
        isDefault: false,
      },
    },
  });
  vi.mocked(loadSelectedDeploymentCredentials).mockResolvedValue({
    url: `https://${deploymentName}.convex.cloud`,
    adminKey: "admin-key",
    deploymentFields: {
      deploymentName,
      deploymentType,
      teamSlug: "my-team",
      projectSlug: "my-project",
      reference,
      isDefault: false,
    },
  });
}

beforeEach(() => {
  vi.resetAllMocks();

  // Set up an in-memory FS that the env-file write/read paths can use.
  testFiles = new Map();
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

  vi.mocked(typedPlatformClient).mockReturnValue({
    POST: mockPlatformPost,
  } as any);
  mockPlatformPost.mockReset();

  vi.spyOn(process, "exit").mockImplementation((() => {
    throw new Error("process.exit called");
  }) as any);
  vi.spyOn(process.stderr, "write").mockImplementation(() => true);
  // logOutput uses console.log, so spy on it (not stdout.write).
  consoleLogSpy = vi.spyOn(console, "log").mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("deployment token create", () => {
  test.each(["deploymentKey", "projectKey", "previewDeployKey"] as const)(
    "crashes when authed with a %s instead of a personal access token",
    async (kind) => {
      setAuthKind(kind);
      mockSelectedDeployment("joyful-capybara-123", "dev");

      await expect(
        deploymentTokenCreate.parseAsync(["my-token"], { from: "user" }),
      ).rejects.toThrow();
      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining(
          "requires being logged in with a personal access token",
        ),
      );
      expect(mockPlatformPost).not.toHaveBeenCalled();
    },
  );

  test("crashes when no auth is configured at all", async () => {
    setNoAuth();
    mockSelectedDeployment("joyful-capybara-123", "dev");

    await expect(
      deploymentTokenCreate.parseAsync(["my-token"], { from: "user" }),
    ).rejects.toThrow();
    expect(mockPlatformPost).not.toHaveBeenCalled();
  });

  test("rejects local deployments client-side", async () => {
    setAuthKind("accessToken");
    mockSelectedDeployment("local-deployment", "local");

    await expect(
      deploymentTokenCreate.parseAsync(["my-token"], { from: "user" }),
    ).rejects.toThrow();
    expect(process.stderr.write).toHaveBeenCalledWith(
      expect.stringContaining("Cannot create a deploy key for a local"),
    );
    expect(mockPlatformPost).not.toHaveBeenCalled();
  });

  test("prints the new deploy key to stdout when --save-env is omitted", async () => {
    setAuthKind("accessToken");
    mockSelectedDeployment("joyful-capybara-123", "dev");
    mockPlatformPost.mockResolvedValue({
      data: { deployKey: "dev:joyful-capybara-123|new-token" },
    });

    await deploymentTokenCreate.parseAsync(["my-token"], { from: "user" });

    expect(mockPlatformPost).toHaveBeenCalledWith(
      "/deployments/{deployment_name}/create_deploy_key",
      {
        params: { path: { deployment_name: "joyful-capybara-123" } },
        body: { name: "my-token" },
      },
    );
    expect(consoleLogSpy).toHaveBeenCalledWith(
      "dev:joyful-capybara-123|new-token",
    );
    // .env.local should not have been written.
    expect(testFiles.has(path.resolve(".env.local"))).toBe(false);
  });

  test("--save-env writes the key to .env.local by default", async () => {
    setAuthKind("accessToken");
    mockSelectedDeployment("joyful-capybara-123", "dev");
    mockPlatformPost.mockResolvedValue({
      data: { deployKey: "dev:joyful-capybara-123|new-token" },
    });

    await deploymentTokenCreate.parseAsync(["my-token", "--save-env"], {
      from: "user",
    });

    const written = testFiles.get(path.resolve(".env.local"));
    expect(written).toContain(
      "CONVEX_DEPLOY_KEY=dev:joyful-capybara-123|new-token",
    );
    // The raw deploy key shouldn't have been printed to stdout.
    expect(consoleLogSpy).not.toHaveBeenCalled();
  });

  test("--save-env <path> writes to a custom env file", async () => {
    setAuthKind("accessToken");
    mockSelectedDeployment("joyful-capybara-123", "dev");
    mockPlatformPost.mockResolvedValue({
      data: { deployKey: "dev:joyful-capybara-123|new-token" },
    });

    await deploymentTokenCreate.parseAsync(
      ["ci-token", "--save-env", ".env.production"],
      { from: "user" },
    );

    expect(testFiles.has(path.resolve(".env.local"))).toBe(false);
    const written = testFiles.get(path.resolve(".env.production"));
    expect(written).toContain(
      "CONVEX_DEPLOY_KEY=dev:joyful-capybara-123|new-token",
    );
  });

  test("--save-env replaces an existing CONVEX_DEPLOY_KEY in the file", async () => {
    setAuthKind("accessToken");
    mockSelectedDeployment("joyful-capybara-123", "dev");
    mockPlatformPost.mockResolvedValue({
      data: { deployKey: "dev:joyful-capybara-123|new-token" },
    });
    testFiles.set(
      path.resolve(".env.local"),
      "FOO=bar\nCONVEX_DEPLOY_KEY=dev:joyful-capybara-123|old-token\n",
    );

    await deploymentTokenCreate.parseAsync(["my-token", "--save-env"], {
      from: "user",
    });

    const written = testFiles.get(path.resolve(".env.local"));
    expect(written).toContain("FOO=bar");
    expect(written).toContain(
      "CONVEX_DEPLOY_KEY=dev:joyful-capybara-123|new-token",
    );
    expect(written).not.toContain("old-token");
  });
});

describe("deployment token delete", () => {
  test.each(["deploymentKey", "projectKey", "previewDeployKey"] as const)(
    "crashes when authed with a %s instead of a personal access token",
    async (kind) => {
      setAuthKind(kind);
      mockSelectedDeployment("joyful-capybara-123", "dev");

      await expect(
        deploymentTokenDelete.parseAsync(["my-token"], { from: "user" }),
      ).rejects.toThrow();
      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining(
          "requires being logged in with a personal access token",
        ),
      );
      expect(mockPlatformPost).not.toHaveBeenCalled();
    },
  );

  test("sends the friendly name as-is when no `|` is present", async () => {
    setAuthKind("accessToken");
    mockSelectedDeployment("joyful-capybara-123", "dev");
    mockPlatformPost.mockResolvedValue({ data: undefined });

    await deploymentTokenDelete.parseAsync(["my-token"], { from: "user" });

    expect(mockPlatformPost).toHaveBeenCalledWith(
      "/deployments/{deployment_name}/delete_deploy_key",
      {
        params: { path: { deployment_name: "joyful-capybara-123" } },
        body: { id: "my-token" },
      },
    );
  });

  test("strips the deploy-key prefix before sending to the server", async () => {
    setAuthKind("accessToken");
    mockSelectedDeployment("joyful-capybara-123", "dev");
    mockPlatformPost.mockResolvedValue({ data: undefined });

    await deploymentTokenDelete.parseAsync(
      ["dev:joyful-capybara-123|the-secret-token"],
      { from: "user" },
    );

    expect(mockPlatformPost).toHaveBeenCalledWith(
      "/deployments/{deployment_name}/delete_deploy_key",
      {
        params: { path: { deployment_name: "joyful-capybara-123" } },
        body: { id: "the-secret-token" },
      },
    );
  });

  test("warns and crashes when the value looks like an unquoted partial deploy key", async () => {
    setAuthKind("accessToken");
    mockSelectedDeployment("joyful-capybara-123", "dev");

    await expect(
      deploymentTokenDelete.parseAsync(["dev:joyful-capybara-123"], {
        from: "user",
      }),
    ).rejects.toThrow();
    expect(process.stderr.write).toHaveBeenCalledWith(
      expect.stringContaining("looks like a partial deploy key"),
    );
    expect(mockPlatformPost).not.toHaveBeenCalled();
  });

  test("rejects local deployments client-side", async () => {
    setAuthKind("accessToken");
    mockSelectedDeployment("local-deployment", "local");

    await expect(
      deploymentTokenDelete.parseAsync(["my-token"], { from: "user" }),
    ).rejects.toThrow();
    expect(process.stderr.write).toHaveBeenCalledWith(
      expect.stringContaining("Cannot delete a deploy key for a local"),
    );
    expect(mockPlatformPost).not.toHaveBeenCalled();
  });
});
