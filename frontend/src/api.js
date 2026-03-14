import { CONFIG } from "./config";

const today = () => new Date().toISOString().split("T")[0];
const monthAgo = () => {
  const d = new Date();
  d.setDate(d.getDate() - 30);
  return d.toISOString().split("T")[0];
};

async function fetchQuery(token, queryType, extra = {}) {
  const params = new URLSearchParams({
    query_type: queryType,
    date_from: monthAgo(),
    date_to: today(),
    ...extra,
  });
  const res = await fetch(
    `${CONFIG.apiEndpoint}/query?${params.toString()}`,
    { headers: { Authorization: token } }
  );
  if (!res.ok) throw new Error(`${queryType} failed: ${res.status}`);
  return res.json();
}

export const fetchEventCount = (token) => fetchQuery(token, "event_count");
export const fetchTimeseries = (token) => fetchQuery(token, "timeseries");
export const fetchTopSessions = (token) => fetchQuery(token, "top_sessions");
export const fetchErrors = (token) => fetchQuery(token, "errors");
