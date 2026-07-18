import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { Chalk } from "chalk";
import { formatTargetedDeployment } from "./announceDeploymentTarget.js";
import type { DetailedDeploymentCredentials } from "./api.js";

const chalk = new Chalk({ level: 3 });

function creds(
  overrides: Partial<DetailedDeploymentCredentials> & {
    fields?: Partial<
      NonNullable<DetailedDeploymentCredentials["deploymentFields"]>
    > | null;
  } = {},
): DetailedDeploymentCredentials {
  const { fields, ...rest } = overrides;
  // Explicit `fields: null` clears the deployment fields entirely (the
  // self-hosted / `--url+--admin-key` case). Otherwise merge with defaults.
  const deploymentFields =
    fields === null
      ? null
      : {
          deploymentName: "happy-animal-123",
          deploymentType: "dev" as const,
          teamSlug: "my-team",
          projectSlug: "my-project",
          reference: null,
          isDefault: false,
          ...fields,
        };
  return {
    adminKey: "test-admin-key",
    url: "https://happy-animal-123.convex.cloud",
    deploymentFields,
    ...rest,
  };
}

describe("formatTargetedDeployment", () => {
  let originalIsTTY = process.stderr.isTTY;
  beforeAll(() => {
    process.stderr.isTTY = true;
  });
  afterAll(() => {
    process.stderr.isTTY = originalIsTTY;
  });

  describe("standard terminal", () => {
    test("default dev deployment shows reference and (dev) alias", () => {
      expect(
        formatTargetedDeployment(
          null,
          creds({
            fields: {
              deploymentType: "dev",
              reference: "dev/nicolas",
              isDefault: true,
            },
          }),
          chalk,
        ),
      ).toMatchSnapshot();
    });

    test("non-default dev deployment shows reference without alias", () => {
      expect(
        formatTargetedDeployment(
          null,
          creds({
            fields: {
              deploymentType: "dev",
              reference: "dev/staging-test",
              isDefault: false,
            },
          }),
          chalk,
        ),
      ).toMatchSnapshot();
    });

    test("default prod deployment shows reference and (prod) alias", () => {
      expect(
        formatTargetedDeployment(
          null,
          creds({
            fields: {
              deploymentType: "prod",
              reference: "production",
              isDefault: true,
            },
          }),
          chalk,
        ),
      ).toMatchSnapshot();
    });

    test("non-default prod deployment shows reference without alias", () => {
      expect(
        formatTargetedDeployment(
          null,
          creds({
            fields: {
              deploymentType: "prod",
              reference: "prod-shadow",
              isDefault: false,
            },
          }),
          chalk,
        ),
      ).toMatchSnapshot();
    });

    test("preview deployment with team and project", () => {
      expect(
        formatTargetedDeployment(
          null,
          creds({
            fields: {
              deploymentType: "preview",
              deploymentName: "happy-otter-123",
              reference: "preview/pr-42",
            },
          }),
          chalk,
        ),
      ).toMatchSnapshot();
    });

    test("preview deployment without a reference falls back to deploymentName", () => {
      expect(
        formatTargetedDeployment(
          null,
          creds({
            fields: {
              deploymentType: "preview",
              deploymentName: "happy-otter-123",
              reference: null,
            },
          }),
          chalk,
        ),
      ).toMatchSnapshot();
    });

    test("custom deployment with team and project", () => {
      expect(
        formatTargetedDeployment(
          null,
          creds({
            fields: {
              deploymentType: "custom",
              deploymentName: "playful-otter-999",
              reference: "my-staging-shadow",
            },
          }),
          chalk,
        ),
      ).toMatchSnapshot();
    });

    test("dev deployment without team/project slugs", () => {
      expect(
        formatTargetedDeployment(
          null,
          creds({ fields: { teamSlug: null, projectSlug: null } }),
          chalk,
        ),
      ).toMatchSnapshot();
    });

    test("local deployment with team and project", () => {
      expect(
        formatTargetedDeployment(
          null,
          creds({
            url: "http://127.0.0.1:3210",
            fields: {
              deploymentType: "local",
              deploymentName: "local",
            },
          }),
          chalk,
        ),
      ).toMatchSnapshot();
    });

    test("local deployment without team/project slugs", () => {
      expect(
        formatTargetedDeployment(
          null,
          creds({
            url: "http://127.0.0.1:3210",
            fields: {
              deploymentType: "local",
              deploymentName: "local",
              teamSlug: null,
              projectSlug: null,
            },
          }),
          chalk,
        ),
      ).toMatchSnapshot();
    });

    test("anonymous deployment", () => {
      expect(
        formatTargetedDeployment(
          null,
          creds({
            url: "http://127.0.0.1:3210",
            fields: {
              deploymentType: "anonymous",
              deploymentName: "anonymous",
              teamSlug: null,
              projectSlug: null,
            },
          }),
          chalk,
        ),
      ).toMatchSnapshot();
    });

    test("self-hosted deployment", () => {
      expect(
        formatTargetedDeployment(
          "Deploying code to deployment:",
          creds({
            url: "https://convex.my-company.com",
            fields: null,
          }),
          chalk,
        ),
      ).toMatchSnapshot();
    });
  });

  describe("every header value", () => {
    test("no header (used after logFinishedStep)", () => {
      expect(formatTargetedDeployment(null, creds(), chalk)).toMatchSnapshot();
    });

    test("dev", () => {
      expect(
        formatTargetedDeployment(
          "Developing against deployment:",
          creds(),
          chalk,
        ),
      ).toMatchSnapshot();
    });

    test("logs", () => {
      expect(
        formatTargetedDeployment("Showing logs of deployment:", creds(), chalk),
      ).toMatchSnapshot();
    });

    test("deploy", () => {
      expect(
        formatTargetedDeployment(
          "Deploying code to deployment:",
          creds(),
          chalk,
        ),
      ).toMatchSnapshot();
    });
  });

  describe("terminals with partial feature support", () => {
    test("without colors", () => {
      expect(
        formatTargetedDeployment(null, creds(), new Chalk({ level: 0 })),
      ).toMatchSnapshot();
    });

    test("without link support", () => {
      process.stderr.isTTY = false;

      expect(formatTargetedDeployment(null, creds(), chalk)).toMatchSnapshot();
    });
  });
});
