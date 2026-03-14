import { useState, useEffect, useCallback } from "react";
import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  Tooltip,
  ResponsiveContainer,
  Legend,
} from "recharts";
import { fetchRealtime } from "../api";

const REFRESH_INTERVAL = 10000; // 10 seconds

const EVENT_COLORS = {
  page_view:   "#6366f1",
  click:       "#22c55e",
  api_call:    "#f59e0b",
  form_submit: "#14b8a6",
  error:       "#ef4444",
  custom:      "#8b5cf6",
};

function LiveDot({ streaming }) {
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
      <span
        style={{
          width: 8,
          height: 8,
          borderRadius: "50%",
          background: streaming ? "#22c55e" : "#6b7280",
          display: "inline-block",
          animation: streaming ? "pulse 1.5s ease-in-out infinite" : "none",
        }}
      />
      {streaming ? "Live" : "No data"}
    </span>
  );
}

export default function LiveMetrics({ token }) {
  const [data, setData] = useState(null);
  const [lastUpdated, setLastUpdated] = useState(null);
  const [error, setError] = useState(null);

  const refresh = useCallback(async () => {
    try {
      const result = await fetchRealtime(token);
      setData(result);
      setLastUpdated(new Date());
      setError(null);
    } catch (err) {
      setError(err.message);
    }
  }, [token]);

  useEffect(() => {
    refresh();
    const id = setInterval(refresh, REFRESH_INTERVAL);
    return () => clearInterval(id);
  }, [refresh]);

  const hasData = data && data.total_events > 0;

  return (
    <section style={{ marginBottom: 32 }}>
      {/* Header */}
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
        <h2 style={{ margin: 0, fontSize: 18, fontWeight: 600 }}>
          Live Metrics{" "}
          <span style={{ fontSize: 13, fontWeight: 400, color: "#9ca3af" }}>
            (last {data?.lookback_minutes ?? 5} min)
          </span>
        </h2>
        <span style={{ fontSize: 12, color: "#6b7280" }}>
          <LiveDot streaming={hasData} />
          {lastUpdated && (
            <span style={{ marginLeft: 8 }}>
              updated {lastUpdated.toLocaleTimeString()}
            </span>
          )}
        </span>
      </div>

      {error && (
        <p style={{ color: "#ef4444", fontSize: 13, marginBottom: 12 }}>
          Stream unavailable: {error}
        </p>
      )}

      {/* Stat cards */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 16, marginBottom: 20 }}>
        <div className="stat-card">
          <div className="stat-value" style={{ color: "#6366f1" }}>
            {data?.total_events ?? 0}
          </div>
          <div className="stat-label">Events (last 5 min)</div>
        </div>
        <div className="stat-card">
          <div className="stat-value" style={{ color: "#ef4444" }}>
            {data?.error_rate_pct ?? 0}%
          </div>
          <div className="stat-label">Error Rate</div>
        </div>
        <div className="stat-card">
          <div className="stat-value" style={{ color: "#22c55e" }}>
            {data?.active_sessions ?? 0}
          </div>
          <div className="stat-label">Active Sessions</div>
        </div>
      </div>

      {/* Sparkline area chart */}
      <div style={{ background: "#1f2937", borderRadius: 8, padding: 16 }}>
        <h3 style={{ margin: "0 0 12px", fontSize: 14, fontWeight: 500, color: "#9ca3af" }}>
          Events per Minute by Type
        </h3>
        {!hasData ? (
          <p style={{ color: "#4b5563", textAlign: "center", padding: "24px 0", margin: 0 }}>
            Waiting for stream data — ingest some events to see real-time metrics
          </p>
        ) : (
          <ResponsiveContainer width="100%" height={180}>
            <AreaChart data={data.timeline} margin={{ top: 4, right: 8, left: -20, bottom: 0 }}>
              <XAxis
                dataKey="minute"
                tick={{ fontSize: 10, fill: "#6b7280" }}
                tickFormatter={(v) => v.slice(11)}  // show HH:MM only
              />
              <YAxis tick={{ fontSize: 10, fill: "#6b7280" }} allowDecimals={false} />
              <Tooltip
                contentStyle={{ background: "#111827", border: "1px solid #374151", fontSize: 12 }}
                labelStyle={{ color: "#d1d5db" }}
              />
              <Legend wrapperStyle={{ fontSize: 11 }} />
              {Object.entries(EVENT_COLORS).map(([type, color]) => (
                <Area
                  key={type}
                  type="monotone"
                  dataKey={type}
                  stackId="1"
                  stroke={color}
                  fill={color}
                  fillOpacity={0.4}
                  dot={false}
                />
              ))}
            </AreaChart>
          </ResponsiveContainer>
        )}
      </div>

      <style>{`
        @keyframes pulse {
          0%, 100% { opacity: 1; }
          50% { opacity: 0.4; }
        }
      `}</style>
    </section>
  );
}
