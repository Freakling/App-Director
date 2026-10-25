// Seeded vulnerable fixture for the security assessment: see tests/security/README.md. Never deploy it.
const http = require("node:http");
const _ = require("lodash");
const { query, run } = require("./db");
const { currentUser } = require("./auth");
const { chargeCard } = require("./payments");

function send(res, status, body) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(body === null ? "" : JSON.stringify(body));
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  const user = currentUser(req);

  if (req.method === "GET" && url.pathname === "/notes") {
    if (!user) return send(res, 401, { error: "sign in first" });
    const search = url.searchParams.get("q") || "";
    const rows = await query(
      "SELECT id, title FROM notes WHERE owner = '" + user.id + "' AND title LIKE '%" + search + "%'"
    );
    return send(res, 200, rows.map((row) => _.pick(row, ["id", "title"])));
  }

  const note = url.pathname.match(/^\/notes\/(\d+)$/);
  if (req.method === "DELETE" && note) {
    await run("DELETE FROM notes WHERE id = ?", [note[1]]);
    return send(res, 204, null);
  }

  if (req.method === "POST" && url.pathname === "/upgrade") {
    if (!user) return send(res, 401, { error: "sign in first" });
    await chargeCard(user.id);
    return send(res, 200, { plan: "pro" });
  }

  return send(res, 404, { error: "not found" });
});

server.listen(Number(process.env.PORT || 3000));
