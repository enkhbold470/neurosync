import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { nodeFs } from "../bundler/fs.js";
import { env } from "./env.js";
import { bigBrainAPI, bigBrainAPIMaybeThrows } from "./lib/utils/utils.js";
import { readGlobalConfig } from "./lib/utils/globalConfig.js";

vi.mock("../bundler/fs.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../bundler/fs.js")>();
  return {
    ...actual,
    nodeFs: {
      ...actual.nodeFs,
      exists: vi.fn().mockImplementation(() => {
        throw new Error("nodeFs.exists should be mocked in test");
      }),
      readUtf8File: vi.fn().mockImplementation(() => {
        throw new Error("nodeFs.readUtf8File should be mocked in test");
      }),
    },
  };
});

const mockPlatformGet = vi.fn();
const mockPlatformPost = vi.fn();

vi.mock("./lib/utils/utils.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./lib/utils/utils.js")>();
  return {
    ...actual,
    deploymentFetch: vi.fn(),
    ensureHasConvexDependency: vi.fn(),
    bigBrainAPI: vi.fn(),
    bigBrainAPIMaybeThrows: vi.fn(),
    validateOrSelectTeam: vi.fn(),
    validateOrSelectProject: vi.fn(),
    typedPlatformClient: vi.fn(() => ({
      GET: mockPlatformGet,
      POST: mockPlatformPost,
    })),
  };
});

vi.mock("./lib/utils/globalConfig.js", async (importOriginal) => {
  const actual =
    await importOriginal<typeof import("./lib/utils/globalConfig.js")>();
  return {
    ...actual,
    readGlobalConfig: vi.fn().mockReturnValue(null),
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
  close: vi.fn(),
}));

function setupBigBrainRoutes(routes: Record<string, (data?: any) => any>) {
  const handler = (args: { path: string; data?: any }) => {
    for (const [routePath, routeHandler] of Object.entries(routes)) {
      if (args.path === routePath || args.path.startsWith(routePath)) {
        return routeHandler(args.data);
      }
    }
    throw new Error(`Unmocked Big Brain route: ${args.path}`);
  };
  vi.mocked(bigBrainAPI).mockImplementation(handler as any);
  vi.mocked(bigBrainAPIMaybeThrows).mockImplementation(handler as any);
}

