import { test, expect, describe, vi } from "vitest";
import ws from "ws";

import { ConvexReactClient } from "./client.js";
import { anyApi } from "../server/api.js";
import { BaseConvexClient } from "../browser/index.js";
import { BaseConvexClientInterface } from "../browser/sync/client.js";

const address = "https://127.0.0.1:3001";

describe("Creating a ConvexReactClient with a custom base client", () => {
  describe("with a `BaseConvexClient` subclass", () => {
    // A minimal subclass of `BaseConvexClient` used to prove that a
    // caller-provided `BaseConvexClient` (of any subclass) can be plugged into
    // a `ConvexReactClient` via the `client` option.
    class MinimalBaseConvexClient extends BaseConvexClient {}

    const testBaseConvexClient = () =>
      new MinimalBaseConvexClient(address, () => {}, {
        webSocketConstructor: ws as unknown as typeof WebSocket,
      });

    test("uses the provided client as its `sync` client", () => {
      const baseClient = testBaseConvexClient();
      const client = new ConvexReactClient(address, { baseClient });
      expect(client.sync).toBe(baseClient);
    });

    test("applies setAdminAuth called before the client is lazily instantiated", () => {
      const baseClient = testBaseConvexClient();
      const setAdminAuthSpy = vi.spyOn(baseClient, "setAdminAuth");
      const client = new ConvexReactClient(address, { baseClient });
      client.setAdminAuth("admin-token");
      expect(setAdminAuthSpy).not.toHaveBeenCalled();

      // Accessing `sync` lazily instantiates the client, applying admin auth.
      expect(client.sync).toBe(baseClient);
      expect(setAdminAuthSpy).toHaveBeenCalledWith("admin-token", undefined);
    });

    test("queries and mutations work through the provided client", async () => {
      const baseClient = testBaseConvexClient();
      const client = new ConvexReactClient(address, { baseClient });

      void client.mutation(
        anyApi.myMutation.default,
        {},
        {
          optimisticUpdate: (localStore) => {
            localStore.setQuery(anyApi.myQuery.default, {}, "queryResult");
          },
        },
      );

      const queryResult = client.query(anyApi.myQuery.default, {});
      expect(await queryResult).toStrictEqual("queryResult");
    });
  });

  describe("with a from-scratch BaseConvexClientInterface implementation", () => {
    // A from-scratch (non-subclass) implementation of `BaseConvexClientInterface`.
    // Unlike `MinimalBaseConvexClient` above, this does not extend
    // `BaseConvexClient`, so TypeScript forces every public member to be
    // declared here explicitly — if `BaseConvexClientInterface` ever gains a member,
    // this class fails to compile until a matching forwarding method is added.
    class ComposedBaseConvexClient implements BaseConvexClientInterface {
      private inner: BaseConvexClient;

      constructor(...args: ConstructorParameters<typeof BaseConvexClient>) {
        this.inner = new BaseConvexClient(...args);
      }

      addOnTransitionHandler(
        ...args: Parameters<BaseConvexClient["addOnTransitionHandler"]>
      ) {
        return this.inner.addOnTransitionHandler(...args);
      }
      setAuth(...args: Parameters<BaseConvexClient["setAuth"]>) {
        return this.inner.setAuth(...args);
      }
      setAdminAuth(...args: Parameters<BaseConvexClient["setAdminAuth"]>) {
        return this.inner.setAdminAuth(...args);
      }
      clearAuth() {
        return this.inner.clearAuth();
      }
      subscribe(...args: Parameters<BaseConvexClient["subscribe"]>) {
        return this.inner.subscribe(...args);
      }
      localQueryResult(
        ...args: Parameters<BaseConvexClient["localQueryResult"]>
      ) {
        return this.inner.localQueryResult(...args);
      }
      localQueryResultByToken(
        ...args: Parameters<BaseConvexClient["localQueryResultByToken"]>
      ) {
        return this.inner.localQueryResultByToken(...args);
      }
      hasLocalQueryResultByToken(
        ...args: Parameters<BaseConvexClient["hasLocalQueryResultByToken"]>
      ) {
        return this.inner.hasLocalQueryResultByToken(...args);
      }
      localQueryLogs(...args: Parameters<BaseConvexClient["localQueryLogs"]>) {
        return this.inner.localQueryLogs(...args);
      }
      queryJournal(...args: Parameters<BaseConvexClient["queryJournal"]>) {
        return this.inner.queryJournal(...args);
      }
      connectionState() {
        return this.inner.connectionState();
      }
      subscribeToConnectionState(
        ...args: Parameters<BaseConvexClient["subscribeToConnectionState"]>
      ) {
        return this.inner.subscribeToConnectionState(...args);
      }
      mutation(...args: Parameters<BaseConvexClient["mutation"]>) {
        return this.inner.mutation(...args);
      }
      action(...args: Parameters<BaseConvexClient["action"]>) {
        return this.inner.action(...args);
      }
      close() {
        return this.inner.close();
      }
      get url() {
        return this.inner.url;
      }
    }

    const testBaseConvexClient = () =>
      new ComposedBaseConvexClient(address, () => {}, {
        webSocketConstructor: ws as unknown as typeof WebSocket,
      });

    test("uses the provided client as its `sync` client", () => {
      const baseClient = testBaseConvexClient();
      const client = new ConvexReactClient(address, { baseClient });
      expect(client.sync).toBe(baseClient);
    });

    test("applies setAdminAuth called before the client is lazily instantiated", () => {
      const baseClient = testBaseConvexClient();
      const setAdminAuthSpy = vi.spyOn(baseClient, "setAdminAuth");
      const client = new ConvexReactClient(address, { baseClient });
      client.setAdminAuth("admin-token");
      expect(setAdminAuthSpy).not.toHaveBeenCalled();

      // Accessing `sync` lazily instantiates the client, applying admin auth.
      expect(client.sync).toBe(baseClient);
      expect(setAdminAuthSpy).toHaveBeenCalledWith("admin-token", undefined);
    });

    test("queries and mutations work through the provided client", async () => {
      const baseClient = testBaseConvexClient();
      const client = new ConvexReactClient(address, { baseClient });

      void client.mutation(
        anyApi.myMutation.default,
        {},
        {
          optimisticUpdate: (localStore) => {
            localStore.setQuery(anyApi.myQuery.default, {}, "queryResult");
          },
        },
      );

      const queryResult = client.query(anyApi.myQuery.default, {});
      expect(await queryResult).toStrictEqual("queryResult");
    });
  });
});
