export default function ErrorsTable({ data }) {
  const rows = (data?.results ?? []).slice(0, 10);

  return (
    <div className="chart-card">
      <h2>Recent Errors <span className="error-badge">{data?.rows_returned ?? 0}</span></h2>
      <table className="data-table">
        <thead>
          <tr>
            <th>Event ID</th>
            <th>Session</th>
            <th>Timestamp</th>
            <th>Properties</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => {
            let props = {};
            try { props = JSON.parse(row.properties ?? "{}"); } catch {}
            return (
              <tr key={row.event_id}>
                <td className="mono small">{row.event_id?.slice(0, 8)}…</td>
                <td className="mono small">{row.session_id?.slice(0, 10)}…</td>
                <td className="muted small">{row.timestamp?.slice(0, 16).replace("T", " ")}</td>
                <td className="muted small">{JSON.stringify(props)}</td>
              </tr>
            );
          })}
          {rows.length === 0 && (
            <tr><td colSpan={4} className="empty">No errors found</td></tr>
          )}
        </tbody>
      </table>
    </div>
  );
}
