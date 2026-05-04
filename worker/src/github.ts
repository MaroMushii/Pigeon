/**
 * Tiny wrapper around the GitHub Contents API. We do one PUT per channel
 * whose snapshot has actually changed (content-hash diffed). Contents API
 * is rate-limited to 5000/hr per token; at 16 channels every 2 minutes
 * this is comfortably under the ceiling even before the no-op skip.
 */

const GITHUB_API = "https://api.github.com";

export interface RepoCoords {
  owner: string;
  repo: string;
  branch: string;
  token: string;
}

export interface ExistingFile {
  sha: string;
  contentBase64: string;
  decodedSize: number;
}

export async function fetchFile(
  coords: RepoCoords,
  path: string
): Promise<ExistingFile | null> {
  const url = `${GITHUB_API}/repos/${coords.owner}/${coords.repo}/contents/${encodeURIComponent(
    path
  )}?ref=${encodeURIComponent(coords.branch)}`;

  const res = await fetch(url, { headers: ghHeaders(coords.token) });
  if (res.status === 404) return null;
  if (!res.ok) {
    throw new Error(`GH GET ${path} failed: ${res.status} ${await res.text()}`);
  }
  const json = (await res.json()) as {
    sha: string;
    content: string;
    size: number;
  };
  return {
    sha: json.sha,
    contentBase64: json.content.replaceAll("\n", ""),
    decodedSize: json.size,
  };
}

export async function fetchRawFile(
  coords: RepoCoords,
  path: string
): Promise<string | null> {
  const url = `https://raw.githubusercontent.com/${coords.owner}/${coords.repo}/${coords.branch}/${path}`;
  const res = await fetch(url, { headers: { "User-Agent": "pigeon-mirror" } });
  if (res.status === 404) return null;
  if (!res.ok) {
    throw new Error(`GH raw ${path} failed: ${res.status}`);
  }
  return await res.text();
}

export async function putFile(
  coords: RepoCoords,
  path: string,
  contents: string,
  message: string,
  existingSHA: string | undefined
): Promise<void> {
  const url = `${GITHUB_API}/repos/${coords.owner}/${coords.repo}/contents/${encodeURIComponent(
    path
  )}`;
  const body: Record<string, unknown> = {
    message,
    branch: coords.branch,
    content: btoa(unescape(encodeURIComponent(contents))),
  };
  if (existingSHA) body.sha = existingSHA;

  const res = await fetch(url, {
    method: "PUT",
    headers: { ...ghHeaders(coords.token), "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    throw new Error(`GH PUT ${path} failed: ${res.status} ${await res.text()}`);
  }
}

function ghHeaders(token: string): Record<string, string> {
  return {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "pigeon-mirror",
  };
}

/** SHA-256 hex digest, used to skip no-op commits. */
export async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
