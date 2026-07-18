/**
 * @vitest-environment custom-vitest-environment.ts
 */
import { expect, vi, test } from "vitest";
import { act, render, screen, within } from "@testing-library/react";
import { jwtEncode } from "../vendor/jwt-encode/index.js";
import React, { createContext, useCallback, useContext, useMemo } from "react";
import {
  ConvexProviderWithAuth,
  ConvexReactClient,
  useConvexAuth,
} from "./index.js";
import {
  BaseConvexClient,
  BaseConvexClientInterface,
} from "../browser/index.js";

vi.useFakeTimers();

const flushPromises = async () => {
  const timers = await vi.importActual("timers");
  await act(() => new Promise((timers as any).setImmediate));
};

// Test helpers reach into `BaseConvexClient`'s private internals; the tests
// only ever construct `ConvexReactClient` without a `baseClient` override, so
// `sync` is always a real `BaseConvexClient` under the hood.
const syncAsBaseConvexClient = (sync: BaseConvexClientInterface) => {
  if (!(sync instanceof BaseConvexClient)) {
    throw new Error("Expected `sync` to be a `BaseConvexClient`");
  }
  return sync;
};

test("setAuth legacy signature typechecks and doesn't throw", async () => {
  const convex = new ConvexReactClient("https://127.0.0.1:3001");
  // We're moving towards removing the Promise, but for backwards compatibility
  // it's still here now.
  await convex.setAuth(async () => "foo");
});

test("ConvexProviderWithAuth works", async () => {
  // This is our fake ProviderX state
  const AuthProviderXContext = createContext<{
    isLoading: boolean;
    isAuthenticated: boolean;
    getToken: (args: { ignoreCache: boolean }) => Promise<string | null>;
  }>(null as any);

  // Fake ProviderX React hook
  const useProviderXAuth = () => {
    return useContext(AuthProviderXContext);
  };

  // What our users would have to write, this is the same as in docs
  // but works in TypeScript. We should transpile this back to JS
  // and use it as a snippet in docs.
  function useAuthFromProviderX() {
    const { isLoading, isAuthenticated, getToken } = useProviderXAuth();
    const fetchAccessToken = useCallback(
      async ({ forceRefreshToken }: { forceRefreshToken: boolean }) => {
        // Here you can do whatever transformation to get the ID Token
        // or null
        // Make sure to fetch a new token when `forceRefreshToken` is true
        return await getToken({ ignoreCache: forceRefreshToken });
      },
      // If `getToken` isn't correctly memoized
      // remove it from this dependency array
      [getToken],
    );
    return useMemo(
      () => ({
        // Whether the auth provider is in a loading state
        isLoading: isLoading,
        // Whether the auth provider has the user signed in
        isAuthenticated: isAuthenticated ?? false,
        // The async function to fetch the ID token
        fetchAccessToken,
      }),
      [isLoading, isAuthenticated, fetchAccessToken],
    );
  }

  const convex = new ConvexReactClient("https://127.0.0.1:3001");

  // Our app will mirror the Convex auth state
  const App = () => {
    const { isLoading, isAuthenticated } = useConvexAuth();
    return (
      <>
        {isLoading
          ? "Loading..."
          : isAuthenticated
            ? "Authenticated"
            : "Unauthenticated"}
      </>
    );
  };

  const element = (
    <ConvexProviderWithAuth client={convex} useAuth={useAuthFromProviderX}>
      <App />
    </ConvexProviderWithAuth>
  );

  const { rerender } = render(
    <AuthProviderXContext.Provider
      value={{
        isLoading: true,
        isAuthenticated: false,
        getToken: async () => null,
      }}
    >
      {element}
    </AuthProviderXContext.Provider>,
  );
  expect(screen.getByText("Loading...")).toBeDefined();

  const token = jwtEncode({ iat: 1234500, exp: 1234500 + 30 }, "secret");

  rerender(
    <AuthProviderXContext.Provider
      value={{
        isLoading: false,
        isAuthenticated: true,
        getToken: async () => token,
      }}
    >
      {element}
    </AuthProviderXContext.Provider>,
  );
  expect(screen.getByText("Loading...")).toBeDefined();

  vi.runOnlyPendingTimers();

  await flushPromises();

  mockServerConfirmsAuth(convex, 0);

  expect(screen.getByText("Authenticated")).toBeDefined();
});

