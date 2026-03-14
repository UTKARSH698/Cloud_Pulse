import { render, screen, waitFor, act } from "@testing-library/react";
import { vi } from "vitest";
import LiveMetrics from "../components/LiveMetrics";

// Recharts uses ResizeObserver which isn't available in jsdom
global.ResizeObserver = class {
  observe() {}
  unobserve() {}
  disconnect() {}
};

// Mock the api module
vi.mock("../api", () => ({
  fetchRealtime: vi.fn(),
}));

import { fetchRealtime } from "../api";

const MOCK_REALTIME = {
  lookback_minutes: 5,
  total_events: 42,
  error_count: 3,
  error_rate_pct: 7.1,
  active_sessions: 8,
  by_event_type: { page_view: 20, click: 15, error: 3, api_call: 4, form_submit: 0, custom: 0 },
  timeline: [
    { minute: "2026-03-14T10:43", page_view: 8, click: 5, error: 1, api_call: 2, form_submit: 0, custom: 0 },
  ],
};

describe("LiveMetrics", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("renders heading and stat cards on successful fetch", async () => {
    fetchRealtime.mockResolvedValueOnce(MOCK_REALTIME);

    render(<LiveMetrics token="fake-token" />);

    await waitFor(() => {
      expect(screen.getByText("Live Metrics")).toBeInTheDocument();
      expect(screen.getByText("42")).toBeInTheDocument();
      expect(screen.getByText("7.1%")).toBeInTheDocument();
      expect(screen.getByText("8")).toBeInTheDocument();
    });
  });

  it("shows empty state message when no data", async () => {
    fetchRealtime.mockResolvedValueOnce({
      ...MOCK_REALTIME,
      total_events: 0,
      timeline: [],
    });

    render(<LiveMetrics token="fake-token" />);

    await waitFor(() => {
      expect(screen.getByText(/Waiting for stream data/i)).toBeInTheDocument();
    });
  });

  it("shows error message when fetch fails", async () => {
    fetchRealtime.mockRejectedValue(new Error("Network error"));

    render(<LiveMetrics token="fake-token" />);

    await waitFor(
      () => expect(screen.getByText(/Stream unavailable/i)).toBeInTheDocument(),
      { timeout: 3000 }
    );
  });

  it("calls fetchRealtime with the provided token", async () => {
    fetchRealtime.mockResolvedValueOnce(MOCK_REALTIME);

    render(<LiveMetrics token="my-token-123" />);

    await waitFor(() => expect(fetchRealtime).toHaveBeenCalledWith("my-token-123"));
  });
});
