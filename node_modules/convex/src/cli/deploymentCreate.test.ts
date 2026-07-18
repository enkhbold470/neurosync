import { describe, test, expect, vi, beforeEach, afterEach } from "vitest";
// @inquirer/testing/vitest must be imported before modules that use @inquirer/*
import { screen } from "@inquirer/testing/vitest";
import { fileURLToPath } from "url";
import path from "path";
import {
  typedPlatformClient,
  typedBigBrainClient,
  selectRegion,
  logNoDefaultRegionMessage,
} from "./lib/utils/utils.js";
import { PlatformProjectDetails } from "@convex-dev/platform/managementApi";
import {
  DeploymentSelection,
  getDeploymentSelection,
  getProjectDetails,
  deploymentNameFromSelection,
  initializeBigBrainAuth,
} from "./lib/deploymentSelection.js";
import type { Context } from "../bundler/context.js";
import { saveSelectedDeployment } from "./deploymentSelect.js";
import {
  deploymentCreate,
  resolveRegionDetails,
  resolveClassDetails,
} from "./deploymentCreate.js";
import { ensureBackendBinaryDownloaded } from "./lib/localDeployment/download.js";
import {
  loadProjectLocalConfig,
  saveDeploymentConfig,
} from "./lib/localDeployment/filePaths.js";
import { chooseLocalBackendPorts } from "./lib/localDeployment/utils.js";
import { bigBrainStart } from "./lib/localDeployment/bigBrain.js";

vi.mock("@sentry/node", () => ({
  captureException: vi.fn(),
  close: vi.fn(),
}));

vi.mock("./lib/utils/utils.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./lib/utils/utils.js")>();
  return {
    ...actual,
    typedPlatformClient: vi.fn(),
    typedBigBrainClient: vi.fn(),
    selectRegion: vi.fn(),
    logNoDefaultRegionMessage: vi.fn(),
  };
});

vi.mock("./lib/deploymentSelection.js", async (importOriginal) => {
  const actual =
    await importOriginal<typeof import("./lib/deploymentSelection.js")>();
  return {
    ...actual,
    initializeBigBrainAuth: vi.fn(),
    getDeploymentSelection: vi.fn(),
    getProjectDetails: vi.fn(),
    deploymentNameFromSelection: vi.fn().mockReturnValue(null),
  };
});

vi.mock("./deploymentSelect.js", () => ({
  saveSelectedDeployment: vi.fn(),
}));

vi.mock("./lib/localDeployment/download.js", () => ({
  ensureBackendBinaryDownloaded: vi.fn(),
}));

vi.mock("./lib/localDeployment/filePaths.js", () => ({
  loadProjectLocalConfig: vi.fn(),
  saveDeploymentConfig: vi.fn(),
}));

vi.mock("./lib/localDeployment/utils.js", () => ({
  chooseLocalBackendPorts: vi.fn(),
}));

vi.mock("./lib/localDeployment/bigBrain.js", () => ({
  bigBrainStart: vi.fn(),
}));

const fakeLocalDevBinary = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "lib/localDeployment/tests/keygenSuccess.mjs",
);

const mockRegions = [
  {
    name: "aws-us-east-1" as const,
    displayName: "US East (Virginia)",
    available: true,
  },
  {
    name: "aws-eu-west-1" as const,
    displayName: "EU West (Ireland)",
    available: true,
  },
];

const mockClasses = [
  {
    type: "s16" as const,
    available: true,
  },
  {
    type: "s256" as const,
    available: true,
  },
  {
    type: "d1024" as const,
    available: false,
  },
];

const mockPlatformGet = vi.fn();
const mockPlatformPost = vi.fn();
const mockBigBrainGet = vi.fn();

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

function setupPlatformClient() {
  vi.mocked(typedPlatformClient).mockReturnValue({
    GET: mockPlatformGet,
    POST: mockPlatformPost,
  } as any);
  vi.mocked(typedBigBrainClient).mockReturnValue({
    GET: mockBigBrainGet,
  } as any);
}

// Suppress process.exit and stderr
beforeEach(() => {
  vi.spyOn(process, "exit").mockImplementation((() => {
    throw new Error("process.exit called");
  }) as any);
  vi.spyOn(process.stderr, "write").mockImplementation(() => true);
  mockPlatformGet.mockReset();
  mockPlatformPost.mockReset();
  mockBigBrainGet.mockReset();
  // Default to a logged-in personal access token; guard tests override this.
  setAuthKind("accessToken");
});

afterEach(() => {
  vi.restoreAllMocks();
});

const fakeProject = {
  id: 123,
  teamId: 456,
  slug: "my-project",
  createTime: 0,
  name: "My Project",
  teamSlug: "my-team",
} satisfies PlatformProjectDetails;

const createdDeployment = {
  kind: "cloud" as const,
  reference: "dev/my-deployment",
  deploymentType: "dev" as const,
  isDefault: false,
};

