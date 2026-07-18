"use strict";
import path from "path";
import {
  logFailure,
  logFinishedStep,
  logVerbose
} from "../../../bundler/log.js";
import { runSystemQuery } from "../run.js";
import {
  deploymentStateDir,
  saveDeploymentConfig
} from "./filePaths.js";
import {
  ensureBackendStopped,
  localDeploymentUrl,
  runLocalBackend
} from "./run.js";
import {
  downloadSnapshotExport,
  startSnapshotExport
} from "../convexExport.js";
import { deploymentFetch, logAndHandleFetchError } from "../utils/utils.js";
import {
  confirmImport,
  uploadForImport,
  waitForStableImportState
} from "../convexImport.js";
import { promptOptions, promptYesNo } from "../utils/prompts.js";
import { recursivelyDelete } from "../fsUtils.js";
import { LocalDeploymentError } from "./errors.js";
import { ensureBackendBinaryDownloaded } from "./download.js";
import {
  generateLocalDevSecretsWithLatestBinary,
  LEGACY_LOCAL_BACKEND_INSTANCE_SECRET
} from "./secrets.js";
export async function handlePotentialUpgradeAndStart(ctx, args) {
  const { adminKey, instanceSecret } = args.existingCredentials === null || args.existingCredentials.instanceSecret === LEGACY_LOCAL_BACKEND_INSTANCE_SECRET ? (
    // Using `generateLocalDevSecretsFromLatestBinary` instead of `generateLocalDevSecrets`
    // here, because `newBinaryPath` can be a binary that doesn’t support
    // the `keygen admin-key` subcommand (when the --local-backend-version flag is provided to the CLI)
    //
    // In most cases (the user is not using the flag), we have already downloaded the latest binary
    // shortly before in handleLocalDeployment/handleAnonymousDeployment, so this doesn’t cause an
    // extra download (even if the user chooses later not to upgrade their deployment)
    await generateLocalDevSecretsWithLatestBinary(ctx, {
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
    saveDeploymentConfig(
      ctx,
      args.deploymentKind,
      args.deploymentName,
      newConfig
    );
    const { cleanupHandle: cleanupHandle2 } = await runLocalBackend(ctx, {
      binaryPath: args.newBinaryPath,
      deploymentKind: args.deploymentKind,
      deploymentName: args.deploymentName,
      ports: args.ports,
      instanceSecret,
      isLatestVersion: true
    });
    return { cleanupHandle: cleanupHandle2, adminKey };
  }
  logVerbose(
    `Considering upgrade from ${args.oldVersion} to ${args.newVersion}`
  );
  const confirmed = args.forceUpgrade || !process.stdin.isTTY || await promptYesNo(ctx, {
    message: `This deployment is using an older version of the Convex backend. Upgrade now?`,
    default: true
  });
  if (!confirmed) {
    const { binaryPath: oldBinaryPath } = await ensureBackendBinaryDownloaded(
      ctx,
      {
        kind: "version",
        version: args.oldVersion
      }
    );
    saveDeploymentConfig(ctx, args.deploymentKind, args.deploymentName, {
      ...newConfig,
      backendVersion: args.oldVersion
    });
    const { cleanupHandle: cleanupHandle2 } = await runLocalBackend(ctx, {
      binaryPath: oldBinaryPath,
      ports: args.ports,
      deploymentKind: args.deploymentKind,
      deploymentName: args.deploymentName,
      instanceSecret,
      isLatestVersion: false
    });
    return { cleanupHandle: cleanupHandle2, adminKey };
  }
  const choice = args.forceUpgrade || !process.stdin.isTTY ? "transfer" : await promptOptions(ctx, {
    message: "Transfer data from existing deployment?",
    default: "transfer",
    choices: [
      { name: "transfer data", value: "transfer" },
      { name: "start fresh", value: "reset" }
    ]
  });
  const deploymentStatePath = deploymentStateDir(
    ctx,
    args.deploymentKind,
    args.deploymentName
  );
  if (choice === "reset") {
    recursivelyDelete(ctx, deploymentStatePath, { force: true });
    saveDeploymentConfig(
      ctx,
      args.deploymentKind,
      args.deploymentName,
      newConfig
    );
    const { cleanupHandle: cleanupHandle2 } = await runLocalBackend(ctx, {
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
  const { binaryPath: oldBinaryPath } = await ensureBackendBinaryDownloaded(
    ctx,
    {
      kind: "version",
      version: args.oldVersion
    }
  );
  logVerbose("Running backend on old version");
  const { cleanupHandle: oldCleanupHandle } = await runLocalBackend(ctx, {
    binaryPath: oldBinaryPath,
    ports: args.ports,
    deploymentKind: args.deploymentKind,
    deploymentName: args.deploymentName,
    instanceSecret: args.instanceSecret,
    isLatestVersion: false
  });
  logVerbose("Downloading env vars");
  const deploymentUrl = localDeploymentUrl(args.ports.cloud);
  const envs = await runSystemQuery(ctx, {
    deploymentUrl,
    adminKey,
    functionName: "_system/cli/queryEnvironmentVariables",
    componentPath: void 0,
    args: {}
  });
  logVerbose("Doing a snapshot export");
  const exportPath = path.join(
    deploymentStateDir(ctx, args.deploymentKind, args.deploymentName),
    "export.zip"
  );
  if (ctx.fs.exists(exportPath)) {
    ctx.fs.unlink(exportPath);
  }
  const snapshotExportState = await startSnapshotExport(ctx, {
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
  await downloadSnapshotExport(ctx, {
    snapshotExportTs: snapshotExportState.start_ts,
    inputPath: exportPath,
    adminKey,
    deploymentUrl
  });
  logVerbose("Stopping the backend on the old version");
  const oldCleanupFunc = ctx.removeCleanup(oldCleanupHandle);
  if (oldCleanupFunc) {
    await oldCleanupFunc(0);
  }
  await ensureBackendStopped(ctx, {
    ports: args.ports,
    maxTimeSecs: 5,
    deploymentName: args.deploymentName,
    allowOtherDeployments: false
  });
  logVerbose("Running backend on new version");
  const { cleanupHandle } = await runLocalBackend(ctx, {
    binaryPath: args.newBinaryPath,
    ports: args.ports,
    deploymentKind: args.deploymentKind,
    deploymentName: args.deploymentName,
    instanceSecret: args.instanceSecret,
    isLatestVersion: true
  });
  logVerbose("Importing the env vars");
  if (envs.length > 0) {
    const fetch = deploymentFetch(ctx, {
      deploymentUrl,
      adminKey
    });
    try {
      await fetch("/api/update_environment_variables", {
        body: JSON.stringify({ changes: envs }),
        method: "POST"
      });
    } catch (e) {
      return await logAndHandleFetchError(ctx, e);
    }
  }
  logVerbose("Doing a snapshot import");
  const importId = await uploadForImport(ctx, {
    deploymentUrl,
    adminKey,
    filePath: exportPath,
    importArgs: { format: "zip", mode: "replace", tableName: void 0 },
    onImportFailed: async (e) => {
      logFailure(`Failed to import snapshot: ${e}`);
    }
  });
  logVerbose(`Snapshot import started`);
  let status = await waitForStableImportState(ctx, {
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
      errForSentry: new LocalDeploymentError(message)
    });
  }
  await confirmImport(ctx, {
    importId,
    adminKey,
    deploymentUrl,
    onError: async (e) => {
      logFailure(`Failed to confirm import: ${e}`);
    }
  });
  logVerbose(`Snapshot import confirmed`);
  status = await waitForStableImportState(ctx, {
    importId,
    deploymentUrl,
    adminKey,
    onProgress: () => {
      return 0;
    }
  });
  logVerbose(`Snapshot import status: ${status.state}`);
  if (status.state !== "completed") {
    const message = "Error while transferring data: Failed to import snapshot";
    return ctx.crash({
      exitCode: 1,
      errorType: "fatal",
      printedMessage: message,
      errForSentry: new LocalDeploymentError(message)
    });
  }
  logFinishedStep("Successfully upgraded to a new backend version");
  saveDeploymentConfig(ctx, args.deploymentKind, args.deploymentName, {
    ports: args.ports,
    backendVersion: args.newVersion,
    adminKey,
    instanceSecret: args.instanceSecret,
    cloudProjectId: args.cloudProjectId
  });
  return { cleanupHandle };
}
//# sourceMappingURL=upgrade.js.map
