# Security policy

Sandglass runs with Accessibility and Automation permissions on the user's Mac, so a flaw in it
can matter even though it has no network code.

## Reporting a vulnerability

Please report security issues **privately** through GitHub:
[Report a vulnerability](https://github.com/moritzthln/sandglass/security/advisories/new)
(the repository's *Security* tab → *Report a vulnerability*). Do not open a public issue for it.

Include the Sandglass version, your macOS version and chip, and the steps to reproduce. You can
expect a first answer within a week.

## What counts

- Anything that lets another app or a web page make Sandglass act on its behalf (for example
  through the block page's query string, or the AppleScript it sends to browsers).
- Anything that reads, writes or leaks data outside `~/Library/Application Support/Sandglass`
  and the agent plist.

Getting around a block on your own Mac is not a vulnerability: Sandglass is friction you chose,
and the README says plainly that a determined user can turn it off.

## Supported versions

Only the latest release receives fixes.
