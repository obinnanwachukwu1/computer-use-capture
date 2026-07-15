#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import path from "node:path";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { RecorderError, RecorderService } from "../lib/recorder-service.mjs";

const repoRoot = path.resolve(import.meta.dirname, "..");
const contract = JSON.parse(await readFile(path.join(repoRoot, "docs", "mcp-tools.schema.json"), "utf8"));
const tools = new Map(contract.tools.map(tool => [tool.name, tool]));
const ajv = new Ajv2020({ allErrors: true, strict: false });
addFormats(ajv);
const validators = new Map(contract.tools.map(tool => [tool.name, {
  input: ajv.compile(tool.inputSchema),
  output: ajv.compile(tool.outputSchema)
}]));
const validateError = ajv.compile(contract.errorModel.errorSchema);
const service = new RecorderService({ repoRoot });
await service.initialize();

const server = new Server(
  { name: "computer-use-capture", version: contract.contract.contractVersion },
  { capabilities: { tools: { listChanged: false } } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: contract.tools }));
server.setRequestHandler(CallToolRequestSchema, async request => {
  const { name, arguments: args = {} } = request.params;
  const tool = tools.get(name);
  if (!tool) return toolError(new RecorderError("invalid_argument", `Unknown tool: ${name}`));
  const validate = validators.get(name);
  if (!validate.input(args)) {
    return toolError(new RecorderError("invalid_argument", "Tool arguments did not match the contract", {
      data: { validationErrors: validate.input.errors }
    }));
  }
  try {
    const method = ({
      recorder_start: "start",
      recorder_stop: "stop",
      recorder_edit: "edit",
      recorder_get: "get",
      recorder_cancel: "cancel",
      recorder_discard: "discard",
      recorder_capabilities: "capabilities"
    })[name];
    const activeRecordingBeforeStart = name === "recorder_start"
      ? await service.activeRecordingId()
      : null;
    const result = await service[method](args);
    if (!validate.output(result)) {
      if (name === "recorder_start"
          && result?.recordingId
          && result.recordingId !== activeRecordingBeforeStart) {
        await service.discard({ recordingId: result.recordingId }).catch(() => {});
      }
      throw new RecorderError("storage_unavailable", "Server produced a result outside its MCP output contract", {
        data: { validationErrors: validate.output.errors }
      });
    }
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
      structuredContent: result
    };
  } catch (error) {
    return toolError(error);
  }
});

function toolError(error) {
  const normalized = error instanceof RecorderError ? error
    : new RecorderError("storage_unavailable", error instanceof Error ? error.message : String(error));
  const structuredContent = {
    code: contract.errorModel.errorSchema.properties.code.enum.includes(normalized.code)
      ? normalized.code : "storage_unavailable",
    message: normalized.message,
    retryable: normalized.retryable,
    ...(normalized.data ? { data: normalized.data } : {})
  };
  if (!validateError(structuredContent)) {
    structuredContent.code = "storage_unavailable";
    structuredContent.message = "Recorder failed and could not serialize its original error safely";
    structuredContent.retryable = false;
    delete structuredContent.data;
  }
  return {
    isError: true,
    content: [{ type: "text", text: JSON.stringify(structuredContent) }]
  };
}

let shuttingDown = false;
async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  await service.shutdown();
  await server.close();
  process.exit(0);
}
process.once("SIGINT", shutdown);
process.once("SIGTERM", shutdown);
process.once("disconnect", shutdown);
process.stdin.once("end", shutdown);

const transport = new StdioServerTransport();
await server.connect(transport);
console.error(`Computer Use Capture MCP server ready (contract ${contract.contract.contractVersion})`);
