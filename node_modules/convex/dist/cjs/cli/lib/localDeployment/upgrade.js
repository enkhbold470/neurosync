"use strict";
var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
  // If the importer is in node compatibility mode or this is not an ESM
  // file that has been converted to a CommonJS file using a Babel-
  // compatible transform (i.e. "__esModule" has not been set), then set
  // "default" to the CommonJS "module.exports" for node compatibility.
  isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
  mod
));
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);
var upgrade_exports = {};
__export(upgrade_exports, {
  handlePotentialUpgradeAndStart: () => handlePotentialUpgradeAndStart
});
module.exports = __toCommonJS(upgrade_exports);
var import_path = __toESM(require("path"), 1);
var import_log = require("../../../bundler/log.js");
var import_run = require("../run.js");
var import_filePaths = require("./filePaths.js");
var import_run2 = require("./run.js");
var import_convexExport = require("../convexExport.js");
var import_utils = require("../utils/utils.js");
var import_convexImport = require("../convexImport.js");
var import_prompts = require("../utils/prompts.js");
var import_fsUtils = require("../fsUtils.js");
var import_errors = require("./errors.js");
var import_download = require("./download.js");
var import_secrets = require("./secrets.js");
async function handlePotentialUpgradeAndStart(ctx, args) {
  const { adminKey, instanceSecret } = args.existingCredentials === null || args.existingCredentials.instanceSecret === import_secrets.LEGACY_LOCAL_BACKEND_INSTANCE_SECRET ? (
    // Using `generateLocalDevSecretsFromLatestBinary` instead of `generateLocalDevSecrets`
    // here, because `newBinaryPath` can be a binary that doesn’t support
    // the `keygen admin-key` subcommand (when the --local-backend-version flag is provided to the CLI)
    //
    // In most cases (the user is not using the flag), we have already downloaded the latest binary
    // shortly before in handleLocalDeployment/handleAnonymousDeployment, so this doesn’t cause an
    // extra download (even if the user chooses later not to upgrade their deployment)
    await (0, import_secrets.generateLocalDevSecretsWithLatestBinary)(ctx, {
      deploymentName: args.deploymentName
    })
  ) : args.existingCredentials;
  const newConfig = {
    ports: args.ports,
    backendVersion: args.newVersion,
    adminKey,
    instanceSecret,
    cloudProjectId: args.cloudProjectId
  };
  if (args.oldVersion === null || args.oldVersion === args.newVersion) {
    (0, import_filePaths.saveDeploymentConfig)(
      ctx,
      args.deploymentKind,
      args.deploymentName,
      newConfig
    );
    const { cleanupHandle: cleanupHandle2 } = await (0, import_run2.runLocalBackend)(ctx, {
      binaryPath: args.newBinaryPath,
      deploymentKind: args.deploymentKind,
      deploymentName: args.deploymentName,
      ports: args.ports,
      instanceSecret,
      isLatestVersion: true
    });
    return { cleanupHandle: cleanupHandle2, adminKey };
  }
  (0, import_log.logVerbose)(
    `Considering upgrade from ${args.oldVersion} to ${args.newVersion}`
  );
  const confirmed = args.forceUpgrade || !process.stdin.isTTY || await (0, import_prompts.promptYesNo)(ctx, {
    message: `This deployment is using an older version of the Convex backend. Upgrade now?`,
    default: true
  });
  if (!confirmed) {
    const { binaryPath: oldBinaryPath } = await (0, import_download.ensureBackendBinaryDownloaded)(
      ctx,
      {
        kind: "version",
        version: args.oldVersion
      }
    );
    (0, import_filePaths.saveDeploymentConfig)(ctx, args.deploymentKind, args.deploymentName, {
      ...newConfig,
      backendVersion: args.oldVersion
    });
    const { cleanupHandle: cleanupHandle2 } = await (0, import_run2.runLocalBackend)(ctx, {
      binaryPath: oldBinaryPath,
      ports: args.ports,
      deploymentKind: args.deploymentKind,
      deploymentName: args.deploymentName,
      instanceSecret,
      isLatestVersion: false
    });
    return { cleanupHandle: cleanupHandle2, adminKey };
  }
  const choice = args.forceUpgrade || !process.stdin.isTTY ? "transfer" : await (0, import_prompts.promptOptions)(ctx, {
    message: "Transfer data from existing deployment?",
    default: "transfer",
    choices: [
      { name: "transfer data", value: "transfer" },
      { name: "start fresh", value: "reset" }
    ]
  });
  const deploymentStatePath = (0, import_filePaths.deploymentStateDir)(
    ctx,
    args.deploymentKind,
    args.deploymentName
  );
  if (choice === "reset") {
    (0, import_fsUtils.recursivelyDelete)(ctx, deploymentStatePath, { force: true });
    (0, import_filePaths.saveDeploymentConfig)(
      ctx,
      args.deploymentKind,
      args.deploymentName,
      newConfig
    );
    const { cleanupHandle: cleanupHandle2 } = await (0, import_run2.runLocalBackend)(ctx, {
      binaryPath: args.newBinaryPath,
      deploymentKind: args.deploymentKind,
      deploymentName: args.deploymentName,
      ports: args.ports,
      instanceSecret,
      isLatestVersion: true
    });
    return { cleanupHandle: cleanupHandle2, adminKey };
  }
  const { cleanupHandle } = await handleUpgrade(ctx, {
    deploymentKind: args.deploymentKind,
    deploymentName: args.deploymentName,
    oldVersion: args.oldVersion,
    newBinaryPath: args.newBinaryPath,
    newVersion: args.newVersion,
    ports: args.ports,
    adminKey,
    instanceSecret,
    cloudProjectId: args.cloudProjectId
  });
  return { cleanupHandle, adminKey };
}
async function handleUpgrade(ctx, args) {
  const { adminKey } = args;
  const { binaryPath: oldBinaryPath } = await (0, import_download.ensureBackendBinaryDownloaded)(
    ctx,
    {
      kind: "version",
      version: args.oldVersion
    }
  );
  (0, import_log.logVerbose)("Running backend on old version");
  const { cleanupHandle: oldCleanupHandle } = await (0, import_run2.runLocalBackend)(ctx, {
    binaryPath: oldBinaryPath,
    ports: args.ports,
    deploymentKind: args.deploymentKind,
    deploymentName: args.deploymentName,
    instanceSecret: args.instanceSecret,
    isLatestVersion: false
  });
  (0, import_log.logVerbose)("Downloading env vars");
  const deploymentUrl = (0, import_run2.localDeploymentUrl)(args.ports.cloud);
  const envs = await (0, import_run.runSystemQuery)(ctx, {
    deploymentUrl,
    adminKey,
    functionName: "_system/cli/queryEnvironmentVariables",
    componentPath: void 0,
    args: {}
  });
  (0, import_log.logVerbose)("Doing a snapshot export");
  const exportPath = import_path.default.join(
    (0, import_filePaths.deploymentStateDir)(ctx, args.deploymentKind, args.deploymentName),
    "export.zip"
  );
  if (ctx.fs.exists(exportPath)) {
    ctx.fs.unlink(exportPath);
  }
  const snapshotExportState = await (0, import_convexExport.startSnapshotExport)(ctx, {
    deploymentUrl,
    adminKey,
    includeStorage: true,
    inputPath: exportPath
  });
  if (snapshotExportState.state !== "completed") {
    return ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: "Failed to export snapshot"
    });
  }
  await (0, import_convexExport.downloadSnapshotExport)(ctx, {
    snapshotExportTs: snapshotExportState.start_ts,
    inputPath: exportPath,
    adminKey,
    deploymentUrl
  });
  (0, import_log.logVerbose)("Stopping the backend on the old version");
  const oldCleanupFunc = ctx.removeCleanup(oldCleanupHandle);
  if (oldCleanupFunc) {
    await oldCleanupFunc(0);
  }
  await (0, import_run2.ensureBackendStopped)(ctx, {
    ports: args.ports,
    maxTimeSecs: 5,
    deploymentName: args.deploymentName,
    allowOtherDeployments: false
  });
  (0, import_log.logVerbose)("Running backend on new version");
  const { cleanupHandle } = await (0, import_run2.runLocalBackend)(ctx, {
    binaryPath: args.newBinaryPath,
    ports: args.ports,
    deploymentKind: args.deploymentKind,
    deploymentName: args.deploymentName,
    instanceSecret: args.instanceSecret,
    isLatestVersion: true
  });
  (0, import_log.logVerbose)("Importing the env vars");
  if (envs.length > 0) {
    const fetch = (0, import_utils.deploymentFetch)(ctx, {
      deploymentUrl,
      adminKey
    });
    try {
      await fetch("/api/update_environment_variables", {
        body: JSON.stringify({ changes: envs }),
        method: "POST"
      });
    } catch (e) {
      return await (0, import_utils.logAndHandleFetchError)(ctx, e);
    }
  }
  (0, import_log.logVerbose)("Doing a snapshot import");
  const importId = await (0, import_convexImport.uploadForImport)(ctx, {
    deploymentUrl,
    adminKey,
    filePath: exportPath,
    importArgs: { format: "zip", mode: "replace", tableName: void 0 },
    onImportFailed: async (e) => {
      (0, import_log.logFailure)(`Failed to import snapshot: ${e}`);
    }
  });
  (0, import_log.logVerbose)(`Snapshot import started`);
  let status = await (0, import_convexImport.waitForStableImportState)(ctx, {
    importId,
    deploymentUrl,
    adminKey,
    onProgress: () => {
      return 0;
    }
  });
  if (status.state !== "waiting_for_confirmation") {
    const message = "Error while transferring data: Failed to upload snapshot";
    return ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: message,
      errForSentry: new import_errors.LocalDeploymentError(message)
    });
  }
  await (0, import_convexImport.confirmImport)(ctx, {
    importId,
    adminKey,
    deploymentUrl,
    onError: async (e) => {
      (0, import_log.logFailure)(`Failed to confirm import: ${e}`);
    }
  });
  (0, import_log.logVerbose)(`Snapshot import confirmed`);
  status = await (0, import_convexImport.waitForStableImportState)(ctx, {
    importId,
    deploymentUrl,
    adminKey,
    onProgress: () => {
      return 0;
    }
  });
  (0, import_log.logVerbose)(`Snapshot import status: ${status.state}`);
  if (status.state !== "completed") {
    const message = "Error while transferring data: Failed to import snapshot";
    return ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: message,
      errForSentry: new import_errors.LocalDeploymentError(message)
    });
  }
  (0, import_log.logFinishedStep)("Successfully upgraded to a new backend version");
  (0, import_filePaths.saveDeploymentConfig)(ctx, args.deploymentKind, args.deploymentName, {
    ports: args.ports,
    backendVersion: args.newVersion,
    adminKey,
    instanceSecret: args.instanceSecret,
    cloudProjectId: args.cloudProjectId
  });
  return { cleanupHandle };
}
//# sourceMappingURL=upgrade.js.map
