import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
// @inquirer/testing/vitest must be imported before modules that use @inquirer/*
import { screen } from "@inquirer/testing/vitest";
import path from "path";
import { nodeFs } from "../bundler/fs.js";
import { deploymentSelect } from "./deploymentSelect.js";
import {
  bigBrainAPI,
  bigBrainAPIMaybeThrows,
  ThrowingFetchError,
} from "./lib/utils/utils.js";
import {
  bigBrainPause,
  bigBrainStart,
} from "./lib/localDeployment/bigBrain.js";
import { globalConfigPath } from "./lib/utils/globalConfig.js";

// Mock GET functions — can be configured per test
const mockPlatformGet = vi.fn();
const mockDeploymentGet = vi.fn();
const { mockCreateLocalDeployment } = vi.hoisted(() => ({
  mockCreateLocalDeployment: vi.fn(),
}));

// In-memory filesystem — populated in beforeEach, written to by real configure code
let testFiles: Map<string, string>;

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

vi.mock("./lib/utils/utils.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./lib/utils/utils.js")>();
  return {
    ...actual,
    bigBrainAPI: vi.fn(),
    bigBrainAPIMaybeThrows: vi.fn(),
    typedPlatformClient: vi.fn(() => ({ GET: mockPlatformGet })),
    typedDeploymentClient: vi.fn(() => ({ GET: mockDeploymentGet })),
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

vi.mock("./deploymentCreate.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./deploymentCreate.js")>();
  return {
    ...actual,
    createLocalDeployment: mockCreateLocalDeployment,
  };
});

vi.mock("./lib/localDeployment/run.js", async (importOriginal) => {
  const actual =
    await importOriginal<typeof import("./lib/localDeployment/run.js")>();
  return {
    ...actual,
    fetchLocalBackendStatus: vi.fn().mockResolvedValue({ kind: "running" }),
  };
});

vi.mock("./lib/localDeployment/bigBrain.js", async (importOriginal) => {
  const actual =
    await importOriginal<typeof import("./lib/localDeployment/bigBrain.js")>();
  return {
    ...actual,
    bigBrainStart: vi.fn(),
    bigBrainPause: vi.fn(),
  };
});

/**
 * Routes mock Big Brain API calls by path.
 * Both `bigBrainAPI` and `bigBrainAPIMaybeThrows` delegate to this.
 */
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

