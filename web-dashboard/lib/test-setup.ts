import { mkdtempSync } from "node:fs";
import path from "node:path";
import os from "node:os";

const dir = mkdtempSync(path.join(os.tmpdir(), "pipe-test-"));
process.env.ORCH_PIPELINES_DIR = dir;
process.env.__PIPE_TEST_DIR = dir;
