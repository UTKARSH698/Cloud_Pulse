import {
  LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip,
  Legend, ResponsiveContainer,
} from "recharts";

const EVENT_COLORS = {
  page_view: "#6366f1",
  click: "#22d3ee",
  api_call: "#f59e0b",
  form_submit: "#10b981",
  error: "#ef4444",
};

function transformTimeseries(results) {
  // results: [{hour, event_type, event_count}, ...]
  // → [{hour, page_view: N, click: N, ...}, ...]
  const map = {};
  const types = new Set();
  for (const row of results) {
    types.add(row.event_type);
    if (!map[row.hour]) map[row.hour] = { hour: row.hour.slice(11, 16) };
    map[row.hour][row.event_type] = Number(row.event_count);
  }
  return { rows: Object.values(map).sort((a, b) => a.hour.localeCompare(b.hour)), types: [...types] };
}

export default function TimeseriesChart({ data }) {
  const results = data?.results ?? [];
  const { rows, types } = transformTimeseries(results);

  return (
    <div className="chart-card">
      <h2>Events Over Time</h2>
      <ResponsiveContainer width="100%" height={240}>
        <LineChart data={rows} margin={{ top: 8, right: 16, left: 0, bottom: 0 }}>
          <CartesianGrid strokeDasharray="3 3" stroke="#2d2d2d" />
          <XAxis dataKey="hour" tick={{ fill: "#9ca3af", fontSize: 11 }} />
          <YAxis tick={{ fill: "#9ca3af", fontSize: 12 }} />
          <Tooltip
            contentStyle={{ background: "#1a1a1a", border: "1px solid #333", borderRadius: 8 }}
            labelStyle={{ color: "#e5e7eb" }}
          />
          <Legend wrapperStyle={{ color: "#9ca3af", fontSize: 12 }} />
          {types.map((t) => (
            <Line
              key={t}
              type="monotone"
              dataKey={t}
              stroke={EVENT_COLORS[t] ?? "#6366f1"}
              strokeWidth={2}
              dot={false}
            />
          ))}
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}
