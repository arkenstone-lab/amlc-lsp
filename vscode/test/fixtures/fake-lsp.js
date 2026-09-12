"use strict";

const requestedVersion = process.argv
  .find((argument) => argument.startsWith("--server-version="))
  ?.slice("--server-version=".length);
const serverVersion = requestedVersion || "0.3.0";
let input = Buffer.alloc(0);

function write(message) {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  process.stdout.write(`Content-Length: ${body.length}\r\n\r\n`);
  process.stdout.write(body);
}

function respond(id, result) {
  write({ jsonrpc: "2.0", id, result });
}

function handle(message) {
  switch (message.method) {
    case "initialize":
      respond(message.id, {
        capabilities: {
          textDocumentSync: { openClose: true, change: 2 },
          completionProvider: {},
        },
        serverInfo: { name: "amlc-lsp", version: serverVersion },
      });
      break;
    case "textDocument/didOpen":
      write({
        jsonrpc: "2.0",
        method: "textDocument/publishDiagnostics",
        params: {
          uri: message.params.textDocument.uri,
          diagnostics: [
            {
              range: {
                start: { line: 0, character: 0 },
                end: { line: 0, character: 7 },
              },
              severity: 2,
              source: "amlc-lsp-test",
              message: "extension-host diagnostic",
            },
          ],
        },
      });
      break;
    case "textDocument/completion":
      respond(message.id, {
        isIncomplete: false,
        items: [{ label: "increment", kind: 3 }],
      });
      break;
    case "shutdown":
      respond(message.id, null);
      break;
    case "exit":
      process.exit(0);
      break;
    default:
      if (message.id !== undefined) {
        write({
          jsonrpc: "2.0",
          id: message.id,
          error: { code: -32601, message: "Method not found" },
        });
      }
  }
}

function drain() {
  for (;;) {
    const headerEnd = input.indexOf("\r\n\r\n");
    if (headerEnd < 0) {
      return;
    }
    const header = input.subarray(0, headerEnd).toString("ascii");
    const length = /content-length:\s*(\d+)/i.exec(header);
    if (!length) {
      process.exit(2);
    }
    const bodyStart = headerEnd + 4;
    const bodyEnd = bodyStart + Number(length[1]);
    if (input.length < bodyEnd) {
      return;
    }
    const message = JSON.parse(input.subarray(bodyStart, bodyEnd).toString("utf8"));
    input = input.subarray(bodyEnd);
    handle(message);
  }
}

process.stdin.on("data", (chunk) => {
  input = Buffer.concat([input, chunk]);
  drain();
});
