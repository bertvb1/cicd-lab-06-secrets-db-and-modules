# Course feedback — Lab 06 (secrets, db and modules)

_From: Bert (bert.vanboven@mustrysolutions.com) — 2026-07-22_

## Setup assumes Lab 04 was completed

The setup instructions say to paste "the token you created in Lab 04"
(`RUNNER_GITHUB_PAT` in `.env`). I did this lab standalone without having done
Lab 04, so I had no token to reuse and it wasn't obvious that this is just a
regular GitHub Personal Access Token (classic, `repo` scope) that anyone can
create fresh in a couple of minutes.

**Suggestion:** if labs can be done separately, lead with the standalone
instructions ("create a PAT at github.com/settings/tokens → classic → tick
`repo`") and mention reusing the Lab 04 token as the shortcut — rather than
the other way around. A one-line note like "didn't do Lab 04? No problem,
just create a new token" in the README prerequisites would have saved the
confusion.