// This is no longer really possible, because
// we wait on server response before scheduling token refetch,
// and the server currently requires JWT tokens.
test("Tokens must be valid JWT", async () => {
  const client = new ConvexReactClient("https://127.0.0.1:3001");
  const consoleSpy = vi
    .spyOn(global.console, "error")
    .mockImplementation(() => {
      // Do nothing
    });

  let tokenId = 0;
  void client.setAuth(
    async () => "foo" + tokenId++, // simulate a new token on every fetch
    () => {
      // Do nothing
    },
  );

  // Wait for token
  await flushPromises();

  // Server confirms it
  mockServerConfirmsAuth(client, 0);

  // Wait for token with `forceRefreshToken: true`
  await flushPromises();

  // Server confirms it
  mockServerConfirmsAuth(client, 1);

  expect(consoleSpy).toHaveBeenCalledWith(
    "Auth token is not a valid JWT, cannot refetch the token",
  );
});

test("Tokens are used to schedule refetch", async () => {
  const client = new ConvexReactClient("https://127.0.0.1:3001");
  const tokenLifetimeSeconds = 60;
  let tokenId = 0;
  const tokenFetcher = vi.fn(async () =>
    jwtEncode(
      { iat: 1234500, exp: 1234500 + tokenLifetimeSeconds },
      "secret" + tokenId++, // simulate a new token on every fetch
    ),
  );
  void client.setAuth(tokenFetcher, () => {
    // Do nothing
  });

  // Wait for token
  await flushPromises();

  // Server confirms it
  mockServerConfirmsAuth(client, 0);

  // Wait for token with `forceRefreshToken: true`
  await flushPromises();

  // Confirm refetched token
  mockServerConfirmsAuth(client, 1);

  expect(tokenFetcher).toHaveBeenCalledTimes(2);

  // Check that next refetch happens in time
  vi.advanceTimersByTime(tokenLifetimeSeconds * 1000);
  expect(tokenFetcher).toHaveBeenCalledTimes(3);
});

function mockServerConfirmsAuth(
  client: ConvexReactClient,
  oldIdentityVersion: number,
  clientClockSkew?: number,
) {
  act(() => {
    const querySetVersion = syncAsBaseConvexClient(client.sync)[
      "remoteQuerySet"
    ]["version"];
    syncAsBaseConvexClient(client.sync)["authenticationManager"].onTransition({
      type: "Transition",
      startVersion: {
        ...querySetVersion,
        identity: oldIdentityVersion,
      },
      endVersion: {
        ...querySetVersion,
        identity: oldIdentityVersion + 1,
      },
      modifications: [],
      ...(clientClockSkew !== undefined ? { clientClockSkew } : {}),
    });
  });
}

test("isRefreshing reflects reauthentication in React tree", async () => {
  const AuthProviderXContext = createContext<{
    isLoading: boolean;
    isAuthenticated: boolean;
    getToken: (args: { ignoreCache: boolean }) => Promise<string | null>;
  }>(null as any);

  const useProviderXAuth = () => useContext(AuthProviderXContext);

  function useAuthFromProviderX() {
    const { isLoading, isAuthenticated, getToken } = useProviderXAuth();
    const fetchAccessToken = useCallback(
      async ({ forceRefreshToken }: { forceRefreshToken: boolean }) => {
        return await getToken({ ignoreCache: forceRefreshToken });
      },
      [getToken],
    );
    return useMemo(
      () => ({
        isLoading,
        isAuthenticated: isAuthenticated ?? false,
        fetchAccessToken,
      }),
      [isLoading, isAuthenticated, fetchAccessToken],
    );
  }

  const convex = new ConvexReactClient("https://127.0.0.1:3001");

  const App = () => {
    const { isLoading, isAuthenticated, isRefreshing } = useConvexAuth();
    return (
      <>
        {isLoading
          ? "Loading..."
          : isAuthenticated
            ? "Authenticated"
            : "Unauthenticated"}
        {isRefreshing && " (Refreshing)"}
      </>
    );
  };

  const tokenLifetimeSeconds = 60;
  let tokenId = 0;
  const getToken = vi.fn(async () =>
    jwtEncode(
      { iat: 1234500, exp: 1234500 + tokenLifetimeSeconds },
      "secret" + tokenId++,
    ),
  );

  const element = (
    <ConvexProviderWithAuth client={convex} useAuth={useAuthFromProviderX}>
      <App />
    </ConvexProviderWithAuth>
  );

  const { container } = render(
    <AuthProviderXContext.Provider
      value={{
        isLoading: false,
        isAuthenticated: true,
        getToken,
      }}
    >
      {element}
    </AuthProviderXContext.Provider>,
  );
  const view = within(container);

  // Get through initial auth. Background token rotation is silent, so no
  // Refreshing flash should appear during this sequence.
  await flushPromises();
  mockServerConfirmsAuth(convex, 0);
  await flushPromises();
  mockServerConfirmsAuth(convex, 1);

  expect(view.getByText("Authenticated")).toBeDefined();
  expect(view.queryByText(/Refreshing/)).toBeNull();

  // Advancing the scheduled refresh timer must remain silent in the UI.
  act(() => {
    vi.advanceTimersByTime(tokenLifetimeSeconds * 1000);
  });
  expect(view.queryByText(/Refreshing/)).toBeNull();

  await flushPromises();
  mockServerConfirmsAuth(convex, 2);
  expect(view.queryByText(/Refreshing/)).toBeNull();

  // Server rejects a token mid-session, triggering reauthentication.
  act(() => {
    syncAsBaseConvexClient(convex.sync)["authenticationManager"].onAuthError({
      type: "AuthError",
      error: "token expired",
      baseVersion: 2,
      authUpdateAttempted: false,
    });
  });

  // Socket is paused while we fetch a new token, but the user is still
  // locally authenticated.
  expect(view.getByText(/Refreshing/)).toBeDefined();
  expect(view.getByText(/Authenticated/)).toBeDefined();

  await flushPromises();
  mockServerConfirmsAuth(convex, 3);

  expect(view.queryByText(/Refreshing/)).toBeNull();
  expect(view.getByText("Authenticated")).toBeDefined();

  await convex.close();
});

