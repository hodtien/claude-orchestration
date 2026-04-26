import type { Metadata } from "next";
import "./globals.css";

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
      <body>{children}</body>
    </html>
  );
}