describe("npx convex select", () => {
  let savedEnv: NodeJS.ProcessEnv;
  let savedIsTTY: boolean | undefined;

  beforeEach(() => {
    savedEnv = { ...process.env };
    savedIsTTY = process.stdin.isTTY;
    process.env = {};
    // Default to interactive TTY for existing tests
    process.stdin.isTTY = true as any;

    // Start with minimal filesystem: package.json for readProjectConfig fallback
    testFiles = new Map([[path.resolve("package.json"), "{}"]]);

    vi.resetAllMocks();

    // Wire up the in-memory filesystem to the nodeFs mock
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

    // typedDeploymentClient GET is called by fetchDeploymentCanonicalUrls
    mockDeploymentGet.mockResolvedValue({
      data: {
        convexCloudUrl: "https://example.convex.cloud",
        convexSiteUrl: "https://example.convex.site",
      },
    });

    // typedPlatformClient is used for reference-based deployment resolution
    vi.mocked(mockPlatformGet).mockResolvedValue({ data: undefined });
  });

  afterEach(() => {
    process.env = savedEnv;
    process.stdin.isTTY = savedIsTTY as any;
  });

  // Suppress process.exit and stderr
  beforeEach(() => {
    vi.spyOn(process, "exit").mockImplementation((() => {
      throw new Error("process.exit called");
    }) as any);
    vi.spyOn(process.stderr, "write").mockImplementation(() => true);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe("with project configured", () => {
    beforeEach(() => {
      process.env.CONVEX_DEPLOYMENT = "dev:joyful-capybara-123";
      testFiles.set(
        globalConfigPath(),
        JSON.stringify({ accessToken: "test-token" }),
      );
    });

    it("selects a dev deployment by name (abc-xyz-123)", async () => {
      // For a deployment name selector, the system looks up the *selected*
      // deployment's team/project (not the current CONVEX_DEPLOYMENT's).
      setupBigBrainRoutes({
        "deployment/clever-otter-890/team_and_project": () => ({
          team: "my-team",
          project: "my-project",
          teamId: 1,
          projectId: 1,
        }),
        "deployment/authorize_within_current_project": () => ({
          adminKey: "dev-key",
          url: "https://clever-otter-890.convex.cloud",
          deploymentName: "clever-otter-890",
          deploymentType: "dev",
        }),
      });

      await deploymentSelect.parseAsync(["clever-otter-890"], { from: "user" });

      expect(bigBrainAPI).toHaveBeenCalledWith(
        expect.objectContaining({
          path: "deployment/authorize_within_current_project",
          data: expect.objectContaining({
            selectedDeploymentName: "clever-otter-890",
          }),
        }),
      );
      const envContent = testFiles.get(path.resolve(".env.local"))!;
      expect(envContent).toContain("CONVEX_DEPLOYMENT=dev:clever-otter-890");
      expect(envContent).toContain("team: my-team, project: my-project");
      expect(envContent).toContain(
        "CONVEX_URL=https://clever-otter-890.convex.cloud",
      );
    });

    it("selects dev deployment with 'dev' selector", async () => {
      setupBigBrainRoutes({
        "deployment/joyful-capybara-123/team_and_project": () => ({
          team: "my-team",
          project: "my-project",
          teamId: 1,
          projectId: 1,
        }),
        "teams/my-team/projects/my-project/deployments": () => true,
        "deployment/authorize_within_current_project": () => ({
          adminKey: "dev-key",
          url: "https://joyful-capybara-123.convex.cloud",
          deploymentName: "joyful-capybara-123",
          deploymentType: "dev",
        }),
      });
      mockPlatformGet.mockResolvedValue({
        data: { name: "joyful-capybara-123" },
        error: undefined,
      });

      await deploymentSelect.parseAsync(["dev"], { from: "user" });

      expect(mockPlatformGet).toHaveBeenCalledWith(
        "/teams/{team_id_or_slug}/projects/{project_slug}/deployment",
        expect.objectContaining({
          params: expect.objectContaining({
            path: { team_id_or_slug: "my-team", project_slug: "my-project" },
            query: { defaultDev: true },
          }),
        }),
      );
      expect(bigBrainAPI).toHaveBeenCalledWith(
        expect.objectContaining({
          path: "deployment/authorize_within_current_project",
          data: expect.objectContaining({
            selectedDeploymentName: "joyful-capybara-123",
          }),
        }),
      );
      const envContent = testFiles.get(path.resolve(".env.local"))!;
      expect(envContent).toContain("CONVEX_DEPLOYMENT=dev:joyful-capybara-123");
    });

    it("selects dev deployment by reference 'dev/nicolas'", async () => {
      setupBigBrainRoutes({
        "deployment/joyful-capybara-123/team_and_project": () => ({
          team: "my-team",
          project: "my-project",
          teamId: 1,
          projectId: 1,
        }),
        "teams/my-team/projects/my-project/deployments": () => true,
        "deployment/authorize_within_current_project": () => ({
          adminKey: "nicolas-key",
          url: "https://nicolas-dev-123.convex.cloud",
          deploymentName: "nicolas-dev-123",
          deploymentType: "dev",
        }),
      });
      mockPlatformGet.mockResolvedValue({
        data: { name: "nicolas-dev-123" },
        error: undefined,
      });

      await deploymentSelect.parseAsync(["dev/nicolas"], { from: "user" });

      expect(mockPlatformGet).toHaveBeenCalledWith(
        "/teams/{team_id_or_slug}/projects/{project_slug}/deployment",
        expect.objectContaining({
          params: expect.objectContaining({
            path: { team_id_or_slug: "my-team", project_slug: "my-project" },
            query: { reference: "dev/nicolas" },
          }),
        }),
      );
      expect(bigBrainAPI).toHaveBeenCalledWith(
        expect.objectContaining({
          path: "deployment/authorize_within_current_project",
          data: expect.objectContaining({
            selectedDeploymentName: "nicolas-dev-123",
          }),
        }),
      );
      expect(testFiles.has(path.resolve(".env.local"))).toBe(true);
    });

    it("selects a preview deployment in another project 'other-project:preview/my-feature'", async () => {
      setupBigBrainRoutes({
        "deployment/joyful-capybara-123/team_and_project": () => ({
          team: "my-team",
          project: "my-project",
          teamId: 1,
          projectId: 1,
        }),
        "teams/my-team/projects/other-project/deployments": () => true,
        "deployment/authorize_within_current_project": () => ({
          adminKey: "preview-key",
          url: "https://feature-preview-123.convex.cloud",
          deploymentName: "feature-preview-123",
          deploymentType: "preview",
        }),
      });
      mockPlatformGet.mockResolvedValue({
        data: { name: "feature-preview-123" },
        error: undefined,
      });

      await deploymentSelect.parseAsync(["other-project:preview/my-feature"], {
        from: "user",
      });

      expect(mockPlatformGet).toHaveBeenCalledWith(
        "/teams/{team_id_or_slug}/projects/{project_slug}/deployment",
        expect.objectContaining({
          params: expect.objectContaining({
            path: {
              team_id_or_slug: "my-team",
              project_slug: "other-project",
            },
            query: { reference: "preview/my-feature" },
          }),
        }),
      );
      const envContent = testFiles.get(path.resolve(".env.local"))!;
      expect(envContent).toContain(
        "CONVEX_DEPLOYMENT=preview:feature-preview-123",
      );
    });

    describe("prod deployment restrictions", () => {
      it("fails with an error message when 'prod' selector is used", async () => {
        setupBigBrainRoutes({
          "deployment/joyful-capybara-123/team_and_project": () => ({
            team: "my-team",
            project: "my-project",
            teamId: 1,
            projectId: 1,
          }),
          "deployment/authorize_prod": () => ({
            adminKey: "prod-key",
            url: "https://graceful-puffin-456.convex.cloud",
            deploymentName: "graceful-puffin-456",
            deploymentType: "prod",
          }),
        });

        await expect(
          deploymentSelect.parseAsync(["prod"], { from: "user" }),
        ).rejects.toThrow();

        expect(process.stderr.write).toHaveBeenCalledWith(
          expect.stringContaining("--deployment prod"),
        );
        expect(testFiles.has(path.resolve(".env.local"))).toBe(false);
      });

      it("fails with an error message when a deployment name resolves to a prod deployment", async () => {
        setupBigBrainRoutes({
          "deployment/graceful-puffin-456/team_and_project": () => ({
            team: "my-team",
            project: "my-project",
            teamId: 1,
            projectId: 1,
          }),
          "deployment/authorize_within_current_project": () => ({
            adminKey: "prod-key",
            url: "https://graceful-puffin-456.convex.cloud",
            deploymentName: "graceful-puffin-456",
            deploymentType: "prod",
          }),
        });

        await expect(
          deploymentSelect.parseAsync(["graceful-puffin-456"], {
            from: "user",
          }),
        ).rejects.toThrow();

        expect(process.stderr.write).toHaveBeenCalledWith(
          expect.stringContaining("--deployment graceful-puffin-456"),
        );
        expect(testFiles.has(path.resolve(".env.local"))).toBe(false);
      });
    });

    describe("side effects on successful selection", () => {
      it("fetches the canonical URLs using the resolved deployment credentials", async () => {
        setupBigBrainRoutes({
          "deployment/joyful-capybara-123/team_and_project": () => ({
            team: "my-team",
            project: "my-project",
            teamId: 1,
            projectId: 1,
          }),
          "teams/my-team/projects/my-project/deployments": () => true,
          "deployment/authorize_within_current_project": () => ({
            adminKey: "dev-key",
            url: "https://joyful-capybara-123.convex.cloud",
            deploymentName: "joyful-capybara-123",
            deploymentType: "dev",
          }),
        });
        mockPlatformGet.mockResolvedValue({
          data: { name: "joyful-capybara-123" },
          error: undefined,
        });

        await deploymentSelect.parseAsync(["dev"], { from: "user" });

        expect(mockDeploymentGet).toHaveBeenCalledWith("/get_canonical_urls");
      });

      it("writes the fetched site URL to the env file", async () => {
        mockDeploymentGet.mockResolvedValue({
          data: {
            convexCloudUrl: "https://joyful-capybara-123.convex.cloud",
            convexSiteUrl: "https://joyful-capybara-123.convex.site",
          },
        });
        setupBigBrainRoutes({
          "deployment/joyful-capybara-123/team_and_project": () => ({
            team: "my-team",
            project: "my-project",
            teamId: 1,
            projectId: 1,
          }),
          "teams/my-team/projects/my-project/deployments": () => true,
          "deployment/authorize_within_current_project": () => ({
            adminKey: "dev-key",
            url: "https://joyful-capybara-123.convex.cloud",
            deploymentName: "joyful-capybara-123",
            deploymentType: "dev",
          }),
        });
        mockPlatformGet.mockResolvedValue({
          data: { name: "joyful-capybara-123" },
          error: undefined,
        });

        await deploymentSelect.parseAsync(["dev"], { from: "user" });

        const envContent = testFiles.get(path.resolve(".env.local"))!;
        expect(envContent).toContain(
          "CONVEX_SITE_URL=https://joyful-capybara-123.convex.site",
        );
      });

      it("uses the existing deployment name to detect unchanged selections", async () => {
        // deploymentNameFromSelection(currentSelection) extracts "joyful-capybara-123"
        // from process.env.CONVEX_DEPLOYMENT ("dev:joyful-capybara-123") and passes
        // it as existingValue to configure so it can detect whether the selection changed.
        // Here we verify the full chain ran: the correct name is written to .env.local.
        setupBigBrainRoutes({
          "deployment/joyful-capybara-123/team_and_project": () => ({
            team: "my-team",
            project: "my-project",
            teamId: 1,
            projectId: 1,
          }),
          "teams/my-team/projects/my-project/deployments": () => true,
          "deployment/authorize_within_current_project": () => ({
            adminKey: "dev-key",
            url: "https://joyful-capybara-123.convex.cloud",
            deploymentName: "joyful-capybara-123",
            deploymentType: "dev",
          }),
        });
        mockPlatformGet.mockResolvedValue({
          data: { name: "joyful-capybara-123" },
          error: undefined,
        });

        await deploymentSelect.parseAsync(["dev"], { from: "user" });

        const envContent = testFiles.get(path.resolve(".env.local"))!;
        expect(envContent).toContain(
          "CONVEX_DEPLOYMENT=dev:joyful-capybara-123",
        );
      });
    });

    it("selects local deployment with 'local' selector", async () => {
      testFiles.set(
        path.resolve(".convex/local/default/config.json"),
        JSON.stringify({
          ports: { cloud: 3210, site: 3211 },
          adminKey: "local-key",
          backendVersion: "1.0.0",
          deploymentName: "local-my_team-my_project-abc",
          cloudProjectId: 42,
        }),
      );
      // The local deployment name is looked up via Big Brain for project
      // access checks (checkAccessToSelectedProject)
      // FIXME We should probably avoid the Big Brain call here so that it works offline
      setupBigBrainRoutes({
        "deployment/local-my_team-my_project-abc/team_and_project": () => ({
          team: "my-team",
          project: "my-project",
          teamId: 1,
          projectId: 42,
        }),
        "deployment/joyful-capybara-123/team_and_project": () => ({
          team: "my-team",
          project: "my-project",
          teamId: 1,
          projectId: 42,
        }),
      });
      // Project lookup: CONVEX_DEPLOYMENT → /deployments/{name} → /projects/{id}
      mockPlatformGet.mockImplementation((path: string) => {
        if (path === "/deployments/{deployment_name}") {
          return { data: { projectId: 42 } };
        }
        if (path === "/projects/{project_id}") {
          return {
            data: {
              id: 42,
              teamSlug: "my-team",
              slug: "my-project",
            },
          };
        }
        return { data: undefined };
      });

      await deploymentSelect.parseAsync(["local"], { from: "user" });

      const envContent = testFiles.get(path.resolve(".env.local"))!;
      expect(envContent).toContain(
        "CONVEX_DEPLOYMENT=local:local-my_team-my_project-abc",
      );
      // Site URL fetch should be skipped for local deployments
      expect(envContent).not.toContain("CONVEX_SITE_URL");
    });

    it("creates a local deployment when user approves the 'Create one now?' prompt", async () => {
      mockCreateLocalDeployment.mockResolvedValue(undefined);

      const promise = deploymentSelect.parseAsync(["local"], { from: "user" });

      await screen.next();
      expect(screen.getScreen()).toContain(
        "No local deployment found. Create one now?",
      );
      screen.keypress("y");
      screen.keypress("enter");

      await promise;

      expect(mockCreateLocalDeployment).toHaveBeenCalledTimes(1);
    });

    it("refuses to create a local deployment for 'project:local' when no local config exists (could silently target wrong project)", async () => {
      await expect(
        deploymentSelect.parseAsync(["my-project:local"], { from: "user" }),
      ).rejects.toThrow();

      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining(
          "npx convex deployment create local --project my-project",
        ),
      );
      expect(mockCreateLocalDeployment).not.toHaveBeenCalled();
      expect(testFiles.has(path.resolve(".env.local"))).toBe(false);
    });

    it("fails with 'No local deployment found' when no local config exists and stdin is not a TTY", async () => {
      const previousIsTTY = process.stdin.isTTY;
      process.stdin.isTTY = false as any;
      try {
        await expect(
          deploymentSelect.parseAsync(["local"], { from: "user" }),
        ).rejects.toThrow();

        expect(process.stderr.write).toHaveBeenCalledWith(
          expect.stringContaining("No local deployment found"),
        );
        expect(mockCreateLocalDeployment).not.toHaveBeenCalled();
      } finally {
        process.stdin.isTTY = previousIsTTY as any;
      }
    });

    describe("project mismatch flow", () => {
      function mockProjectLookup(opts: { projectId: number }) {
        mockPlatformGet.mockImplementation((path: string) => {
          if (path === "/deployments/{deployment_name}") {
            return { data: { projectId: opts.projectId } };
          }
          if (path === "/projects/{project_id}") {
            return {
              data: {
                id: opts.projectId,
                teamSlug: "my-team",
                slug: "my-project",
              },
            };
          }
          return { data: undefined };
        });
      }

      it("matching cloudProjectId → selects directly without warn/pause/bigBrainStart", async () => {
        testFiles.set(
          path.resolve(".convex/local/default/config.json"),
          JSON.stringify({
            ports: { cloud: 3210, site: 3211 },
            adminKey: "local-key",
            backendVersion: "1.0.0",
            deploymentName: "local-my_team-my_project-abc",
            cloudProjectId: 42,
          }),
        );
        setupBigBrainRoutes({
          "deployment/local-my_team-my_project-abc/team_and_project": () => ({
            team: "my-team",
            project: "my-project",
            teamId: 1,
            projectId: 42,
          }),
          "deployment/joyful-capybara-123/team_and_project": () => ({
            team: "my-team",
            project: "my-project",
            teamId: 1,
            projectId: 42,
          }),
        });
        mockProjectLookup({ projectId: 42 });

        await deploymentSelect.parseAsync(["local"], { from: "user" });

        // Did NOT call pause or start
        expect(bigBrainPause).not.toHaveBeenCalled();
        expect(bigBrainStart).not.toHaveBeenCalled();
        // config.json untouched
        const config = JSON.parse(
          testFiles.get(path.resolve(".convex/local/default/config.json"))!,
        );
        expect(config.cloudProjectId).toBe(42);
        expect(config.adminKey).toBe("local-key");
        // Selection saved
        const envContent = testFiles.get(path.resolve(".env.local"))!;
        expect(envContent).toContain(
          "CONVEX_DEPLOYMENT=local:local-my_team-my_project-abc",
        );
      });

      it("missing cloudProjectId → writes resolved id back to config.json and selects", async () => {
        testFiles.set(
          path.resolve(".convex/local/default/config.json"),
          JSON.stringify({
            ports: { cloud: 3210, site: 3211 },
            adminKey: "local-key",
            backendVersion: "1.0.0",
            deploymentName: "local-my_team-my_project-abc",
          }),
        );
        setupBigBrainRoutes({
          "deployment/local-my_team-my_project-abc/team_and_project": () => ({
            team: "my-team",
            project: "my-project",
            teamId: 1,
            projectId: 42,
          }),
          "deployment/joyful-capybara-123/team_and_project": () => ({
            team: "my-team",
            project: "my-project",
            teamId: 1,
            projectId: 42,
          }),
        });
        mockProjectLookup({ projectId: 42 });

        await deploymentSelect.parseAsync(["local"], { from: "user" });

        const config = JSON.parse(
          testFiles.get(path.resolve(".convex/local/default/config.json"))!,
        );
        expect(config.cloudProjectId).toBe(42);
        // No pause / no start
        expect(bigBrainPause).not.toHaveBeenCalled();
        expect(bigBrainStart).not.toHaveBeenCalled();
      });

      it("mismatching cloudProjectId → warns, pauses old, registers new, rewrites config, selects", async () => {
        testFiles.set(
          path.resolve(".convex/local/default/config.json"),
          JSON.stringify({
            ports: { cloud: 3210, site: 3211 },
            adminKey: "admin-key",
            backendVersion: "1.0.0",
            deploymentName: "local-old_team-old_project-abc",
            cloudProjectId: 100, // old project
          }),
        );
        setupBigBrainRoutes({
          "deployment/local-new_team-new_project-xyz/team_and_project": () => ({
            team: "my-team",
            project: "my-project",
            teamId: 1,
            projectId: 42,
          }),
          "deployment/joyful-capybara-123/team_and_project": () => ({
            team: "my-team",
            project: "my-project",
            teamId: 1,
            projectId: 42,
          }),
        });
        vi.mocked(bigBrainPause).mockResolvedValue(undefined);
        vi.mocked(bigBrainStart).mockResolvedValue({
          deploymentName: "local-new_team-new_project-xyz",
          adminKey: "admin-key",
          projectId: 42,
        });
        mockPlatformGet.mockImplementation((path: string, args: any) => {
          if (path === "/deployments/{deployment_name}") {
            return { data: { projectId: 42 } };
          }
          if (path === "/projects/{project_id}") {
            const id = args?.params?.path?.project_id;
            if (id === 100) {
              return {
                data: {
                  id: 100,
                  teamSlug: "old-team",
                  slug: "old-project",
                },
              };
            }
            return {
              data: {
                id: 42,
                teamSlug: "my-team",
                slug: "my-project",
              },
            };
          }
          return { data: undefined };
        });

        await deploymentSelect.parseAsync(["local"], { from: "user" });

        // Warned about the move, using the resolved slugs
        expect(process.stderr.write).toHaveBeenCalledWith(
          expect.stringContaining(
            "This local deployment was previously in project old-team:old-project. Moving it to project my-team:my-project.",
          ),
        );
        // Paused the old project's local deployment
        expect(bigBrainPause).toHaveBeenCalledWith(expect.anything(), {
          teamSlug: "old-team",
          projectSlug: "old-project",
        });
        // Registered against the new project
        expect(bigBrainStart).toHaveBeenCalledWith(
          expect.anything(),
          expect.objectContaining({
            teamSlug: "my-team",
            projectSlug: "my-project",
          }),
        );
        const config = JSON.parse(
          testFiles.get(path.resolve(".convex/local/default/config.json"))!,
        );
        expect(config.cloudProjectId).toBe(42);
        expect(config.adminKey).toBe("admin-key");
        expect(config.deploymentName).toBe("local-new_team-new_project-xyz");
        expect(config.ports).toEqual({ cloud: 3210, site: 3211 });
      });

      it("swallows pause failure: still calls start and saves selection", async () => {
        testFiles.set(
          path.resolve(".convex/local/default/config.json"),
          JSON.stringify({
            ports: { cloud: 3210, site: 3211 },
            adminKey: "admin-key",
            backendVersion: "1.0.0",
            deploymentName: "local-old_team-old_project-abc",
            cloudProjectId: 100,
          }),
        );
        setupBigBrainRoutes({
          "deployment/local-new_team-new_project-xyz/team_and_project": () => ({
            team: "my-team",
            project: "my-project",
            teamId: 1,
            projectId: 42,
          }),
          "deployment/joyful-capybara-123/team_and_project": () => ({
            team: "my-team",
            project: "my-project",
            teamId: 1,
            projectId: 42,
          }),
        });
        vi.mocked(bigBrainPause).mockRejectedValue(new Error("pause failed"));
        vi.mocked(bigBrainStart).mockResolvedValue({
          deploymentName: "local-new_team-new_project-xyz",
          adminKey: "admin-key",
          projectId: 42,
        });
        mockPlatformGet.mockImplementation((path: string, args: any) => {
          if (path === "/deployments/{deployment_name}") {
            return { data: { projectId: 42 } };
          }
          if (path === "/projects/{project_id}") {
            const id = args?.params?.path?.project_id;
            if (id === 100) {
              return {
                data: { id: 100, teamSlug: "old-team", slug: "old-project" },
              };
            }
            return {
              data: { id: 42, teamSlug: "my-team", slug: "my-project" },
            };
          }
          return { data: undefined };
        });

        await deploymentSelect.parseAsync(["local"], { from: "user" });

        expect(bigBrainStart).toHaveBeenCalled();
        const envContent = testFiles.get(path.resolve(".env.local"))!;
        expect(envContent).toContain(
          "CONVEX_DEPLOYMENT=local:local-new_team-new_project-xyz",
        );
      });

      it("swallows old-project 404 (deleted cloud project): still registers new project and selects", async () => {
        testFiles.set(
          path.resolve(".convex/local/default/config.json"),
          JSON.stringify({
            ports: { cloud: 3210, site: 3211 },
            adminKey: "admin-key",
            backendVersion: "1.0.0",
            deploymentName: "local-old_team-old_project-abc",
            cloudProjectId: 100,
          }),
        );
        setupBigBrainRoutes({
          "deployment/local-new_team-new_project-xyz/team_and_project": () => ({
            team: "my-team",
            project: "my-project",
            teamId: 1,
            projectId: 42,
          }),
          "deployment/joyful-capybara-123/team_and_project": () => ({
            team: "my-team",
            project: "my-project",
            teamId: 1,
            projectId: 42,
          }),
        });
        vi.mocked(bigBrainStart).mockResolvedValue({
          deploymentName: "local-new_team-new_project-xyz",
          adminKey: "admin-key",
          projectId: 42,
        });
        mockPlatformGet.mockImplementation((path: string, args: any) => {
          if (path === "/deployments/{deployment_name}") {
            return { data: { projectId: 42 } };
          }
          if (path === "/projects/{project_id}") {
            const id = args?.params?.path?.project_id;
            if (id === 100) {
              const response = new Response(
                JSON.stringify({
                  code: "ProjectNotFound",
                  message: "...",
                }),
                { status: 404, statusText: "Not Found" },
              );
              throw new ThrowingFetchError("Error fetching", {
                code: "ProjectNotFound",
                message: "The requested project does not exist",
                response,
              });
            }
            return {
              data: { id: 42, teamSlug: "my-team", slug: "my-project" },
            };
          }
          return { data: undefined };
        });

        await deploymentSelect.parseAsync(["local"], { from: "user" });

        // Warning falls back to the raw id when the project can't be resolved
        expect(process.stderr.write).toHaveBeenCalledWith(
          expect.stringContaining(
            "This local deployment was previously in an unknown cloud project (ID 100). Moving it to project my-team:my-project.",
          ),
        );
        expect(bigBrainPause).not.toHaveBeenCalled();
        expect(bigBrainStart).toHaveBeenCalled();
        const envContent = testFiles.get(path.resolve(".env.local"))!;
        expect(envContent).toContain(
          "CONVEX_DEPLOYMENT=local:local-new_team-new_project-xyz",
        );
        const config = JSON.parse(
          testFiles.get(path.resolve(".convex/local/default/config.json"))!,
        );
        expect(config.cloudProjectId).toBe(42);
        expect(config.deploymentName).toBe("local-new_team-new_project-xyz");
      });

      describe.each([
        { label: "project:local", selector: "my-project:local" },
        {
          label: "team:project:local",
          selector: "my-team:my-project:local",
        },
      ])("select $label", ({ selector }) => {
        function mockPlatformForTargetProject(opts: { projectId: number }) {
          mockPlatformGet.mockImplementation((path: string, args: any) => {
            if (path === "/deployments/{deployment_name}") {
              return { data: { projectId: opts.projectId } };
            }
            if (path === "/projects/{project_id}") {
              const id = args?.params?.path?.project_id;
              if (id === 100) {
                return {
                  data: {
                    id: 100,
                    teamSlug: "old-team",
                    slug: "old-project",
                  },
                };
              }
              return {
                data: {
                  id: opts.projectId,
                  teamSlug: "my-team",
                  slug: "my-project",
                },
              };
            }
            if (path === "/teams/{team_id_or_slug}/projects/{project_slug}") {
              return {
                data: {
                  id: opts.projectId,
                  teamSlug: "my-team",
                  slug: "my-project",
                },
              };
            }
            return { data: undefined };
          });
        }

        it("matching cloudProjectId → selects without warn/pause/start", async () => {
          testFiles.set(
            path.resolve(".convex/local/default/config.json"),
            JSON.stringify({
              ports: { cloud: 3210, site: 3211 },
              adminKey: "local-key",
              backendVersion: "1.0.0",
              deploymentName: "local-my_team-my_project-abc",
              cloudProjectId: 42,
            }),
          );
          setupBigBrainRoutes({
            "deployment/local-my_team-my_project-abc/team_and_project": () => ({
              team: "my-team",
              project: "my-project",
              teamId: 1,
              projectId: 42,
            }),
            "deployment/joyful-capybara-123/team_and_project": () => ({
              team: "my-team",
              project: "my-project",
              teamId: 1,
              projectId: 42,
            }),
          });
          mockPlatformForTargetProject({ projectId: 42 });

          await deploymentSelect.parseAsync([selector], { from: "user" });

          expect(bigBrainPause).not.toHaveBeenCalled();
          expect(bigBrainStart).not.toHaveBeenCalled();
          expect(process.stderr.write).not.toHaveBeenCalledWith(
            expect.stringContaining("Moving it to project"),
          );
          const config = JSON.parse(
            testFiles.get(path.resolve(".convex/local/default/config.json"))!,
          );
          expect(config.cloudProjectId).toBe(42);
          const envContent = testFiles.get(path.resolve(".env.local"))!;
          expect(envContent).toContain(
            "CONVEX_DEPLOYMENT=local:local-my_team-my_project-abc",
          );
        });

        it("missing cloudProjectId → writes resolved id back and selects", async () => {
          testFiles.set(
            path.resolve(".convex/local/default/config.json"),
            JSON.stringify({
              ports: { cloud: 3210, site: 3211 },
              adminKey: "local-key",
              backendVersion: "1.0.0",
              deploymentName: "local-my_team-my_project-abc",
            }),
          );
          setupBigBrainRoutes({
            "deployment/local-my_team-my_project-abc/team_and_project": () => ({
              team: "my-team",
              project: "my-project",
              teamId: 1,
              projectId: 42,
            }),
            "deployment/joyful-capybara-123/team_and_project": () => ({
              team: "my-team",
              project: "my-project",
              teamId: 1,
              projectId: 42,
            }),
          });
          mockPlatformForTargetProject({ projectId: 42 });

          await deploymentSelect.parseAsync([selector], { from: "user" });

          const config = JSON.parse(
            testFiles.get(path.resolve(".convex/local/default/config.json"))!,
          );
          expect(config.cloudProjectId).toBe(42);
          expect(bigBrainPause).not.toHaveBeenCalled();
          expect(bigBrainStart).not.toHaveBeenCalled();
          expect(process.stderr.write).not.toHaveBeenCalledWith(
            expect.stringContaining("Moving it to project"),
          );
        });

        it("mismatching cloudProjectId → warns, pauses old, registers new, rewrites config", async () => {
          testFiles.set(
            path.resolve(".convex/local/default/config.json"),
            JSON.stringify({
              ports: { cloud: 3210, site: 3211 },
              adminKey: "admin-key",
              backendVersion: "1.0.0",
              deploymentName: "local-old_team-old_project-abc",
              cloudProjectId: 100,
            }),
          );
          setupBigBrainRoutes({
            "deployment/local-new_team-new_project-xyz/team_and_project":
              () => ({
                team: "my-team",
                project: "my-project",
                teamId: 1,
                projectId: 42,
              }),
            "deployment/joyful-capybara-123/team_and_project": () => ({
              team: "my-team",
              project: "my-project",
              teamId: 1,
              projectId: 42,
            }),
          });
          vi.mocked(bigBrainPause).mockResolvedValue(undefined);
          vi.mocked(bigBrainStart).mockResolvedValue({
            deploymentName: "local-new_team-new_project-xyz",
            adminKey: "admin-key",
            projectId: 42,
          });
          mockPlatformForTargetProject({ projectId: 42 });

          await deploymentSelect.parseAsync([selector], { from: "user" });

          expect(process.stderr.write).toHaveBeenCalledWith(
            expect.stringContaining("Moving it to project"),
          );
          expect(bigBrainPause).toHaveBeenCalledWith(expect.anything(), {
            teamSlug: "old-team",
            projectSlug: "old-project",
          });
          expect(bigBrainStart).toHaveBeenCalledWith(
            expect.anything(),
            expect.objectContaining({
              teamSlug: "my-team",
              projectSlug: "my-project",
            }),
          );
          const config = JSON.parse(
            testFiles.get(path.resolve(".convex/local/default/config.json"))!,
          );
          expect(config.cloudProjectId).toBe(42);
          expect(config.deploymentName).toBe("local-new_team-new_project-xyz");
        });
      });
    });
  });

  describe("without project configured", () => {
    beforeEach(() => {
      delete process.env.CONVEX_DEPLOYMENT;
      testFiles.set(
        globalConfigPath(),
        JSON.stringify({ accessToken: "test-token" }),
      );
    });

    it("fails with 'No project configured' for the 'dev' selector", async () => {
      await expect(
        deploymentSelect.parseAsync(["dev"], { from: "user" }),
      ).rejects.toThrow();

      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining("No project configured"),
      );
    });

    it("fails with 'No project configured' for a simple reference selector", async () => {
      await expect(
        deploymentSelect.parseAsync(["staging"], { from: "user" }),
      ).rejects.toThrow();

      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining("No project configured"),
      );
    });

    it("fails with 'No project configured' for a project:reference selector (needs team context)", async () => {
      await expect(
        deploymentSelect.parseAsync(["my-project:staging"], { from: "user" }),
      ).rejects.toThrow();

      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining("No project configured"),
      );
    });

    it("succeeds with a fully-qualified 'team:project:ref' selector", async () => {
      setupBigBrainRoutes({
        "deployment/authorize_within_current_project": () => ({
          adminKey: "fq-key",
          url: "https://fully-qualified-123.convex.cloud",
          deploymentName: "fully-qualified-123",
          deploymentType: "dev",
        }),
        "teams/my-team/projects/my-project/deployments": () => true,
      });
      mockPlatformGet.mockResolvedValue({
        data: { name: "fully-qualified-123" },
        error: undefined,
      });

      await deploymentSelect.parseAsync(["my-team:my-project:staging"], {
        from: "user",
      });

      expect(mockPlatformGet).toHaveBeenCalledWith(
        "/teams/{team_id_or_slug}/projects/{project_slug}/deployment",
        expect.objectContaining({
          params: expect.objectContaining({
            path: { team_id_or_slug: "my-team", project_slug: "my-project" },
            query: { reference: "staging" },
          }),
        }),
      );
      const envContent = testFiles.get(path.resolve(".env.local"))!;
      expect(envContent).toContain("CONVEX_DEPLOYMENT=dev:fully-qualified-123");
    });

    it("succeeds with a deployment name directly (does not need project context)", async () => {
      // Deployment names (abc-xyz-123 pattern) don't require a project to
      // already be configured — they look up their own team/project info.
      setupBigBrainRoutes({
        "deployment/clever-otter-890/team_and_project": () => ({
          team: "my-team",
          project: "my-project",
          teamId: 1,
          projectId: 1,
        }),
        "deployment/authorize_within_current_project": () => ({
          adminKey: "dev-key",
          url: "https://clever-otter-890.convex.cloud",
          deploymentName: "clever-otter-890",
          deploymentType: "dev",
        }),
      });

      await deploymentSelect.parseAsync(["clever-otter-890"], { from: "user" });

      // deploymentNameFromSelection(currentSelection) returns null when there
      // is no CONVEX_DEPLOYMENT configured (kind === "chooseProject"), meaning
      // configure treats this as a brand-new selection.
      const envContent = testFiles.get(path.resolve(".env.local"))!;
      expect(envContent).toContain("CONVEX_DEPLOYMENT=dev:clever-otter-890");
    });

    it("fails with 'No project configured' for 'local' when no local deployment exists yet", async () => {
      // No `.convex/local/default/config.json` exists, so we'd normally prompt
      // "Create one now?". But since creating a local deployment requires a
      // project, we should fail up-front instead.
      await expect(
        deploymentSelect.parseAsync(["local"], { from: "user" }),
      ).rejects.toThrow();

      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining("No project configured"),
      );
      expect(process.stderr.write).not.toHaveBeenCalledWith(
        expect.stringContaining("Create one now?"),
      );
      expect(mockCreateLocalDeployment).not.toHaveBeenCalled();
    });

    it("creates a local deployment for 'team:project:local' even when no project is configured", async () => {
      // No CONVEX_DEPLOYMENT set (chooseProject) and no on-disk local config,
      // but the selector itself carries team/project context, so we should
      // proceed to create one rather than crashing with "No project configured".
      mockCreateLocalDeployment.mockResolvedValue(undefined);

      const promise = deploymentSelect.parseAsync(
        ["my-team:my-project:local"],
        { from: "user" },
      );

      await screen.next();
      expect(screen.getScreen()).toContain(
        "No local deployment found. Create one now?",
      );
      screen.keypress("y");
      screen.keypress("enter");

      await promise;

      expect(mockCreateLocalDeployment).toHaveBeenCalledWith(
        expect.anything(),
        expect.anything(),
        true,
        { teamSlug: "my-team", projectSlug: "my-project" },
      );
      expect(process.stderr.write).not.toHaveBeenCalledWith(
        expect.stringContaining("No project configured"),
      );
    });

    it("selects local deployment without project configured", async () => {
      testFiles.set(
        path.resolve(".convex/local/default/config.json"),
        JSON.stringify({
          ports: { cloud: 3210, site: 3211 },
          adminKey: "local-key",
          backendVersion: "1.0.0",
          deploymentName: "local-my_team-my_project-abc",
          cloudProjectId: 1,
        }),
      );
      setupBigBrainRoutes({
        "deployment/local-my_team-my_project-abc/team_and_project": () => ({
          team: "my-team",
          project: "my-project",
          teamId: 1,
          projectId: 1,
        }),
      });

      await deploymentSelect.parseAsync(["local"], { from: "user" });

      const envContent = testFiles.get(path.resolve(".env.local"))!;
      expect(envContent).toContain(
        "CONVEX_DEPLOYMENT=local:local-my_team-my_project-abc",
      );
    });
  });
});