describe("env default", () => {
  let savedEnv: NodeJS.ProcessEnv;
  let savedIsTTY: boolean | undefined;

  beforeEach(() => {
    savedEnv = { ...process.env };
    savedIsTTY = process.stdin.isTTY;
    process.env = {};
    process.stdin.isTTY = true as any;

    vi.resetAllMocks();
    vi.mocked(readGlobalConfig).mockReturnValue(null);
    vi.mocked(nodeFs.exists).mockReturnValue(false);

    mockPlatformGet.mockReset();
    mockPlatformPost.mockReset();
  });

  afterEach(() => {
    process.env = savedEnv;
    process.stdin.isTTY = savedIsTTY as any;
  });

  beforeEach(() => {
    vi.spyOn(process, "exit").mockImplementation((() => {
      throw new Error("process.exit called");
    }) as any);
    vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    vi.spyOn(process.stdout, "write").mockImplementation(() => true);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  function setupDefaultEnvPlatformMocks({
    projectId = 42,
    teamSlug = "my-team",
    projectSlug = "my-project",
  }: {
    projectId?: number;
    teamSlug?: string;
    projectSlug?: string;
  } = {}) {
    mockPlatformGet.mockImplementation((path: string, _opts: any) => {
      if (path === "/teams/{team_id_or_slug}/projects/{project_slug}") {
        return {
          data: {
            id: projectId,
            slug: projectSlug,
            name: projectSlug,
            teamId: 1,
            teamSlug,
            createTime: 0,
          },
        };
      }
      if (
        path === "/projects/{project_id}/list_default_environment_variables"
      ) {
        return { data: { items: [] } };
      }
      throw new Error(`Unmocked platform GET: ${path}`);
    });
    mockPlatformPost.mockImplementation(async (path: string, _opts: any) => {
      if (
        path === "/projects/{project_id}/update_default_environment_variables"
      ) {
        return { data: {} };
      }
      throw new Error(`Unmocked platform POST: ${path}`);
    });
  }

  describe("default behavior (no --type, no --project)", () => {
    it("uses current deployment's project and inferred dtype", async () => {
      process.env.CONVEX_DEPLOYMENT = "dev:foo-bar-123";
      vi.mocked(readGlobalConfig).mockReturnValue({
        accessToken: "test-token",
      });
      setupBigBrainRoutes({
        "deployment/foo-bar-123/team_and_project": () => ({
          team: "my-team",
          project: "my-project",
          teamId: 1,
          projectId: 42,
        }),
        "deployment/authorize_within_current_project": () => ({
          adminKey: "dev-key",
          url: "https://foo-bar-123.convex.cloud",
          deploymentName: "foo-bar-123",
          deploymentType: "dev",
        }),
      });
      setupDefaultEnvPlatformMocks({ projectId: 42 });

      await env.parseAsync(["default", "set", "ABC", "DEF"], { from: "user" });

      expect(mockPlatformPost).toHaveBeenCalledWith(
        "/projects/{project_id}/update_default_environment_variables",
        expect.objectContaining({
          params: { path: { project_id: 42 } },
          body: {
            changes: [{ name: "ABC", deploymentType: "dev", value: "DEF" }],
          },
        }),
      );
    });
  });

  describe("--type override", () => {
    it("--type prod overrides dtype, still uses current deployment's project", async () => {
      process.env.CONVEX_DEPLOYMENT = "dev:foo-bar-123";
      vi.mocked(readGlobalConfig).mockReturnValue({
        accessToken: "test-token",
      });
      setupBigBrainRoutes({
        "deployment/foo-bar-123/team_and_project": () => ({
          team: "my-team",
          project: "my-project",
          teamId: 1,
          projectId: 42,
        }),
        "deployment/authorize_within_current_project": () => ({
          adminKey: "dev-key",
          url: "https://foo-bar-123.convex.cloud",
          deploymentName: "foo-bar-123",
          deploymentType: "dev",
        }),
      });
      setupDefaultEnvPlatformMocks({ projectId: 42 });

      await env.parseAsync(["default", "set", "ABC", "DEF", "--type", "prod"], {
        from: "user",
      });

      expect(mockPlatformPost).toHaveBeenCalledWith(
        "/projects/{project_id}/update_default_environment_variables",
        expect.objectContaining({
          params: { path: { project_id: 42 } },
          body: {
            changes: [{ name: "ABC", deploymentType: "prod", value: "DEF" }],
          },
        }),
      );
    });

    it("--type production aliases to prod", async () => {
      process.env.CONVEX_DEPLOYMENT = "dev:foo-bar-123";
      vi.mocked(readGlobalConfig).mockReturnValue({
        accessToken: "test-token",
      });
      setupBigBrainRoutes({
        "deployment/foo-bar-123/team_and_project": () => ({
          team: "my-team",
          project: "my-project",
          teamId: 1,
          projectId: 42,
        }),
        "deployment/authorize_within_current_project": () => ({
          adminKey: "dev-key",
          url: "https://foo-bar-123.convex.cloud",
          deploymentName: "foo-bar-123",
          deploymentType: "dev",
        }),
      });
      setupDefaultEnvPlatformMocks({ projectId: 42 });

      await env.parseAsync(["default", "list", "--type", "production"], {
        from: "user",
      });

      expect(mockPlatformGet).toHaveBeenCalledWith(
        "/projects/{project_id}/list_default_environment_variables",
        expect.objectContaining({
          params: {
            path: { project_id: 42 },
            query: { deploymentType: "prod" },
          },
        }),
      );
    });

    it("--type development aliases to dev", async () => {
      process.env.CONVEX_DEPLOYMENT = "prod:foo-bar-123";
      vi.mocked(readGlobalConfig).mockReturnValue({
        accessToken: "test-token",
      });
      setupBigBrainRoutes({
        "deployment/foo-bar-123/team_and_project": () => ({
          team: "my-team",
          project: "my-project",
          teamId: 1,
          projectId: 42,
        }),
        "deployment/authorize_within_current_project": () => ({
          adminKey: "dev-key",
          url: "https://foo-bar-123.convex.cloud",
          deploymentName: "foo-bar-123",
          deploymentType: "prod",
        }),
      });
      setupDefaultEnvPlatformMocks({ projectId: 42 });

      await env.parseAsync(["default", "list", "--type", "development"], {
        from: "user",
      });

      expect(mockPlatformGet).toHaveBeenCalledWith(
        "/projects/{project_id}/list_default_environment_variables",
        expect.objectContaining({
          params: {
            path: { project_id: 42 },
            query: { deploymentType: "dev" },
          },
        }),
      );
    });
  });

  describe("--project", () => {
    it("--project team:proj --type prod does not require a current deployment", async () => {
      vi.mocked(readGlobalConfig).mockReturnValue({
        accessToken: "test-token",
      });
      setupBigBrainRoutes({});
      setupDefaultEnvPlatformMocks({
        projectId: 99,
        teamSlug: "my-team",
        projectSlug: "my-proj",
      });

      await env.parseAsync(
        [
          "default",
          "set",
          "ABC",
          "DEF",
          "--project",
          "my-team:my-proj",
          "--type",
          "prod",
        ],
        { from: "user" },
      );

      expect(bigBrainAPI).not.toHaveBeenCalled();
      expect(mockPlatformGet).toHaveBeenCalledWith(
        "/teams/{team_id_or_slug}/projects/{project_slug}",
        expect.objectContaining({
          params: {
            path: { team_id_or_slug: "my-team", project_slug: "my-proj" },
          },
        }),
      );
      expect(mockPlatformPost).toHaveBeenCalledWith(
        "/projects/{project_id}/update_default_environment_variables",
        expect.objectContaining({
          params: { path: { project_id: 99 } },
          body: {
            changes: [{ name: "ABC", deploymentType: "prod", value: "DEF" }],
          },
        }),
      );
    });

    it("--project just-proj --type prod uses current deployment's team", async () => {
      process.env.CONVEX_DEPLOYMENT = "dev:foo-bar-123";
      vi.mocked(readGlobalConfig).mockReturnValue({
        accessToken: "test-token",
      });
      setupBigBrainRoutes({
        "deployment/foo-bar-123/team_and_project": () => ({
          team: "my-team",
          project: "original-project",
          teamId: 1,
          projectId: 42,
        }),
        "deployment/authorize_within_current_project": () => ({
          adminKey: "dev-key",
          url: "https://foo-bar-123.convex.cloud",
          deploymentName: "foo-bar-123",
          deploymentType: "dev",
        }),
      });
      setupDefaultEnvPlatformMocks({
        projectId: 77,
        teamSlug: "my-team",
        projectSlug: "just-proj",
      });

      await env.parseAsync(
        ["default", "list", "--project", "just-proj", "--type", "prod"],
        { from: "user" },
      );

      expect(mockPlatformGet).toHaveBeenCalledWith(
        "/teams/{team_id_or_slug}/projects/{project_slug}",
        expect.objectContaining({
          params: {
            path: { team_id_or_slug: "my-team", project_slug: "just-proj" },
          },
        }),
      );
      expect(mockPlatformGet).toHaveBeenCalledWith(
        "/projects/{project_id}/list_default_environment_variables",
        expect.objectContaining({
          params: {
            path: { project_id: 77 },
            query: { deploymentType: "prod" },
          },
        }),
      );
    });

    it("--project team:proj without --type exits with a fatal error", async () => {
      await expect(
        env.parseAsync(["default", "list", "--project", "my-team:my-proj"], {
          from: "user",
        }),
      ).rejects.toThrow();
      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining("--project requires --type"),
      );
    });

    it("--project a:b:c (too many colons) exits with a fatal error", async () => {
      await expect(
        env.parseAsync(
          ["default", "list", "--project", "a:b:c", "--type", "prod"],
          { from: "user" },
        ),
      ).rejects.toThrow();
      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining("--project must be"),
      );
    });
  });

  describe("--type forwarded values", () => {
    it("invalid --type values are forwarded; backend error surfaces", async () => {
      process.env.CONVEX_DEPLOYMENT = "dev:foo-bar-123";
      vi.mocked(readGlobalConfig).mockReturnValue({
        accessToken: "test-token",
      });
      setupBigBrainRoutes({
        "deployment/foo-bar-123/team_and_project": () => ({
          team: "my-team",
          project: "my-project",
          teamId: 1,
          projectId: 42,
        }),
        "deployment/authorize_within_current_project": () => ({
          adminKey: "dev-key",
          url: "https://foo-bar-123.convex.cloud",
          deploymentName: "foo-bar-123",
          deploymentType: "dev",
        }),
      });
      mockPlatformGet.mockImplementation((path: string) => {
        if (
          path === "/projects/{project_id}/list_default_environment_variables"
        ) {
          throw new Error("backend rejected deploymentType: invalid-type");
        }
        throw new Error(`Unmocked platform GET: ${path}`);
      });

      await expect(
        env.parseAsync(["default", "list", "--type", "invalid-type"], {
          from: "user",
        }),
      ).rejects.toThrow();

      expect(mockPlatformGet).toHaveBeenCalledWith(
        "/projects/{project_id}/list_default_environment_variables",
        expect.objectContaining({
          params: expect.objectContaining({
            query: expect.objectContaining({ deploymentType: "invalid-type" }),
          }),
        }),
      );
    });
  });

  describe("remove subcommand", () => {
    it("--project team:proj --type prod wires through", async () => {
      vi.mocked(readGlobalConfig).mockReturnValue({
        accessToken: "test-token",
      });
      setupBigBrainRoutes({});
      setupDefaultEnvPlatformMocks({ projectId: 55 });

      await env.parseAsync(
        [
          "default",
          "remove",
          "ABC",
          "--project",
          "my-team:my-proj",
          "--type",
          "prod",
        ],
        { from: "user" },
      );

      expect(mockPlatformPost).toHaveBeenCalledWith(
        "/projects/{project_id}/update_default_environment_variables",
        expect.objectContaining({
          params: { path: { project_id: 55 } },
          body: {
            changes: [{ name: "ABC", deploymentType: "prod", value: null }],
          },
        }),
      );
    });
  });
});
