import { useState } from "react";
import { getStoredToken } from "./auth";
import Login from "./components/Login";
import Dashboard from "./components/Dashboard";

function App() {
  const [token, setToken] = useState(() => getStoredToken());

  if (!token) {
    return <Login onLogin={(t) => setToken(t)} />;
  }
  return <Dashboard token={token} onLogout={() => setToken(null)} />;
}

export default App;
