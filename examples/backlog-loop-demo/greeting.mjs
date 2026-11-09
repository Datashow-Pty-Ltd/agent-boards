export function formatGreeting(name) {
  const subject = String(name ?? "").trim() || "world";
  return `Hello, ${subject}!`;
}
