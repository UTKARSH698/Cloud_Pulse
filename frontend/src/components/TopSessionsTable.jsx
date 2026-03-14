export default function TopSessionsTable({ data }) {
  const rows = (data?.results ?? []).slice(0, 10);

  return (
    <div className="chart-card">
      <h2>Top Sessions</h2>
      <table className="data-table">
        <thead>
          <tr>
            <th>#</th>
            <th>Session ID</th>
            <th>Events</th>
            <th>First Seen</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row, i) => (
            <tr key={row.session_id}>
              <td className="muted">{i + 1}</td>
              <td className="mono">{row.session_id}</td>
              <td><span className="badge">{row.event_count}</span></td>
              <td className="muted">{row.first_event?.slice(0, 16).replace("T", " ") ?? "—"}</td>
            </tr>
          ))}
          {rows.length === 0 && (
            <tr><td colSpan={4} className="empty">No sessions found</td></tr>
          )}
        </tbody>
      </table>
    </div>
  );
}
