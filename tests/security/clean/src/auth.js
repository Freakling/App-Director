// Sessions are looked up by the random token in the session cookie.
const sessions = new Map();

function currentUser(req) {
  const cookie = req.headers.cookie || "";
  const token = (cookie.match(/(?:^|;\s*)session=([A-Za-z0-9_-]+)/) || [])[1];
  return token ? sessions.get(token) || null : null;
}

module.exports = { currentUser, sessions };