function setupPlatformForCreate(overrides?: Record<string, unknown>) {
  setupPlatformClient();
  mockPlatformGet.mockImplementation((path: string) => {
    if (path === "/teams/{team_id}/list_deployment_regions") {
      return { data: { items: mockRegions } };
    }
    if (path === "/teams/{team_id}/list_deployment_classes") {
      return { data: { items: mockClasses } };
    }
    throw new Error(`Unmocked GET route: ${path}`);
  });
  mockPlatformPost.mockResolvedValue({
    data: { ...createdDeployment, ...overrides },
  });
}

describe("deploy key guard", () => {
  test.each(["deploymentKey", "previewDeployKey"] as const)(
    "crashes before any platform call when authed with a %s",
    async (kind) => {
      setAuthKind(kind);
      setupPlatformClient();

      await expect(
        deploymentCreate.parseAsync(["my-deployment", "--type", "dev"], {
          from: "user",
        }),
      ).rejects.toThrow();

      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining("isn't supported with a deploy key"),
      );
      expect(mockPlatformGet).not.toHaveBeenCalled();
      expect(mockPlatformPost).not.toHaveBeenCalled();
    },
  );

  test("crashes when no auth is configured at all", async () => {
    setNoAuth();
    setupPlatformClient();

    await expect(
      deploymentCreate.parseAsync(["my-deployment", "--type", "dev"], {
        from: "user",
      }),
    ).rejects.toThrow();

    expect(process.stderr.write).toHaveBeenCalledWith(
      expect.stringContaining("Creating a deployment requires logging in"),
    );
    expect(mockPlatformGet).not.toHaveBeenCalled();
    expect(mockPlatformPost).not.toHaveBeenCalled();
  });

  test("also guards local deployment creation", async () => {
    setAuthKind("deploymentKey");
    setupPlatformClient();

    await expect(
      deploymentCreate.parseAsync(["local"], { from: "user" }),
    ).rejects.toThrow();

    expect(process.stderr.write).toHaveBeenCalledWith(
      expect.stringContaining("isn't supported with a deploy key"),
    );
    expect(mockPlatformGet).not.toHaveBeenCalled();
    expect(mockPlatformPost).not.toHaveBeenCalled();
  });
});

