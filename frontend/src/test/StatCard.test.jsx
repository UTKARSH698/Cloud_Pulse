import { render, screen } from "@testing-library/react";
import StatCard from "../components/StatCard";

describe("StatCard", () => {
  it("renders value and label", () => {
    render(<StatCard label="Total Events" value="601" color="#6366f1" />);
    expect(screen.getByText("601")).toBeInTheDocument();
    expect(screen.getByText("Total Events")).toBeInTheDocument();
  });

  it("applies the given color to value", () => {
    render(<StatCard label="Errors" value="29" color="#ef4444" />);
    const value = screen.getByText("29");
    expect(value).toHaveStyle({ color: "#ef4444" });
  });
});
