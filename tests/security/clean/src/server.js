// Clean twin of the seeded vulnerable fixture: see tests/security/README.md.
const http = require("node:http");
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
    const search = (url.searchParams.get("q") || "").slice(0, 100);
    const rows = await query(
      "SELECT id, title FROM notes WHERE owner = ? AND title LIKE ?",
      [user.id, "%" + search + "%"]
    );
    return send(res, 200, rows.map((row) => ({ id: row.id, title: row.title })));
  }

  const note = url.pathname.match(/^\/notes\/(\d+)$/);
  if (req.method === "DELETE" && note) {
    if (!user) return send(res, 401, { error: "sign in first" });
    const result = await run("DELETE FROM notes WHERE id = ? AND owner = ?", [note[1], user.id]);
    return send(res, result.changes === 1 ? 204 : 404, null);
  }

  if (req.method === "POST" && url.pathname === "/upgrade") {
    if (!user) return send(res, 401, { error: "sign in first" });
    await chargeCard(user.id);
    return send(res, 200, { plan: "pro" });
  }

  return send(res, 404, { error: "not found" });
});

server.listen(Number(process.env.PORT || 3000));
