import { useEffect, useState } from "react";
import { fetchEventCount, fetchTimeseries, fetchTopSessions, fetchErrors } from "../api";
import { clearToken, logout } from "../auth";
import StatCard from "./StatCard";
import EventCountChart from "./EventCountChart";
import TimeseriesChart from "./TimeseriesChart";
import TopSessionsTable from "./TopSessionsTable";
import ErrorsTable from "./ErrorsTable";
import LiveMetrics from "./LiveMetrics";

const STAT_COLORS = {
  page_view: "#6366f1",
  click: "#22d3ee",
  api_call: "#f59e0b",
  form_submit: "#10b981",
  error: "#ef4444",
};

export default function Dashboard({ token, onLogout }) {
  const [eventCount, setEventCount] = useState(null);
  const [timeseries, setTimeseries] = useState(null);
  const [topSessions, setTopSessions] = useState(null);
  const [errors, setErrors] = useState(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");
  const [lastRefresh, setLastRefresh] = useState(null);

  async function loadAll() {
    setLoading(true);
    setErr("");
    try {
      const [ec, ts, sess, errs] = await Promise.all([
        fetchEventCount(token),
        fetchTimeseries(token),
        fetchTopSessions(token),
        fetchErrors(token),
      ]);
      setEventCount(ec);
      setTimeseries(ts);
      setTopSessions(sess);
      setErrors(errs);
      setLastRefresh(new Date().toLocaleTimeString());
    } catch (e) {
      setErr(e.message);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { loadAll(); }, []);

  function handleLogout() {
    logout();
    clearToken();
    onLogout();
  }

  const statRows = eventCount?.results ?? [];
  const totalEvents = statRows.reduce((s, r) => s + Number(r.event_count), 0);

  return (
    <div className="dashboard">
      <header className="topbar">
        <div className="topbar-left">
          <span className="logo-icon">☁</span>
          <span className="logo-text">CloudPulse</span>
          <span className="subtitle">Analytics Dashboard</span>
        </div>
        <div className="topbar-right">
          {lastRefresh && <span className="refresh-time">Updated {lastRefresh}</span>}
          <button className="btn-ghost" onClick={loadAll} disabled={loading}>
            {loading ? "Loading…" : "↻ Refresh"}
          </button>
          <button className="btn-ghost" onClick={handleLogout}>Sign out</button>
        </div>
      </header>

      {err && <div className="global-error">{err}</div>}

      {loading && !eventCount ? (
        <div className="loader">Fetching analytics…</div>
      ) : (
        <main className="content">
          {/* Real-time streaming metrics */}
          <LiveMetrics token={token} />

          {/* Stat row */}
          <div className="stats-row">
            <StatCard label="Total Events" value={totalEvents.toLocaleString()} color="#6366f1" />
            {statRows.map((r) => (
              <StatCard
                key={r.event_type}
                label={r.event_type.replace("_", " ")}
                value={Number(r.event_count).toLocaleString()}
                color={STAT_COLORS[r.event_type] ?? "#6366f1"}
              />
            ))}
          </div>

          {/* Charts row */}
          <div className="charts-row">
            <EventCountChart data={eventCount} />
            <TimeseriesChart data={timeseries} />
          </div>

          {/* Tables row */}
          <div className="tables-row">
            <TopSessionsTable data={topSessions} />
            <ErrorsTable data={errors} />
          </div>
        </main>
      )}
    </div>
  );
}