describe("non-interactive create flow", () => {
  beforeEach(() => {
    vi.mocked(getDeploymentSelection).mockReset();
    vi.mocked(getProjectDetails).mockReset();
    vi.mocked(saveSelectedDeployment).mockReset();
    vi.mocked(deploymentNameFromSelection).mockReset();
    vi.mocked(deploymentNameFromSelection).mockReturnValue(null);
  });

  describe("validation errors", () => {
    test("crashes when no ref and no --default", async () => {
      await expect(
        deploymentCreate.parseAsync(["--type", "dev"], { from: "user" }),
      ).rejects.toThrow();
      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining("Specify a deployment ref"),
      );
    });

    test("crashes when --type is missing", async () => {
      await expect(
        deploymentCreate.parseAsync(["my-deployment"], { from: "user" }),
      ).rejects.toThrow();
      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining("--type is required"),
      );
    });

    test("creates a local deployment: downloads binary, chooses ports, registers with Big Brain, saves config", async () => {
      vi.mocked(getDeploymentSelection).mockResolvedValue({
        kind: "existingDeployment",
        deploymentToActOn: {
          url: "https://joyful-capybara-123.convex.cloud",
          adminKey: "admin-key",
          deploymentFields: {
            deploymentName: "joyful-capybara-123",
            deploymentType: "dev",
            teamSlug: "my-team",
            projectSlug: "my-project",
            reference: "dev/nicolas",
            isDefault: true,
          },
          source: "deployKey" as const,
        },
      });
      vi.mocked(getProjectDetails).mockResolvedValue(fakeProject);
      vi.mocked(loadProjectLocalConfig).mockReturnValue(null);
      vi.mocked(ensureBackendBinaryDownloaded).mockResolvedValue({
        binaryPath: fakeLocalDevBinary,
        version: "1.0.0",
      });
      vi.mocked(chooseLocalBackendPorts).mockResolvedValue({
        cloudPort: 3210,
        sitePort: 3211,
      });
      vi.mocked(bigBrainStart).mockResolvedValue({
        deploymentName: "local-test-123",
        adminKey: "test-key",
        projectId: 42,
      });
      setupPlatformClient();
      mockPlatformGet.mockResolvedValue({ data: { items: [] } });

      await deploymentCreate.parseAsync(["local"], { from: "user" });

      expect(saveDeploymentConfig).toHaveBeenCalledWith(
        expect.anything(),
        "local",
        "local-test-123",
        {
          backendVersion: "1.0.0",
          ports: { cloud: 3210, site: 3211 },
          adminKey: "local-test-123|mock_admin_key",
          instanceSecret: expect.anything(),
          cloudProjectId: fakeProject.id,
        },
      );
      expect(mockPlatformPost).not.toHaveBeenCalled();
    });

    test("creates a local deployment with --select and selects it", async () => {
      vi.mocked(getDeploymentSelection).mockResolvedValue({
        kind: "existingDeployment",
        deploymentToActOn: {
          url: "https://joyful-capybara-123.convex.cloud",
          adminKey: "admin-key",
          deploymentFields: {
            deploymentName: "joyful-capybara-123",
            deploymentType: "dev",
            teamSlug: "my-team",
            projectSlug: "my-project",
            reference: "dev/nicolas",
            isDefault: true,
          },
          source: "deployKey" as const,
        },
      });
      vi.mocked(getProjectDetails).mockResolvedValue(fakeProject);
      vi.mocked(loadProjectLocalConfig).mockReturnValue(null);
      vi.mocked(ensureBackendBinaryDownloaded).mockResolvedValue({
        binaryPath: fakeLocalDevBinary,
        version: "1.0.0",
      });
      vi.mocked(chooseLocalBackendPorts).mockResolvedValue({
        cloudPort: 3210,
        sitePort: 3211,
      });
      vi.mocked(bigBrainStart).mockResolvedValue({
        deploymentName: "local-test-123",
        adminKey: "test-key",
        projectId: 42,
      });
      setupPlatformClient();
      mockPlatformGet.mockResolvedValue({ data: { items: [] } });

      await deploymentCreate.parseAsync(["local", "--select"], {
        from: "user",
      });

      expect(saveSelectedDeployment).toHaveBeenCalledWith(
        expect.anything(),
        "local",
        {
          kind: "deploymentWithinProject",
          targetProject: {
            kind: "deploymentName",
            deploymentName: "local-test-123",
            deploymentType: "local",
          },
          selectionWithinProject: {
            kind: "deploymentSelector",
            selector: "local",
          },
        },
        null,
      );
    });

    test("crashes when creating a local deployment with --type", async () => {
      await expect(
        deploymentCreate.parseAsync(["local", "--type", "dev"], {
          from: "user",
        }),
      ).rejects.toThrow();
      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining(
          "--type cannot be used when creating a local deployment",
        ),
      );
      expect(mockPlatformPost).not.toHaveBeenCalled();
    });

    test("errors when local deployment already exists", async () => {
      vi.mocked(getDeploymentSelection).mockResolvedValue({
        kind: "existingDeployment",
        deploymentToActOn: {
          url: "https://joyful-capybara-123.convex.cloud",
          adminKey: "admin-key",
          deploymentFields: {
            deploymentName: "joyful-capybara-123",
            deploymentType: "dev",
            teamSlug: "my-team",
            projectSlug: "my-project",
            reference: "dev/nicolas",
            isDefault: true,
          },
          source: "deployKey" as const,
        },
      });
      vi.mocked(loadProjectLocalConfig).mockReturnValue({
        deploymentName: "existing-local-123",
        config: {} as any,
      });

      await expect(
        deploymentCreate.parseAsync(["local"], { from: "user" }),
      ).rejects.toThrow();
      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining("A local deployment already exists"),
      );
    });

    test.each(["region", "class", "default", "expiration"] as const)(
      "rejects --%s with local",
      async (flag) => {
        const args = ["local", `--${flag}`];
        if (flag === "region") args.push("us");
        if (flag === "class") args.push("s16");
        if (flag === "expiration") args.push("none");

        await expect(
          deploymentCreate.parseAsync(args, { from: "user" }),
        ).rejects.toThrow();
        expect(process.stderr.write).toHaveBeenCalledWith(
          expect.stringContaining(
            `--${flag} cannot be used when creating a local deployment`,
          ),
        );
      },
    );
  });

  describe("with project configured", () => {
    beforeEach(() => {
      vi.mocked(getDeploymentSelection).mockResolvedValue({
        kind: "existingDeployment",
        deploymentToActOn: {
          url: "https://joyful-capybara-123.convex.cloud",
          adminKey: "admin-key",
          deploymentFields: {
            deploymentName: "joyful-capybara-123",
            deploymentType: "dev",
            teamSlug: "my-team",
            projectSlug: "my-project",
            reference: "dev/nicolas",
            isDefault: true,
          },
          source: "deployKey" as const,
        },
      });
      vi.mocked(getProjectDetails).mockResolvedValue(fakeProject);
    });

    test("creates a dev deployment with ref and --type dev", async () => {
      setupPlatformForCreate();

      await deploymentCreate.parseAsync(["my-deployment", "--type", "dev"], {
        from: "user",
      });

      expect(mockPlatformPost).toHaveBeenCalledWith(
        "/projects/{project_id}/create_deployment",
        expect.objectContaining({
          params: { path: { project_id: 123 } },
          body: {
            type: "dev",
            region: null,
            reference: "my-deployment",
            isDefault: null,
          },
        }),
      );
    });

    test("allows a project key (creates the deployment)", async () => {
      setAuthKind("projectKey");
      setupPlatformForCreate();

      await deploymentCreate.parseAsync(["my-deployment", "--type", "dev"], {
        from: "user",
      });

      expect(mockPlatformPost).toHaveBeenCalledWith(
        "/projects/{project_id}/create_deployment",
        expect.objectContaining({
          body: expect.objectContaining({
            type: "dev",
            reference: "my-deployment",
          }),
        }),
      );
    });

    test("creates a prod deployment with ref and --type prod", async () => {
      setupPlatformForCreate({
        deploymentType: "prod",
        reference: "staging",
      });

      await deploymentCreate.parseAsync(["staging", "--type", "prod"], {
        from: "user",
      });

      expect(mockPlatformPost).toHaveBeenCalledWith(
        "/projects/{project_id}/create_deployment",
        expect.objectContaining({
          body: expect.objectContaining({
            type: "prod",
            reference: "staging",
          }),
        }),
      );
    });

    test("creates a deployment with --default flag", async () => {
      setupPlatformForCreate({ isDefault: true });

      await deploymentCreate.parseAsync(
        ["my-deployment", "--type", "dev", "--default"],
        { from: "user" },
      );

      expect(mockPlatformPost).toHaveBeenCalledWith(
        "/projects/{project_id}/create_deployment",
        expect.objectContaining({
          body: expect.objectContaining({
            isDefault: true,
          }),
        }),
      );
    });

    test("creates a default deployment without a ref", async () => {
      setupPlatformForCreate({ isDefault: true, reference: null });

      await deploymentCreate.parseAsync(["--type", "dev", "--default"], {
        from: "user",
      });

      expect(mockPlatformPost).toHaveBeenCalledWith(
        "/projects/{project_id}/create_deployment",
        expect.objectContaining({
          body: {
            type: "dev",
            region: null,
            reference: null,
            isDefault: true,
          },
        }),
      );
    });

    test("creates a deployment with --region full name", async () => {
      setupPlatformForCreate();

      await deploymentCreate.parseAsync(
        ["my-deployment", "--type", "dev", "--region", "aws-eu-west-1"],
        { from: "user" },
      );

      expect(mockPlatformGet).toHaveBeenCalledWith(
        "/teams/{team_id}/list_deployment_regions",
        expect.objectContaining({
          params: { path: { team_id: "456" } },
        }),
      );
      expect(mockPlatformPost).toHaveBeenCalledWith(
        "/projects/{project_id}/create_deployment",
        expect.objectContaining({
          body: expect.objectContaining({
            region: "aws-eu-west-1",
          }),
        }),
      );
    });

    test("creates a deployment with --region alias", async () => {
      setupPlatformForCreate();

      await deploymentCreate.parseAsync(
        ["my-deployment", "--type", "dev", "--region", "us"],
        { from: "user" },
      );

      expect(mockPlatformPost).toHaveBeenCalledWith(
        "/projects/{project_id}/create_deployment",
        expect.objectContaining({
          body: expect.objectContaining({
            region: "aws-us-east-1",
          }),
        }),
      );
    });

    test("fails with invalid --region", async () => {
      setupPlatformForCreate();

      await expect(
        deploymentCreate.parseAsync(
          ["my-deployment", "--type", "dev", "--region", "invalid-region"],
          { from: "user" },
        ),
      ).rejects.toThrow();
      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining('Invalid region "invalid-region"'),
      );
    });

    test("creates a deployment with --class", async () => {
      setupPlatformForCreate();

      await deploymentCreate.parseAsync(
        ["my-deployment", "--type", "dev", "--class", "s256"],
        { from: "user" },
      );

      expect(mockPlatformGet).toHaveBeenCalledWith(
        "/teams/{team_id}/list_deployment_classes",
        expect.objectContaining({
          params: { path: { team_id: "456" } },
        }),
      );
      expect(mockPlatformPost).toHaveBeenCalledWith(
        "/projects/{project_id}/create_deployment",
        expect.objectContaining({
          body: expect.objectContaining({
            class: "s256",
          }),
        }),
      );
    });

    test("fails with invalid --class", async () => {
      setupPlatformForCreate();

      await expect(
        deploymentCreate.parseAsync(
          ["my-deployment", "--type", "dev", "--class", "invalid-class"],
          { from: "user" },
        ),
      ).rejects.toThrow();
      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining('Invalid class "invalid-class"'),
      );
    });

    test("fails with unavailable --class", async () => {
      setupPlatformForCreate();

      await expect(
        deploymentCreate.parseAsync(
          ["my-deployment", "--type", "dev", "--class", "d1024"],
          { from: "user" },
        ),
      ).rejects.toThrow();
      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining('Invalid class "d1024"'),
      );
    });

    test("no --class flag does not include class in body", async () => {
      setupPlatformForCreate();

      await deploymentCreate.parseAsync(["my-deployment", "--type", "dev"], {
        from: "user",
      });

      const call = mockPlatformPost.mock.calls[0];
      expect(call[1].body).not.toHaveProperty("class");
    });

    test("creates a deployment with --select calls saveSelectedDeployment", async () => {
      setupPlatformForCreate({
        reference: "dev/my-deployment",
      });

      await deploymentCreate.parseAsync(
        ["my-deployment", "--type", "dev", "--select"],
        { from: "user" },
      );

      expect(saveSelectedDeployment).toHaveBeenCalledWith(
        expect.anything(),
        "dev/my-deployment",
        {
          kind: "deploymentWithinProject",
          targetProject: {
            kind: "teamAndProjectSlugs",
            teamSlug: "my-team",
            projectSlug: "my-project",
          },
          selectionWithinProject: {
            kind: "deploymentSelector",
            selector: "dev/my-deployment",
          },
        },
        null,
      );
    });
  });

  describe("with team:project:ref syntax", () => {
    test("uses getProjectDetails with teamAndProjectSlugs", async () => {
      vi.mocked(getProjectDetails).mockResolvedValue({
        ...fakeProject,
        slug: "other-project",
        teamSlug: "other-team",
      });
      setupPlatformForCreate();

      await deploymentCreate.parseAsync(
        ["other-team:other-project:my-deployment", "--type", "dev"],
        { from: "user" },
      );

      expect(getProjectDetails).toHaveBeenCalledWith(expect.anything(), {
        kind: "teamAndProjectSlugs",
        teamSlug: "other-team",
        projectSlug: "other-project",
      });
      expect(mockPlatformPost).toHaveBeenCalledWith(
        "/projects/{project_id}/create_deployment",
        expect.objectContaining({
          body: expect.objectContaining({
            reference: "my-deployment",
          }),
        }),
      );
    });
  });

  describe("project-scoped local deployment creation", () => {
    const chooseProjectSelection: DeploymentSelection = {
      kind: "chooseProject",
      selectionWithinProject: { kind: "unspecified" },
    };

    test("creates a local deployment with team:project:local", async () => {
      vi.mocked(getDeploymentSelection).mockResolvedValue(
        chooseProjectSelection,
      );
      vi.mocked(getProjectDetails).mockResolvedValue({
        ...fakeProject,
        id: 999,
        teamSlug: "other-team",
        slug: "other-project",
      });
      vi.mocked(loadProjectLocalConfig).mockReturnValue(null);
      vi.mocked(ensureBackendBinaryDownloaded).mockResolvedValue({
        binaryPath: fakeLocalDevBinary,
        version: "1.0.0",
      });
      vi.mocked(chooseLocalBackendPorts).mockResolvedValue({
        cloudPort: 3210,
        sitePort: 3211,
      });
      vi.mocked(bigBrainStart).mockResolvedValue({
        deploymentName: "local-other_team-other_project-xyz",
        adminKey: "other-key",
        projectId: 42,
      });
      setupPlatformClient();
      mockPlatformGet.mockResolvedValue({ data: { items: [] } });

      await deploymentCreate.parseAsync(["other-team:other-project:local"], {
        from: "user",
      });

      expect(getProjectDetails).toHaveBeenCalledWith(expect.anything(), {
        kind: "teamAndProjectSlugs",
        teamSlug: "other-team",
        projectSlug: "other-project",
      });
      expect(bigBrainStart).toHaveBeenCalledWith(
        expect.anything(),
        expect.objectContaining({
          teamSlug: "other-team",
          projectSlug: "other-project",
        }),
      );
      expect(saveDeploymentConfig).toHaveBeenCalledWith(
        expect.anything(),
        "local",
        "local-other_team-other_project-xyz",
        expect.objectContaining({
          adminKey: "local-other_team-other_project-xyz|mock_admin_key",
          cloudProjectId: 999,
        }),
      );
    });

    test("rejects project:local without team prefix", async () => {
      vi.mocked(getDeploymentSelection).mockResolvedValue(
        chooseProjectSelection,
      );

      await expect(
        deploymentCreate.parseAsync(["other-project:local"], { from: "user" }),
      ).rejects.toThrow();
      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining(
          "Please use `team:project:local` to specify the team",
        ),
      );
    });

    test("team:project:local with --select selects the new local deployment", async () => {
      vi.mocked(getDeploymentSelection).mockResolvedValue(
        chooseProjectSelection,
      );
      vi.mocked(getProjectDetails).mockResolvedValue({
        ...fakeProject,
        id: 999,
        teamSlug: "other-team",
        slug: "other-project",
      });
      vi.mocked(loadProjectLocalConfig).mockReturnValue(null);
      vi.mocked(ensureBackendBinaryDownloaded).mockResolvedValue({
        binaryPath: fakeLocalDevBinary,
        version: "1.0.0",
      });
      vi.mocked(chooseLocalBackendPorts).mockResolvedValue({
        cloudPort: 3210,
        sitePort: 3211,
      });
      vi.mocked(bigBrainStart).mockResolvedValue({
        deploymentName: "local-other_team-other_project-xyz",
        adminKey: "other-key",
        projectId: 42,
      });
      setupPlatformClient();
      mockPlatformGet.mockResolvedValue({ data: { items: [] } });

      await deploymentCreate.parseAsync(
        ["other-team:other-project:local", "--select"],
        { from: "user" },
      );

      expect(saveSelectedDeployment).toHaveBeenCalledWith(
        expect.anything(),
        "local",
        expect.objectContaining({
          targetProject: {
            kind: "deploymentName",
            deploymentName: "local-other_team-other_project-xyz",
            deploymentType: "local",
          },
        }),
        null,
      );
    });

    test("plain `local` fails when no project context is available", async () => {
      vi.mocked(getDeploymentSelection).mockResolvedValue(
        chooseProjectSelection,
      );
      vi.mocked(loadProjectLocalConfig).mockReturnValue(null);

      await expect(
        deploymentCreate.parseAsync(["local"], { from: "user" }),
      ).rejects.toThrow();
      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining("No project configured yet"),
      );
    });
  });

  describe("--expiration flag", () => {
    beforeEach(() => {
      vi.mocked(getDeploymentSelection).mockResolvedValue({
        kind: "existingDeployment",
        deploymentToActOn: {
          url: "https://joyful-capybara-123.convex.cloud",
          adminKey: "admin-key",
          deploymentFields: {
            deploymentName: "joyful-capybara-123",
            deploymentType: "dev",
            teamSlug: "my-team",
            projectSlug: "my-project",
            reference: "dev/nicolas",
            isDefault: true,
          },
          source: "deployKey" as const,
        },
      });
      vi.mocked(getProjectDetails).mockResolvedValue(fakeProject);
    });

    test("--expiration none sends expiresAt: null", async () => {
      setupPlatformForCreate();

      await deploymentCreate.parseAsync(
        ["my-deployment", "--type", "dev", "--expiration", "none"],
        { from: "user" },
      );

      expect(mockPlatformPost).toHaveBeenCalledWith(
        "/projects/{project_id}/create_deployment",
        expect.objectContaining({
          body: expect.objectContaining({
            expiresAt: null,
          }),
        }),
      );
    });

    test("--expiration with timestamp sends correct ms value", async () => {
      setupPlatformForCreate();

      // Use a timestamp far enough in the future to pass validation
      const futureMs = Date.now() + 2 * 60 * 60 * 1000; // 2 hours from now
      const futureSec = Math.floor(futureMs / 1000);

      await deploymentCreate.parseAsync(
        [
          "my-deployment",
          "--type",
          "dev",
          "--expiration",
          futureSec.toString(),
        ],
        { from: "user" },
      );

      expect(mockPlatformPost).toHaveBeenCalledWith(
        "/projects/{project_id}/create_deployment",
        expect.objectContaining({
          body: expect.objectContaining({
            expiresAt: futureSec * 1000,
          }),
        }),
      );
    });

    test("no --expiration flag does not include expiresAt in body", async () => {
      setupPlatformForCreate();

      await deploymentCreate.parseAsync(["my-deployment", "--type", "dev"], {
        from: "user",
      });

      const call = mockPlatformPost.mock.calls[0];
      expect(call[1].body).not.toHaveProperty("expiresAt");
    });
  });

  describe("without project configured", () => {
    beforeEach(() => {
      vi.mocked(getDeploymentSelection).mockResolvedValue({
        kind: "chooseProject",
      } as any);
    });

    test("fails with bare ref when no project context", async () => {
      await expect(
        deploymentCreate.parseAsync(["my-deployment", "--type", "dev"], {
          from: "user",
        }),
      ).rejects.toThrow();
      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining("No project configured yet"),
      );
    });

    test("succeeds with team:project:ref syntax", async () => {
      vi.mocked(getProjectDetails).mockResolvedValue(fakeProject);
      setupPlatformForCreate();

      await deploymentCreate.parseAsync(
        ["my-team:my-project:my-deployment", "--type", "dev"],
        { from: "user" },
      );

      expect(getProjectDetails).toHaveBeenCalledWith(expect.anything(), {
        kind: "teamAndProjectSlugs",
        teamSlug: "my-team",
        projectSlug: "my-project",
      });
      expect(mockPlatformPost).toHaveBeenCalled();
    });

    test("hint includes full team:project:ref when no project configured in current directory", async () => {
      vi.mocked(getProjectDetails).mockResolvedValue(fakeProject);
      setupPlatformForCreate();

      await deploymentCreate.parseAsync(
        ["my-team:my-project:my-deployment", "--type", "dev"],
        { from: "user" },
      );

      expect(process.stderr.write).toHaveBeenCalledWith(
        expect.stringContaining(
          "npx convex deployment select my-team:my-project:dev/my-deployment",
        ),
      );
    });
  });
});

