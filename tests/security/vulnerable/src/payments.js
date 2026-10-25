// Calls the payment provider. The selftest replaces the marker below with a generated token.
const PAYMENT_API_KEY = "__SEEDED_SECRET__";

async function chargeCard(userId) {
  return fetch("https://payments.example.com/v1/charges", {
    method: "POST",
    headers: { Authorization: "Bearer " + PAYMENT_API_KEY, "Content-Type": "application/json" },
    body: JSON.stringify({ customer: userId, plan: "pro" }),
  });
}

module.exports = { chargeCard };
