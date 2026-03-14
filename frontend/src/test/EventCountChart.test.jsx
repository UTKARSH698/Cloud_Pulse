import { render, screen } from "@testing-library/react";
import EventCountChart from "../components/EventCountChart";

// Recharts uses ResizeObserver which isn't available in jsdom
global.ResizeObserver = class {
  observe() {}
  unobserve() {}
  disconnect() {}
};

const MOCK_DATA = {
  results: [
    { event_type: "page_view",  event_count: "267" },
    { event_type: "click",      event_count: "164" },
    { event_type: "api_call",   event_count: "79"  },
    { event_type: "form_submit",event_count: "62"  },
    { event_type: "error",      event_count: "29"  },
  ],
};

describe("EventCountChart", () => {
  it("renders the heading", () => {
    render(<EventCountChart data={MOCK_DATA} />);
    expect(screen.getByText("Event Counts")).toBeInTheDocument();
  });

  it("renders with empty data without crashing", () => {
    render(<EventCountChart data={{ results: [] }} />);
    expect(screen.getByText("Event Counts")).toBeInTheDocument();
  });

  it("renders with null data without crashing", () => {
    render(<EventCountChart data={null} />);
    expect(screen.getByText("Event Counts")).toBeInTheDocument();
  });
});
