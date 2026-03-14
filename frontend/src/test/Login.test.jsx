import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import { vi } from "vitest";
import Login from "../components/Login";

// Mock the auth module
vi.mock("../auth", () => ({
  login: vi.fn(),
  storeToken: vi.fn(),
}));

import { login, storeToken } from "../auth";

describe("Login", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("renders email and password fields", () => {
    render(<Login onLogin={() => {}} />);
    expect(screen.getByPlaceholderText("you@example.com")).toBeInTheDocument();
    expect(screen.getByPlaceholderText("••••••••")).toBeInTheDocument();
  });

  it("renders the Sign in button", () => {
    render(<Login onLogin={() => {}} />);
    expect(screen.getByRole("button", { name: /sign in/i })).toBeInTheDocument();
  });

  it("calls onLogin with token on successful login", async () => {
    login.mockResolvedValueOnce("fake-id-token");
    const onLogin = vi.fn();
    render(<Login onLogin={onLogin} />);

    fireEvent.change(screen.getByPlaceholderText("you@example.com"), {
      target: { value: "test@example.com" },
    });
    fireEvent.change(screen.getByPlaceholderText("••••••••"), {
      target: { value: "Password@123" },
    });
    fireEvent.click(screen.getByRole("button", { name: /sign in/i }));

    await waitFor(() => {
      expect(storeToken).toHaveBeenCalledWith("fake-id-token");
      expect(onLogin).toHaveBeenCalledWith("fake-id-token");
    });
  });

  it("shows error message on failed login", async () => {
    login.mockRejectedValueOnce(new Error("Incorrect username or password"));
    render(<Login onLogin={() => {}} />);

    fireEvent.change(screen.getByPlaceholderText("you@example.com"), {
      target: { value: "wrong@example.com" },
    });
    fireEvent.change(screen.getByPlaceholderText("••••••••"), {
      target: { value: "WrongPass" },
    });
    fireEvent.click(screen.getByRole("button", { name: /sign in/i }));

    await waitFor(() => {
      expect(screen.getByText("Incorrect username or password")).toBeInTheDocument();
    });
  });

  it("disables button while loading", async () => {
    login.mockImplementation(() => new Promise(() => {})); // never resolves
    render(<Login onLogin={() => {}} />);

    fireEvent.change(screen.getByPlaceholderText("you@example.com"), {
      target: { value: "test@example.com" },
    });
    fireEvent.change(screen.getByPlaceholderText("••••••••"), {
      target: { value: "Password@123" },
    });
    fireEvent.click(screen.getByRole("button", { name: /sign in/i }));

    await waitFor(() => {
      expect(screen.getByRole("button", { name: /signing in/i })).toBeDisabled();
    });
  });
});