test("isRefreshing becomes false when reauth fetch fails", async () => {
  const client = new ConvexReactClient("https://127.0.0.1:3001");
  const tokenLifetimeSeconds = 60;
  let tokenId = 0;

  // First two calls (initial cached + initial fresh) succeed; the reauth
  // attempt returns null to simulate the token fetcher failing.
  const tokenFetcher = vi.fn(async () => {
    if (tokenId++ < 2) {
      return jwtEncode(
        { iat: 1234500, exp: 1234500 + tokenLifetimeSeconds },
        "secret" + tokenId,
      );
    }
    return null;
  });

  const onRefreshChange = vi.fn();
  void client.setAuth(tokenFetcher, () => {}, onRefreshChange);

  await flushPromises();
  mockServerConfirmsAuth(client, 0);
  await flushPromises();
  mockServerConfirmsAuth(client, 1);

  onRefreshChange.mockClear();

  // Server rejects the token; tryToReauthenticate runs but the fetcher
  // returns null on its retry.
  syncAsBaseConvexClient(client.sync)["authenticationManager"].onAuthError({
    type: "AuthError",
    error: "token expired",
    baseVersion: 1,
    authUpdateAttempted: false,
  });
  await flushPromises();

  expect(onRefreshChange).toHaveBeenCalledWith(true);
  expect(onRefreshChange).toHaveBeenCalledWith(false);

  await client.close();
});

test("isRefreshing is not set during initial token fetch (no cached token)", async () => {
  const client = new ConvexReactClient("https://127.0.0.1:3001");
  const tokenLifetimeSeconds = 60;
  let tokenId = 0;

  // Return null on first call (no cached token), valid tokens afterwards
  const tokenFetcher = vi.fn(
    async ({ forceRefreshToken }: { forceRefreshToken: boolean }) => {
      if (!forceRefreshToken) {
        return null; // No cached token available
      }
      return jwtEncode(
        { iat: 1234500, exp: 1234500 + tokenLifetimeSeconds },
        "secret" + tokenId++,
      );
    },
  );

  const onRefreshChange = vi.fn();
  void client.setAuth(tokenFetcher, () => {}, onRefreshChange);

  // Wait for initial (cached) fetch - returns null, enters initialRefetch
  await flushPromises();

  // Wait for force-refresh fetch in initialRefetch state
  await flushPromises();

  // onRefreshChange should NOT have been called during the initialRefetch path,
  // because "refreshing" implies re-acquiring a token that already existed.
  expect(onRefreshChange).not.toHaveBeenCalledWith(true);

  // Server confirms the fresh token
  mockServerConfirmsAuth(client, 0);

  await client.close();
});

