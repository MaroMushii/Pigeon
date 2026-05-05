/**
 * Local sanity test for the parser. Feeds a captured t.me/s/<channel>
 * HTML fixture through `parseChannelPage` and prints a digested view of
 * the resulting `Snapshot`. Run with:
 *
 *   pnpm exec tsx dry-run.ts <path-to-fixture.html> <fallback-username>
 *
 * Or with a default fixture against the live `t.me` page:
 *
 *   pnpm exec tsx dry-run.ts --live durov
 */

import { readFileSync, writeFileSync } from "node:fs";
import { parseChannelPage } from "./parser.js";

async function main() {
  const args = process.argv.slice(2);
  if (args[0] === "--live") {
    const username = args[1] ?? "durov";
    const url = `https://t.me/s/${username}`;
    process.stderr.write(`fetching ${url}\n`);
    const res = await fetch(url, {
      headers: {
        "User-Agent":
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
      },
    });
    if (!res.ok) {
      process.stderr.write(`fetch failed: HTTP ${res.status}\n`);
      process.exit(1);
    }
    const html = await res.text();
    writeFileSync("/tmp/dry-run-fixture.html", html);
    process.stderr.write(`saved fixture to /tmp/dry-run-fixture.html (${html.length} bytes)\n`);
    runOnHTML(html, username);
    return;
  }

  const path = args[0];
  const username = args[1] ?? "unknown";
  if (!path) {
    process.stderr.write("usage: dry-run.ts <fixture.html> <fallback-username>\n");
    process.stderr.write("       dry-run.ts --live <username>\n");
    process.exit(1);
  }
  const html = readFileSync(path, "utf8");
  await runOnHTML(html, username);
}

function runOnHTML(html: string, username: string) {
  const snap = parseChannelPage(html, username);
  process.stderr.write("\n=== summary ===\n");
  process.stderr.write(
    `channel: ${snap.channel.title} (@${snap.channel.username})\n`
  );
  process.stderr.write(`  photo:        ${snap.channel.photo_url ?? "(none)"}\n`);
  process.stderr.write(`  subscribers:  ${snap.channel.subscriber_count ?? "(none)"}\n`);
  process.stderr.write(`  description:  ${(snap.channel.description_html ?? "").slice(0, 80)}…\n`);
  process.stderr.write(`posts: ${snap.posts.length}\n`);
  for (const p of snap.posts.slice(0, 3)) {
    process.stderr.write(`  - ${p.id}\n`);
    process.stderr.write(`      author:    ${p.author_name}\n`);
    process.stderr.write(`      posted:    ${p.posted_at ?? "(unknown)"}\n`);
    process.stderr.write(`      views:     ${p.views_label ?? "(none)"}\n`);
    process.stderr.write(`      media:     ${p.media.length}  reactions: ${p.reactions.length}\n`);
    process.stderr.write(`      plain:     ${p.plain_text.slice(0, 80)}…\n`);
  }
  process.stderr.write("\n=== first post (full JSON) ===\n");
  process.stdout.write(JSON.stringify(snap.posts[0], null, 2) + "\n");
}

main().catch((e) => {
  process.stderr.write(`failed: ${e?.stack ?? e}\n`);
  process.exit(1);
});
