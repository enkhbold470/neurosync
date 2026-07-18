import { test, expect, describe, beforeEach, vi } from "vitest";
import { Context } from "../../../bundler/context.js";
import { createCORSOrigin, createRedirectURI } from "./environmentApi.js";

const mockFetch = vi.fn();
global.fetch = mockFetch;

const ctx: Context = {
  crash: vi.fn(async (args: { printedMessage: string | null }) => {
    throw new Error(args.printedMessage ?? "crash");
  }),
} as unknown as Context;

beforeEach(() => {
  vi.clearAllMocks();
});

describe("createRedirectURI", () => {
  test("returns modified: true on a successful response", async () => {
    mockFetch.mockResolvedValue(new Response(null, { status: 201 }));
    await expect(
      createRedirectURI(ctx, "key", "http://localhost:5173"),
    ).resolves.toEqual({ modified: true });
  });

  test("returns modified: false when the URI already exists", async () => {
    mockFetch.mockResolvedValue(
      new Response(
        `{"message":"Redirect URI 'http://localhost:5173' already exists.","error":"Unprocessable Entity"}`,
        { status: 422 },
      ),
    );
    await expect(
      createRedirectURI(ctx, "key", "http://localhost:5173"),
    ).resolves.toEqual({ modified: false });
    expect(ctx.crash).not.toHaveBeenCalled();
  });

  test("crashes with the body for a non-duplicate 422", async () => {
    const body = `{"message":"Redirect URI 'test' is invalid.","error":"Unprocessable Entity"}`;
    mockFetch.mockResolvedValue(new Response(body, { status: 422 }));
    await expect(createRedirectURI(ctx, "key", "test")).rejects.toThrow(
      `Failed to create redirect URI: 422 ${body}`,
    );
    expect(ctx.crash).toHaveBeenCalledWith(
      expect.objectContaining({
        exitCode: 1,
        errorType: "fatal",
        printedMessage: `Failed to create redirect URI: 422 ${body}`,
      }),
    );
  });

  test("crashes with the body for non-422 errors", async () => {
    const body = `{"message":"Unauthorized"}`;
    mockFetch.mockResolvedValue(new Response(body, { status: 401 }));
    await expect(createRedirectURI(ctx, "key", "http://x")).rejects.toThrow(
      `Failed to create redirect URI: 401 ${body}`,
    );
  });
});

describe("createCORSOrigin", () => {
  test("returns modified: true on a successful response", async () => {
    mockFetch.mockResolvedValue(new Response(null, { status: 201 }));
    await expect(
      createCORSOrigin(ctx, "key", "http://localhost:5173"),
    ).resolves.toEqual({ modified: true });
  });

  test("returns modified: false on duplicate_cors_origin", async () => {
    mockFetch.mockResolvedValue(
      new Response(`{"code":"duplicate_cors_origin","message":"..."}`, {
        status: 409,
      }),
    );
    await expect(
      createCORSOrigin(ctx, "key", "http://localhost:5173"),
    ).resolves.toEqual({ modified: false });
    expect(ctx.crash).not.toHaveBeenCalled();
  });

  test("returns modified: false when the origin already exists", async () => {
    mockFetch.mockResolvedValue(
      new Response(`{"message":"CORS origin already exists."}`, {
        status: 409,
      }),
    );
    await expect(
      createCORSOrigin(ctx, "key", "http://localhost:5173"),
    ).resolves.toEqual({ modified: false });
    expect(ctx.crash).not.toHaveBeenCalled();
  });

  test("crashes with the body for a non-duplicate 409", async () => {
    const body = `{"message":"Some other conflict."}`;
    mockFetch.mockResolvedValue(new Response(body, { status: 409 }));
    await expect(createCORSOrigin(ctx, "key", "http://x")).rejects.toThrow(
      `Failed to create CORS origin: 409 ${body}`,
    );
    expect(ctx.crash).toHaveBeenCalledWith(
      expect.objectContaining({
        printedMessage: `Failed to create CORS origin: 409 ${body}`,
      }),
    );
  });
});