test("isFromOutdatedConfig during reauth resets isRefreshing via resetAuthState", async () => {
  const client = new ConvexReactClient("https://127.0.0.1:3001");
  const tokenLifetimeSeconds = 60;
  let tokenId = 0;
  const tokenFetcher = vi.fn(async () =>
    jwtEncode(
      { iat: 1234500, exp: 1234500 + tokenLifetimeSeconds },
      "secret" + tokenId++,
    ),
  );

  const onRefreshChange = vi.fn();
  void client.setAuth(tokenFetcher, () => {}, onRefreshChange);

  await flushPromises();
  mockServerConfirmsAuth(client, 0);
  await flushPromises();
  mockServerConfirmsAuth(client, 1);

  onRefreshChange.mockClear();

  // Server rejects the token, kicking off tryToReauthenticate.
  syncAsBaseConvexClient(client.sync)["authenticationManager"].onAuthError({
    type: "AuthError",
    error: "token expired",
    baseVersion: 1,
    authUpdateAttempted: false,
  });

  expect(onRefreshChange).toHaveBeenCalledWith(true);

  // Call setAuth again while the reauth fetch is in flight. This bumps
  // configVersion via resetAuthState, which also notifies false for the
  // old config before transitioning to noAuth.
  const onRefreshChange2 = vi.fn();
  void client.setAuth(tokenFetcher, () => {}, onRefreshChange2);

  expect(onRefreshChange).toHaveBeenCalledWith(false);

  await flushPromises();

  await client.close();
});

test("isRefreshing is true during reauthentication after auth error", async () => {
  const client = new ConvexReactClient("https://127.0.0.1:3001");
  const tokenLifetimeSeconds = 60;
  let tokenId = 0;
  const tokenFetcher = vi.fn(async () =>
    jwtEncode(
      { iat: 1234500, exp: 1234500 + tokenLifetimeSeconds },
      "secret" + tokenId++,
    ),
  );

  const onRefreshChange = vi.fn();
  void client.setAuth(tokenFetcher, () => {}, onRefreshChange);

  // Wait for tokens and confirm
  await flushPromises();
  mockServerConfirmsAuth(client, 0);
  await flushPromises();
  mockServerConfirmsAuth(client, 1);

  // Clear mock
  onRefreshChange.mockClear();

  // Simulate auth error from server
  act(() => {
    syncAsBaseConvexClient(client.sync)["authenticationManager"].onAuthError({
      type: "AuthError",
      error: "token expired",
      baseVersion: 1,
      authUpdateAttempted: false,
    });
  });

  // Should have notified refreshing started
  expect(onRefreshChange).toHaveBeenCalledWith(true);

  // Wait for reauth token fetch
  await flushPromises();

  // Server confirms new token
  mockServerConfirmsAuth(client, 2);

  // Should have notified refreshing ended
  expect(onRefreshChange).toHaveBeenCalledWith(false);

  await client.close();
});

test("stop() during reauth notifies isRefreshing false", async () => {
  const client = new ConvexReactClient("https://127.0.0.1:3001");
  const tokenLifetimeSeconds = 60;
  let tokenId = 0;
  const tokenFetcher = vi.fn(async () =>
    jwtEncode(
      { iat: 1234500, exp: 1234500 + tokenLifetimeSeconds },
      "secret" + tokenId++,
    ),
  );

  const onRefreshChange = vi.fn();
  void client.setAuth(tokenFetcher, () => {}, onRefreshChange);

  await flushPromises();
  mockServerConfirmsAuth(client, 0);
  await flushPromises();
  mockServerConfirmsAuth(client, 1);

  onRefreshChange.mockClear();

  // Server rejects the token so isRefreshing becomes true.
  syncAsBaseConvexClient(client.sync)["authenticationManager"].onAuthError({
    type: "AuthError",
    error: "token expired",
    baseVersion: 1,
    authUpdateAttempted: false,
  });
  expect(onRefreshChange).toHaveBeenCalledWith(true);

  // Closing the client calls stop() on the auth manager, which calls
  // resetAuthState() and should notify false.
  await client.close();

  expect(onRefreshChange).toHaveBeenCalledWith(false);
});

// --- initialAuthTokenReuse tests ---
// When enabled, the cached token is reused after server confirmation
// (no immediate fresh-token fetch), and the refetch is scheduled using
// the server's clientClockSkew to estimate remaining lifetime.
// The server computes clientClockSkew = clientTs - serverReceiveTs:
// negative means client behind, positive means ahead. Connect latency
// makes the skew more negative (conservative).

