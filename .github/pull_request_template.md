<!--
Keep the visible part short: a reviewer should get the change from the Summary and screenshots alone.
Everything a reviewer only needs when going deep goes inside <details>.

Anything that would make a reviewer act differently stays visible as a "⚠️" bullet,
never only inside <details>: a database migration, a revert that a plain `git revert`
doesn't undo, a manual step before or after merge (App Store Connect, server env, DNS),
or a risk to privacy, location, auth, payments or user data.
-->

### Summary

<!-- One sentence that starts with a present-tense verb and says what the PR does,
e.g. "Adds a live chat thread backed by the new messages API." -->

<!-- 2–5 bullets, one line each: a thing and what it now does.
No file paths or type names here; those go in Details. -->

-
-

<!-- Closes #123. -->

### Screenshots

<!-- One captioned screenshot per changed screen or state, full width, caption above the image.
Each caption makes a checkable claim, e.g. "**Empty inbox**: shows the glass empty state instead of a blank list."
Before/after pairs only for changes to existing UI. Say what you couldn't capture and why. -->

<details>
<summary><h3>Details: what changed, testing, risk, how to revert</h3></summary>

### What changed

<!-- The how and why, per area (iOS, server, docs), with paths. -->

### Testing

<!-- What you ran and what you checked, with the commands: xcodebuild test, server tests,
a manual pass in the simulator or on device. "Tests pass" with no named command doesn't count. -->

### Risk

<!-- What could break and who would notice: screens, endpoints, migrations, privacy surfaces
(location fuzzing, photo sanitizing, session storage), and what was not tested. -->

### How to revert

<!-- Is a plain `git revert` enough? Name anything a revert leaves behind. -->

</details>
