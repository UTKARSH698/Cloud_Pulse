import {
  BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, Cell,
} from "recharts";

const COLORS = {
  page_view: "#6366f1",
  click: "#22d3ee",
  api_call: "#f59e0b",
  form_submit: "#10b981",
  error: "#ef4444",
};

export default function EventCountChart({ data }) {
  const rows = data?.results ?? [];

  return (
    <div className="chart-card">
      <h2>Event Counts</h2>
      <ResponsiveContainer width="100%" height={240}>
        <BarChart data={rows} margin={{ top: 8, right: 16, left: 0, bottom: 0 }}>
          <CartesianGrid strokeDasharray="3 3" stroke="#2d2d2d" />
          <XAxis dataKey="event_type" tick={{ fill: "#9ca3af", fontSize: 12 }} />
          <YAxis tick={{ fill: "#9ca3af", fontSize: 12 }} />
          <Tooltip
            contentStyle={{ background: "#1a1a1a", border: "1px solid #333", borderRadius: 8 }}
            labelStyle={{ color: "#e5e7eb" }}
          />
          <Bar dataKey="event_count" radius={[4, 4, 0, 0]}>
            {rows.map((row) => (
              <Cell key={row.event_type} fill={COLORS[row.event_type] ?? "#6366f1"} />
            ))}
          </Bar>
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}
