import { render, screen } from "@testing-library/react";
import TopSessionsTable from "../components/TopSessionsTable";

const MOCK_DATA = {
  rows_returned: 3,
  results: [
    { session_id: "sess_abc123", event_count: "12", first_event: "2026-03-12T08:00:00" },
    { session_id: "sess_def456", event_count: "9",  first_event: "2026-03-11T14:30:00" },
    { session_id: "sess_ghi789", event_count: "7",  first_event: "2026-03-10T20:15:00" },
  ],
};

describe("TopSessionsTable", () => {
  it("renders the heading", () => {
    render(<TopSessionsTable data={MOCK_DATA} />);
    expect(screen.getByText("Top Sessions")).toBeInTheDocument();
  });

  it("renders all session rows", () => {
    render(<TopSessionsTable data={MOCK_DATA} />);
    expect(screen.getByText("sess_abc123")).toBeInTheDocument();
    expect(screen.getByText("sess_def456")).toBeInTheDocument();
    expect(screen.getByText("sess_ghi789")).toBeInTheDocument();
  });

  it("shows event count badges", () => {
    render(<TopSessionsTable data={MOCK_DATA} />);
    expect(screen.getByText("12")).toBeInTheDocument();
    expect(screen.getByText("9")).toBeInTheDocument();
  });

  it("shows empty state when no data", () => {
    render(<TopSessionsTable data={{ results: [] }} />);
    expect(screen.getByText("No sessions found")).toBeInTheDocument();
  });

  it("limits to top 10 rows", () => {
    const manyRows = Array.from({ length: 15 }, (_, i) => ({
      session_id: `sess_${i}`,
      event_count: String(15 - i),
      first_event: "2026-03-01T00:00:00",
    }));
    render(<TopSessionsTable data={{ results: manyRows }} />);
    const rows = screen.getAllByRole("row");
    // 1 header row + max 10 data rows
    expect(rows.length).toBe(11);
  });
});
