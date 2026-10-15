<!-- App Director · framework-owned: replaced on upgrade. -->
# Research domain: apps

Read this when the question concerns a stack, a library or tool, a licence, or what an app store or platform requires. It adds to `procedures/research.md` and never repeats it. A question outside this domain stays technology-neutral, and every option gets the same evidence standard.

## Stacks and libraries
- The project's stack in AGENTS.md › Project facts is the starting point. Cover the stacks App Director supports (TypeScript, Flutter, Python), and say so when a question goes beyond them.
- Judge a library or tool on:
  - maturity, release cadence and the date of its last release;
  - how actively it is maintained, and by whom;
  - known security advisories;
  - its licence, and whether that fits how the app is distributed;
  - platform and runtime support, for the versions the project uses;
  - size and cost to adopt;
  - how well it fits the project's check and structure rules (`tools/check.cfg`, the UI, logic and data layers in `rules.md` › Architecture defaults).
- Take versions, release dates and advisories from the registry entry, the release notes or the repository you inspected, and give the version a claim applies to.

## Licences
- Read the licence from the licence file or the registry entry you actually inspected, with the version the claim applies to. A README badge or a search preview is not the licence.
- Include attribution and notice duties, and whether the licence allows the way the app is distributed.

## App-store and platform requirements
- Cover the store and platform terms the app must meet to be published: review guidelines, privacy and data declarations, target platform levels and signing.
- Read them from the store's current published text and give its date or version. They are Tier 1 binding requirements.
- This is technical guidance, not legal advice. Name what needs confirmation from the people who own the legal, privacy or publishing side.
