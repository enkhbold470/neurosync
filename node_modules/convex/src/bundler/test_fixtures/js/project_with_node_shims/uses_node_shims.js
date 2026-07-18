import { AsyncLocalStorage, AsyncResource } from "node:async_hooks";

export const als = new AsyncLocalStorage();
export const resource = new AsyncResource("test");
