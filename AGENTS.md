# Agent guide for Stexx

## Privacy

- Commit and push only as the Stexx identity: `Stexx <358030352+stexxapp@users.noreply.github.com>`. Set it per repo (`git config user.name` / `user.email`) before your first commit.
- Never put a real name, personal email, home location, or personal account handle in code, commits, PRs, screenshots, or seed data.

## Pull requests

Every PR follows [`.github/pull_request_template.md`](.github/pull_request_template.md): a short visible summary and screenshots, with everything else folded into a `<details>` accordion.

- **Summary:** one present-tense sentence saying what the PR does, then 2–5 one-line bullets, each a thing and what it now does. No file paths or type names in the visible part.
- **⚠️ bullets stay visible:** migrations, manual steps before or after merge, reverts a plain `git revert` doesn't undo, and any risk to privacy, location, auth, payments or user data. Never hide these inside `<details>`.
- **Screenshots of every changed screen and state:** they let a reviewer check the change without building the branch.
  - List the states before you shoot: empty vs populated, loading, error, signed out vs signed in, free vs Stexx+, light vs dark if it differs, and any branch your diff adds a conditional for.
  - Use real seeded data from the mock or dev API, not hand-forced view state.
  - Every caption makes a checkable claim about what the image proves. A shot without a claim is decoration.
  - Before/after pairs only for changes to existing UI, with identical device, screen and data. Brand-new UI gets plain shots.
  - Say what you couldn't capture and why. An honest gap beats a mislabelled image.
  - Layout is a full-width captioned sequence, caption then image. If it runs long, cut shots that don't prove something rather than compacting. Three strong shots beat six weak ones.
  - Capture from the simulator at full resolution: `xcrun simctl io booted screenshot shot.png` (iPhone 17 Pro). Never publish a downscaled preview. Look at each PNG before publishing.
  - Upload with `gh pr edit <N> --body-file body.md --attach` (gh ≥ 2.99), which hosts images on GitHub and commits nothing to the repo.
- **Details accordion:** What changed (per area, with paths), Testing (named commands, not "tests pass"), Risk (what could break, what wasn't tested), and How to revert.
