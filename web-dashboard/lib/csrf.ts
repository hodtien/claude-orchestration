import { NextResponse } from "next/server";

// Same-origin guard for state-changing handlers.
// Why: dashboard runs locally without auth; without this, any page in the
// browser can issue cross-origin POST/PATCH/PUT/DELETE that mutates config.
// How to apply: call at the top of every mutating handler. Returns null when
// allowed, NextResponse(403) when rejected.
export function assertSameOrigin(req: Request): NextResponse | null {
  const host = req.headers.get("host");
  if (!host) {
    return NextResponse.json(
      { success: false, error: "missing host header" },
      { status: 403 }
    );
  }
  const origin = req.headers.get("origin");
  const referer = req.headers.get("referer");
  const source = origin ?? referer;
  if (!source) {
    return NextResponse.json(
      { success: false, error: "missing origin/referer" },
      { status: 403 }
    );
  }
  let sourceHost: string;
  try {
    sourceHost = new URL(source).host;
  } catch {
    return NextResponse.json(
      { success: false, error: "invalid origin/referer" },
      { status: 403 }
    );
  }
  if (sourceHost !== host) {
    return NextResponse.json(
      { success: false, error: "cross-origin request rejected" },
      { status: 403 }
    );
  }
  return null;
}
