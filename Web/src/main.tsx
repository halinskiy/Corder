import React from "react";
import { createRoot } from "react-dom/client";

function App() {
  const [meetings, setMeetings] = React.useState<unknown[]>([]);
  const [error, setError] = React.useState<string | null>(null);

  React.useEffect(() => {
    fetch("/api/meetings")
      .then((r) => r.json())
      .then(setMeetings)
      .catch((e) => setError(String(e)));
  }, []);

  return (
    <main style={{ padding: 32 }}>
      <h1 style={{ fontWeight: 500, letterSpacing: -0.5 }}>Corder</h1>
      <p style={{ opacity: 0.6 }}>Plan 1 skeleton. Server is up if you see this.</p>
      {error ? (
        <pre style={{ color: "#f88" }}>error: {error}</pre>
      ) : (
        <pre style={{ background: "#111", padding: 16, borderRadius: 8 }}>
          {JSON.stringify(meetings, null, 2)}
        </pre>
      )}
    </main>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