describe("interactive create flow", () => {
  beforeEach(() => {
    process.stdin.isTTY = true;
    vi.mocked(getDeploymentSelection).mockReset();
    vi.mocked(getProjectDetails).mockReset();
    vi.mocked(saveSelectedDeployment).mockReset();
    vi.mocked(selectRegion).mockReset();
    vi.mocked(deploymentNameFromSelection).mockReset();
    vi.mocked(deploymentNameFromSelection).mockReturnValue(null);

    // Default: project configured via deployment selection
    vi.mocked(getDeploymentSelection).mockResolvedValue({
      kind: "existingDeployment",
      deploymentToActOn: {
        url: "https://joyful-capybara-123.convex.cloud",
        adminKey: "admin-key",
        deploymentFields: {
          deploymentName: "joyful-capybara-123",
          deploymentType: "dev",
          teamSlug: "my-team",
          projectSlug: "my-project",
          reference: "dev/nicolas",
          isDefault: true,
        },
        source: "deployKey" as const,
      },
    });
    vi.mocked(getProjectDetails).mockResolvedValue(fakeProject);
  });

  afterEach(() => {
    process.stdin.isTTY = false;
  });

  function setupPlatformRoutes(routes: Record<string, (args: any) => any>) {
    setupPlatformClient();
    mockPlatformGet.mockImplementation((path: string, args: any) => {
      for (const [routePath, handler] of Object.entries(routes)) {
        if (path === routePath || path.startsWith(routePath)) {
          return { data: handler(args) };
        }
      }
      throw new Error(`Unmocked GET route: ${path}`);
    });
    mockPlatformPost.mockResolvedValue({
      data: { ...createdDeployment },
    });
  }

  function setupDefaultRoutes() {
    setupPlatformRoutes({
      "/teams/{team_id}/list_deployment_regions": () => ({
        items: mockRegions,
      }),
      "/teams/{team_id}/list_deployment_classes": () => ({
        items: mockClasses,
      }),
    });
    mockBigBrainGet.mockResolvedValue({
      data: [{ id: 456, slug: "my-team", defaultRegion: "aws-us-east-1" }],
    });
  }

  test.each([
    { deploymentType: "dev" as const, downPresses: 0 },
    { deploymentType: "preview" as const, downPresses: 1 },
    { deploymentType: "prod" as const, downPresses: 2 },
  ])(
    "selecting $deploymentType calls endpoint with type=$deploymentType",
    async ({ deploymentType, downPresses }) => {
      setupDefaultRoutes();

      const promise = deploymentCreate.parseAsync([], { from: "user" });

      // Type prompt (select)
      await screen.next();
      expect(screen.getScreen()).toContain("Deployment type?");
      for (let i = 0; i < downPresses; i++) {
        screen.keypress("down");
      }
      screen.keypress("enter");

      // Ref prompt (input)
      await screen.next();
      expect(screen.getScreen()).toContain(
        "What do you want to call this deployment",
      );
      screen.type("my-feature");
      screen.keypress("enter");

      await promise;

      expect(mockPlatformPost).toHaveBeenCalledWith(
        "/projects/{project_id}/create_deployment",
        expect.objectContaining({
          body: expect.objectContaining({
            type: deploymentType,
          }),
        }),
      );
    },
  );

  test("full prompt flow: select type, enter ref", async () => {
    setupDefaultRoutes();

    const promise = deploymentCreate.parseAsync([], { from: "user" });

    // Type prompt (select) — "dev" is first choice, just press enter
    await screen.next();
    expect(screen.getScreen()).toContain("Deployment type?");
    screen.keypress("enter");

    // Ref prompt (input)
    await screen.next();
    expect(screen.getScreen()).toContain(
      "What do you want to call this deployment",
    );
    screen.type("my-feature");
    screen.keypress("enter");

    await promise;

    expect(mockPlatformPost).toHaveBeenCalledWith(
      "/projects/{project_id}/create_deployment",
      expect.objectContaining({
        body: {
          type: "dev",
          region: "aws-us-east-1",
          reference: "my-feature",
          isDefault: null,
        },
      }),
    );
  });

  test("partial flags: --type dev and ref provided, no prompts needed", async () => {
    setupDefaultRoutes();

    const promise = deploymentCreate.parseAsync(
      ["my-feature", "--type", "dev"],
      { from: "user" },
    );

    await promise;

    expect(mockPlatformPost).toHaveBeenCalledWith(
      "/projects/{project_id}/create_deployment",
      expect.objectContaining({
        body: expect.objectContaining({
          type: "dev",
          reference: "my-feature",
          isDefault: null,
        }),
      }),
    );
  });

  test("invalid ref retry: user enters invalid ref, then valid ref", async () => {
    setupDefaultRoutes();

    const promise = deploymentCreate.parseAsync(["--type", "dev"], {
      from: "user",
    });

    // Ref prompt — enter invalid ref "dev"
    await screen.next();
    expect(screen.getScreen()).toContain(
      "What do you want to call this deployment",
    );
    screen.type("dev");
    screen.keypress("enter");

    // Inline validation error, then edit input
    await screen.next();
    expect(screen.getScreen()).toContain(
      '"dev" is reserved as an alias for your default dev deployment.',
    );
    screen.type("/my-feature");
    screen.keypress("enter");

    await promise;

    expect(mockPlatformPost).toHaveBeenCalledWith(
      "/projects/{project_id}/create_deployment",
      expect.objectContaining({
        body: expect.objectContaining({
          reference: "dev/my-feature",
          isDefault: null,
        }),
      }),
    );
  });

  test("interactive ref prompt rejects 'local' as a deployment reference", async () => {
    setupDefaultRoutes();

    const promise = deploymentCreate.parseAsync(["--type", "dev"], {
      from: "user",
    });

    // Ref prompt — enter "local"
    await screen.next();
    expect(screen.getScreen()).toContain(
      "What do you want to call this deployment",
    );
    screen.type("local");
    screen.keypress("enter");

    // Inline validation error
    await screen.next();
    expect(screen.getScreen()).toContain(
      '"local" is reserved as an alias for your local deployment',
    );

    // Fix the input
    screen.type("ization-improvements");
    screen.keypress("enter");

    await promise;

    expect(mockPlatformPost).toHaveBeenCalledWith(
      "/projects/{project_id}/create_deployment",
      expect.objectContaining({
        body: expect.objectContaining({
          reference: "localization-improvements",
        }),
      }),
    );
  });

  test("--region invalid crashes", async () => {
    setupDefaultRoutes();

    await expect(
      deploymentCreate.parseAsync(
        ["my-feature", "--type", "dev", "--region", "invalid-region"],
        { from: "user" },
      ),
    ).rejects.toThrow();
    expect(process.stderr.write).toHaveBeenCalledWith(
      expect.stringContaining('Invalid region "invalid-region"'),
    );
  });

  test("no team default region: falls through to selectRegion", async () => {
    setupDefaultRoutes();
    // Override BigBrain to return team without defaultRegion
    mockBigBrainGet.mockResolvedValue({
      data: [{ id: 456, slug: "my-team" }],
    });
    vi.mocked(selectRegion).mockResolvedValue("aws-us-east-1");

    await deploymentCreate.parseAsync(["my-feature", "--type", "dev"], {
      from: "user",
    });

    expect(selectRegion).toHaveBeenCalledWith(expect.anything(), 456, "dev");
    expect(logNoDefaultRegionMessage).toHaveBeenCalledWith("my-team");
  });

  test("uses team default region when no --region provided", async () => {
    setupDefaultRoutes();

    const promise = deploymentCreate.parseAsync(
      ["my-feature", "--type", "dev"],
      { from: "user" },
    );

    await promise;

    expect(selectRegion).not.toHaveBeenCalled();
    expect(mockPlatformPost).toHaveBeenCalledWith(
      "/projects/{project_id}/create_deployment",
      expect.objectContaining({
        body: expect.objectContaining({
          region: "aws-us-east-1",
        }),
      }),
    );
  });
});

