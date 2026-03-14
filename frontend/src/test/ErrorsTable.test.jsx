import { render, screen } from "@testing-library/react";
import ErrorsTable from "../components/ErrorsTable";

const MOCK_DATA = {
  rows_returned: 2,
  results: [
    {
      event_id: "aabbccdd-1234-5678-abcd-000000000001",
      session_id: "sess_afb77abc",
      timestamp: "2026-03-12T07:28:00",
      properties: '{"message":"ValidationFailed","code":"422","page":"/billing"}',
    },
    {
      event_id: "aabbccdd-1234-5678-abcd-000000000002",
      session_id: "sess_37c7fabc",
      timestamp: "2026-03-11T18:07:00",
      properties: '{"message":"ResourceNotFound","code":"404","page":"/pricing"}',
    },
  ],
};

describe("ErrorsTable", () => {
  it("renders the heading with error count badge", () => {
    render(<ErrorsTable data={MOCK_DATA} />);
    expect(screen.getByText("Recent Errors")).toBeInTheDocument();
    expect(screen.getByText("2")).toBeInTheDocument();
  });

  it("renders truncated event IDs", () => {
    render(<ErrorsTable data={MOCK_DATA} />);
    const ids = screen.getAllByText("aabbccdd…");
    expect(ids).toHaveLength(2);
  });

  it("renders properties as JSON string", () => {
    render(<ErrorsTable data={MOCK_DATA} />);
    expect(
      screen.getByText(/ValidationFailed/)
    ).toBeInTheDocument();
  });

  it("shows empty state when no errors", () => {
    render(<ErrorsTable data={{ rows_returned: 0, results: [] }} />);
    expect(screen.getByText("No errors found")).toBeInTheDocument();
  });

  it("shows 0 badge when rows_returned is 0", () => {
    render(<ErrorsTable data={{ rows_returned: 0, results: [] }} />);
    expect(screen.getByText("0")).toBeInTheDocument();
  });
});
