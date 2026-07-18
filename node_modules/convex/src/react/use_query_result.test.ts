/**
 * @vitest-environment custom-vitest-environment.ts
 */

/* eslint-disable @typescript-eslint/no-unused-vars */
import { test, describe, expectTypeOf } from "vitest";
import { anyApi } from "../server/api.js";

import type { ApiFromModules, QueryBuilder } from "../server/index.js";
import {
  useQuery_experimental as useQueryReal,
  type UseQueryResult,
} from "./client.js";

const useQuery_experimental = (() => {}) as unknown as typeof useQueryReal;
const query: QueryBuilder<any, "public"> = (() => {}) as any;

const module = {
  noArgs: query(() => "result"),
  args: query((_ctx, { _arg }: { _arg: string }) => "result"),
};
type API = ApiFromModules<{ module: typeof module }>;
const api = anyApi as unknown as API;

describe("useQuery_experimental result types", () => {
  test("supports object-form result usage", () => {
    useQuery_experimental({
      query: api.module.args,
      args: { _arg: "asdf" },
    });

    const throwingResult = useQuery_experimental({
      query: api.module.args,
      args: { _arg: "asdf" },
      throwOnError: true,
    });
    expectTypeOf(throwingResult).toEqualTypeOf<UseQueryResult<string, true>>();

    const _arg: string | undefined = undefined;
    const conditionalResult = useQuery_experimental({
      query: api.module.args,
      args: _arg ? { _arg } : "skip",
    });
    expectTypeOf(conditionalResult).toEqualTypeOf<
      UseQueryResult<string, false>
    >();
  });

  test("throwOnError:true omits error from result", () => {
    // Never executed; exists only for type checking.
    () => {
      const throwingResult = useQuery_experimental({
        query: api.module.args,
        args: { _arg: "asdf" },
        throwOnError: true,
      });
      expectTypeOf<(typeof throwingResult)["status"]>().toEqualTypeOf<
        "pending" | "success"
      >();
    };
  });

  test("throwOnError ommitted includes error in result", () => {
    // Never executed; exists only for type checking.
    () => {
      const throwingResult = useQuery_experimental({
        query: api.module.args,
        args: { _arg: "asdf" },
      });
      expectTypeOf<(typeof throwingResult)["status"]>().toEqualTypeOf<
        "pending" | "success" | "error"
      >();
    };
  });
});
