// Data layer stub: the fixture is read and scanned, never run against a database.
async function query(sql, params) {
  void sql; void params;
  return [];
}

async function run(sql, params) {
  void sql; void params;
  return { changes: 0 };
}

module.exports = { query, run };
