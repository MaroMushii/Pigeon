const REPO = "MaroMushii/Pigeon";
const WORKFLOW = "mirror.yml";
const REF = "main";

interface Env {
  GITHUB_TOKEN: string;
}

export default {
  async scheduled(_event, env, _ctx): Promise<void> {
    const url = `https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW}/dispatches`;

    const response = await fetch(url, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${env.GITHUB_TOKEN}`,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "pigeon-mirror-dispatcher",
      },
      body: JSON.stringify({ ref: REF }),
      signal: AbortSignal.timeout(10_000),
    });

    if (!response.ok) {
      const body = await response.text();
      throw new Error(
        `dispatch failed: ${response.status} ${response.statusText} <${body}>`
      );
    }

    console.log(
      `dispatched ${WORKFLOW} on <${REPO}@${REF}> at <${new Date().toISOString()}>`
    );
  },
} satisfies ExportedHandler<Env>;
