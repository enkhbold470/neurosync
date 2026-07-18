import { test, expect, describe, vi } from "vitest";
import { fileURLToPath } from "url";
import path from "path";
import { Context } from "../../../bundler/context.js";
import { generateLocalDevSecrets } from "./secrets.js";

// We test that `generateLocalDevSecrets` can correctly generate admin
// keys from the CLI by using fake binaries that return mock values
const fixturesDir = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "tests",
);
const successBinary = path.join(fixturesDir, "keygenSuccess.mjs");
const failureBinary = path.join(fixturesDir, "keygenFailure.mjs");

function mockContext(): Context {
  return {
    crash: vi.fn((args: { printedMessage: string | null }) => {
      throw new Error(args.printedMessage ?? "crash");
    }),
  } as unknown as Context;
}

describe("generateLocalDevSecrets", () => {
  test("returns an instance secret and admin key from the binary", async () => {
    const ctx = mockContext();

    const { instanceSecret, adminKey } = await generateLocalDevSecrets(ctx, {
      deploymentName: "my-deployment",
      latestBinaryPath: successBinary,
    });

    // The fixture echoes back the instance name as the first part of the key.
    expect(adminKey).toBe("my-deployment|mock_admin_key");
    // The instance secret is 32 random bytes, hex-encoded.
    expect(instanceSecret).toMatch(/^[0-9a-f]{64}$/);
  });

  test("crashes when the binary fails", async () => {
    const ctx = mockContext();

    await expect(
      generateLocalDevSecrets(ctx, {
        deploymentName: "my-deployment",
        latestBinaryPath: failureBinary,
      }),
    ).rejects.toThrow();

    expect(vi.mocked(ctx.crash).mock.calls[0][0].printedMessage).toContain(
      "Failed to generate admin key",
    );
  });
});