const availableRegions = mockRegions.filter((r) => r.available);

describe("resolveRegionDetails", () => {
  test("resolves region by alias", () => {
    const result = resolveRegionDetails(availableRegions, "us");
    expect(result).not.toBeNull();
    expect(result!.name).toBe("aws-us-east-1");
    expect(result!.displayName).toBe("US East (Virginia)");
  });

  test("resolves region by full name", () => {
    const result = resolveRegionDetails(availableRegions, "aws-eu-west-1");
    expect(result).not.toBeNull();
    expect(result!.name).toBe("aws-eu-west-1");
    expect(result!.displayName).toBe("EU West (Ireland)");
  });

  test("returns null on unknown region", () => {
    const result = resolveRegionDetails(availableRegions, "invalid-region");
    expect(result).toBeNull();
  });

  test("returns null on unavailable region", () => {
    const result = resolveRegionDetails(availableRegions, "aws-ap-southeast-1");
    expect(result).toBeNull();
  });
});

const availableClasses = mockClasses.filter((c) => c.available);

describe("resolveClassDetails", () => {
  test("resolves class by type", () => {
    const result = resolveClassDetails(availableClasses, "s16");
    expect(result).not.toBeNull();
    expect(result!.type).toBe("s16");
  });

  test("resolves another class by type", () => {
    const result = resolveClassDetails(availableClasses, "s256");
    expect(result).not.toBeNull();
    expect(result!.type).toBe("s256");
  });

  test("returns null on unknown class", () => {
    const result = resolveClassDetails(availableClasses, "invalid-class");
    expect(result).toBeNull();
  });

  test("returns null on unavailable class", () => {
    const result = resolveClassDetails(availableClasses, "d1024");
    expect(result).toBeNull();
  });
});
