import { renameSync, writeFileSync } from "node:fs";

/**
 * Write content atomically: write to a `.tmp` sibling then rename into
 * place. A mid-write SIGTERM (CI cancellation, OOM) then leaves either the
 * old file or a complete new file on disk — never a truncated file that
 * would break signature verification downstream.
 */
export function atomicWriteFile(path: string, content: string | Buffer): void {
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, content);
  renameSync(tmp, path);
}
