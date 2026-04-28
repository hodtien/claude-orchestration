"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from "react";

export interface ModelView {
  id: string;
  channel: string;
  tier?: string;
  cost_hint?: string;
  strengths?: string[];
  note?: string;
  inSettingsAllowlist: boolean;
  isDefault: boolean;
}

export interface ModelConfig {
  models: ModelView[];
  defaultModel: string | undefined;
  allowlist: string[];
}

interface ModelConfigContextValue {
  config: ModelConfig | null;
  loading: boolean;
  error: string | null;
  refresh: () => Promise<void>;
}

const ModelConfigContext = createContext<ModelConfigContextValue | null>(null);

const CHANNEL_NAME = "config:models";

async function fetchModelConfig(): Promise<ModelConfig> {
  const res = await fetch("/api/config/models", { cache: "no-store" });
  if (!res.ok) throw new Error(`Failed to load model config: ${res.status}`);
  const json = await res.json();
  if (!json.success) throw new Error(json.error ?? "Unknown error");
  return json.data as ModelConfig;
}

export function ModelConfigProvider({ children }: { children: ReactNode }) {
  const [config, setConfig] = useState<ModelConfig | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const data = await fetchModelConfig();
      setConfig(data);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Failed to load config";
      setError(msg);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  useEffect(() => {
    if (typeof BroadcastChannel === "undefined") return;
    const bc = new BroadcastChannel(CHANNEL_NAME);
    bc.onmessage = () => {
      refresh();
    };
    return () => bc.close();
  }, [refresh]);

  return (
    <ModelConfigContext.Provider value={{ config, loading, error, refresh }}>
      {children}
    </ModelConfigContext.Provider>
  );
}

export function useModelConfig(): ModelConfigContextValue {
  const ctx = useContext(ModelConfigContext);
  if (!ctx) {
    throw new Error("useModelConfig must be used within ModelConfigProvider");
  }
  return ctx;
}

export function broadcastConfigChange(): void {
  if (typeof BroadcastChannel === "undefined") return;
  const bc = new BroadcastChannel(CHANNEL_NAME);
  bc.postMessage({ type: "invalidate" });
  bc.close();
}
