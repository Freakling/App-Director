// A static server for the selftest's fixture web app: node tests/ui-web/serve.mjs <port>
// Serves tests/ui-web/site on 127.0.0.1 only. /missing answers 404, so a failed first request can be
// tested; /redirect-away redirects off this machine; /api/data answers JSON.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { dirname, join, normalize } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "site");
const port = Number(process.argv[2] || 47831);
createServer(async (request, response) => {
  if (request.url === "/redirect-away") {
    // A redirect off this machine: capture must not follow it.
    response.writeHead(302, { location: "http://203.0.113.9/redirected" });
    response.end();
    return;
  }
  if (request.url === "/api/data") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end('{"local": true}');
    return;
  }
  const path = normalize(decodeURIComponent(new URL(request.url, "http://localhost").pathname)).replace(/^[/\\]+/, "");
  const file = join(root, path === "" || path === "." ? "index.html" : path.endsWith(".html") ? path : path + ".html");
  try {
    const body = await readFile(file);
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    response.end(body);
  } catch {
    response.writeHead(404, { "content-type": "text/plain" });
    response.end("not found");
  }
}).listen(port, "127.0.0.1");
