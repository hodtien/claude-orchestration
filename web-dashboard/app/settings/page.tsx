"use client";

import { useState } from "react";
import "./settings.css";
import { ModelsTab } from "./ModelsTab";
import { RoutingTab } from "./RoutingTab";
import { AgentsTab } from "./AgentsTab";

type Tab = "models" | "routing" | "agents";

const TABS: { id: Tab; label: string }[] = [
  { id: "models", label: "Models" },
  { id: "routing", label: "Routing" },
  { id: "agents", label: "Agents" },
];

export default function SettingsPage() {
  const [active, setActive] = useState<Tab>("models");

  return (
    <div className="settings-page">
      <div className="settings-header">
        <h1>Settings</h1>
        <p className="settings-subtitle">Model &amp; Agent Configuration</p>
      </div>

      <div className="tabs-bar">
        {TABS.map((t) => (
          <button
            key={t.id}
            className="tab-btn"
            data-active={active === t.id}
            onClick={() => setActive(t.id)}
          >
            {t.label}
          </button>
        ))}
      </div>

      {active === "models" && <ModelsTab />}
      {active === "routing" && <RoutingTab />}
      {active === "agents" && <AgentsTab />}
    </div>
  );
}