test("initialAuthTokenReuse: sends only one Authenticate", async () => {
  const client = new ConvexReactClient("https://127.0.0.1:3001", {
    initialAuthTokenReuse: true,
  });
  const tokenLifetimeSeconds = 60;
  let tokenId = 0;
  const tokenFetcher = vi.fn(async () =>
    jwtEncode(
      { iat: 1234500, exp: 1234500 + tokenLifetimeSeconds },
      "secret" + tokenId++,
    ),
  );

  const sendMessageSpy = vi.spyOn(
    syncAsBaseConvexClient(client.sync)["webSocketManager"],
    "sendMessage",
  );

  const onAuthChange = vi.fn();
  void client.setAuth(tokenFetcher, onAuthChange);

  await flushPromises();
  mockServerConfirmsAuth(client, 0);
  await flushPromises();

  expect(onAuthChange).toHaveBeenCalledWith(true);

  const authenticateMessages = sendMessageSpy.mock.calls.filter(
    ([msg]) => msg.type === "Authenticate",
  );
  expect(authenticateMessages).toHaveLength(1);

  await client.close();
});

test("initialAuthTokenReuse: clock skew adjusts schedule for partially-expired token", async () => {
  const client = new ConvexReactClient("https://127.0.0.1:3001", {
    initialAuthTokenReuse: true,
  });
  const defaultLeewaySeconds = 10;
  const tokenLifetimeSeconds = 60;
  const tokenAgeOnServer = 30;
  const clientClockSkewMs = 0;
  const clientNow = Date.now() / 1000;
  const serverNow = clientNow;
  const tokenFetcher = vi.fn(async () =>
    jwtEncode(
      {
        iat: serverNow - tokenAgeOnServer,
        exp: serverNow - tokenAgeOnServer + tokenLifetimeSeconds,
      },
      "secret",
    ),
  );
  void client.setAuth(tokenFetcher, () => {});

  await flushPromises();
  mockServerConfirmsAuth(client, 0, clientClockSkewMs);

  expect(tokenFetcher).toHaveBeenCalledTimes(1);

  const expectedDelay =
    (tokenLifetimeSeconds - tokenAgeOnServer - defaultLeewaySeconds) * 1000;

  vi.advanceTimersByTime(expectedDelay - 1);
  expect(tokenFetcher).toHaveBeenCalledTimes(1);

  vi.advanceTimersByTime(1);
  expect(tokenFetcher).toHaveBeenCalledTimes(2);
});

test("initialAuthTokenReuse: clock skew triggers immediate refetch for nearly-expired token", async () => {
  const client = new ConvexReactClient("https://127.0.0.1:3001", {
    initialAuthTokenReuse: true,
  });
  const tokenLifetimeSeconds = 60;
  const clientClockSkewMs = -50_000;
  const clientNow = Date.now() / 1000;
  const serverNow = clientNow - clientClockSkewMs / 1000;
  const tokenFetcher = vi.fn(async () =>
    jwtEncode(
      {
        iat: serverNow - 55,
        exp: serverNow - 55 + tokenLifetimeSeconds,
      },
      "secret",
    ),
  );
  void client.setAuth(tokenFetcher, () => {});

  await flushPromises();
  mockServerConfirmsAuth(client, 0, clientClockSkewMs);

  expect(tokenFetcher).toHaveBeenCalledTimes(1);

  vi.advanceTimersByTime(1);
  expect(tokenFetcher).toHaveBeenCalledTimes(2);
});

test("initialAuthTokenReuse: clock skew corrects for client clock behind server", async () => {
  const client = new ConvexReactClient("https://127.0.0.1:3001", {
    initialAuthTokenReuse: true,
  });
  const defaultLeewaySeconds = 10;
  const tokenLifetimeSeconds = 60;
  const tokenAgeOnServer = 30;
  const clientClockSkewMs = -20_000;
  const clientNow = Date.now() / 1000;
  const serverNow = clientNow - clientClockSkewMs / 1000;
  const tokenFetcher = vi.fn(async () =>
    jwtEncode(
      {
        iat: serverNow - tokenAgeOnServer,
        exp: serverNow - tokenAgeOnServer + tokenLifetimeSeconds,
      },
      "secret",
    ),
  );
  void client.setAuth(tokenFetcher, () => {});

  await flushPromises();
  mockServerConfirmsAuth(client, 0, clientClockSkewMs);

  expect(tokenFetcher).toHaveBeenCalledTimes(1);

  const expectedDelay =
    (tokenLifetimeSeconds - tokenAgeOnServer - defaultLeewaySeconds) * 1000;

  vi.advanceTimersByTime(expectedDelay - 1);
  expect(tokenFetcher).toHaveBeenCalledTimes(1);

  vi.advanceTimersByTime(1);
  expect(tokenFetcher).toHaveBeenCalledTimes(2);
});
