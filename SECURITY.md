# Security policy

Pigeon ships to people on filtered networks where reliability and
privacy are load-bearing. If you find a vulnerability — especially
one that could leak a user's identity, traffic, or location — please
report it privately rather than opening a public issue.

## Reporting a vulnerability

Use GitHub's private security advisory feature for this repo:

**https://github.com/MaroMushii/Pigeon/security/advisories/new**

Reports go to the maintainer only. Nothing becomes public until a fix
is shipped and the advisory is published.

If for some reason that flow is unavailable, open an issue describing
the problem in non-exploitable terms and ask for a private channel —
do not paste an exploit into a public issue.

## Scope

In scope:

- The macOS app under `mac/`.
- The mirror scraper and CI workflow under `mirror/` and
  `.github/workflows/`.
- Anything that could leak a user's IP, traffic patterns, or
  channel-list to Telegram's servers or to a network observer
  positioned between the user and the mirror.

Out of scope:

- Issues with `t.me` itself, Telegram's CDN, or Google's translate
  proxy. Pigeon doesn't own those.
- Channel content moderation. Pigeon is a reader; what's published on
  Telegram channels is moderated by Telegram, not by this project.
