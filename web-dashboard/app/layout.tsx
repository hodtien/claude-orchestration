import type { Metadata } from "next";
import "./globals.css";
import "./nav.css";
import { ModelConfigProvider } from "../lib/use-model-config";
import Sidebar from "../components/Sidebar";

export const metadata: Metadata = {
  title: "Claude Orchestration",
  description: "Live observability for the multi-agent orchestrator"
};

export default function RootLayout({
  children
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>
        <ModelConfigProvider>
          <div className="layout-wrapper">
            <Sidebar />
            <div className="main-content">{children}</div>
          </div>
        </ModelConfigProvider>
      </body>
    </html>
  );
}
