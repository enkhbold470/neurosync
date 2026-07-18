/**
 * @vitest-environment custom-vitest-environment.ts
 */

/* eslint-disable @typescript-eslint/no-unused-vars */
import { test, describe } from "vitest";
import { anyApi } from "../server/api.js";

import type { ApiFromModules, QueryBuilder } from "../server/index.js";
import { useQuery_experimental as useQuery_experimentalReal } from "./client.js";

const useQuery_experimental =
  (() => {}) as unknown as typeof useQuery_experimentalReal;
const query: QueryBuilder<any, "public"> = (() => {}) as any;

const module = {
  noArgs: query(() => "result"),
  args: query((_ctx, { _arg }: { _arg: string }) => "result"),
};
type API = ApiFromModules<{ module: typeof module }>;
const api = anyApi as unknown as API;

describe("useQuery object options", () => {
  test("supports object options and skip sentinel", () => {
    useQuery_experimental({
      query: api.module.noArgs,
      args: {},
    });

    useQuery_experimental({
      query: api.module.args,
      args: { _arg: "asdf" },
    });

    const _arg: string | undefined = undefined;
    useQuery_experimental({
      query: api.module.args,
      args: _arg ? { _arg } : "skip",
    });

    useQuery_experimental({
      query: api.module.args,
      args: { _arg: "asdf" },
    });

    useQuery_experimental({
      query: api.module.noArgs,
      args: "skip",
    });
  });
});
