// Calls the payment provider. The key comes from the environment, never from source.
async function chargeCard(userId) {
  const key = process.env.PAYMENT_API_KEY;
  if (!key) throw new Error("PAYMENT_API_KEY is not set");
  return fetch("https://payments.example.com/v1/charges", {
    method: "POST",
    headers: { Authorization: "Bearer " + key, "Content-Type": "application/json" },
    body: JSON.stringify({ customer: userId, plan: "pro" }),
  });
}

module.exports = { chargeCard };
