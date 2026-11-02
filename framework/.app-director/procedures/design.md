<!-- App Director · framework-owned: replaced on upgrade. -->
# Design session

Brainstorm a topic, answer open design questions, change how part of the app works, validate the user stories (Validate the stories, below), or harvest a prototype (Harvest a prototype, below). Write down only what the human decides. Your job is to make the human's decisions fast and well informed, never to make them.

## Prepare
- Read brief › Open Questions and the brief sections the topic touches, and the related lines in `product/decisions.md`. Don't re-propose something decided against there without saying what has changed since.
- Read the stories in `product/user-stories.md` for the roles and areas the topic touches (`grep -n "^## " product/user-stories.md` lists the areas).
- List `product/research/` for notes on the topic. A note whose Verified as of date is recent enough for its claims is evidence you can use; research only what has changed since.
- **Ranking the open questions** (no topic, or "which questions block development?"): order them by what they unblock in TASKS.md:
  1. a question blocking a ready item;
  2. one that would cause rework if answered later;
  3. one that gates a placeholder value;
  4. long-term questions.

  Give a one-line reason for each position.
- **Show the context to the human before presenting options.** Quote or paraphrase the brief sections that the topic touches (keep it short; skip sections with no bearing), and list the stories it touches by ID and text. Then list the related lines from `product/decisions.md` verbatim. Add the research on file for the topic: path, conclusion and Verified as of date. If there is nothing relevant in these files, say so in one sentence. This gives the director the existing state of play before any options appear.

## For each question
1. **Research first when the options depend on facts you don't have,** or when the human asks for it, such as which library fits, what a licence allows, or what an app store requires.
   - A single fact one source settles (a version, a licence, a limit) you may check yourself. Anything larger goes to the `researcher`, as `research.md` › Starting research describes, so this session's context stays small.
   - The result is a note in `product/research/` and a done `R<n>` item. Tell the human where the researcher's assumptions are, since those are the first thing to check.
   - The researcher's recommendation is one option, shown with its reason like any other. It informs; the human decides.
2. Offer 2-4 concrete options. For each: what the user experiences, what it would take to build (which systems in AGENTS.md › Architecture), and how it fits the product goals. Name the stories it serves, and draft the new or changed stories it needs (User stories, below), so the human confirms them with the option.
   Where an option touches security (input, authentication, authorization, sessions, secrets, data access, file or network access, dependencies), state its effect on the OWASP baseline in `rules.md` › Architecture defaults: the item it touches (such as Broken Access Control) and whether it meets, strengthens or would deviate from it. An option that would deviate is shown with the accepted decision it needs, and never recommended without saying so.
3. Recommend one, with a one-line reason.
4. Wait for the human. If they answer only part, record only that part. If you had to interpret the answer, write down your reading and ask them to confirm it.

## Record each decision in one change
1. **brief:** write the rule into its section as the current design, replacing any text it supersedes. A new area gets a new subsection.
2. **`product/decisions.md`:** append one line in the format given at the top of that file. When the decision followed research, end the `why` with the note's path, as in `why (research: product/research/<note>.md)`, so later sessions reuse the evidence instead of redoing it.
3. **brief › Open Questions:** delete the answered question. Follow-up questions become new open questions (bump the counter in the brief's Open Questions section).
4. **`product/user-stories.md`:** the chosen option's stories. Each one the human confirmed is dated today: a new one gets the next ID from the header (then bump it), a changed one is rewritten in place, and a dropped one is deleted. A drafted story they didn't answer goes in as `unconfirmed`.
5. **TASKS.md:** add or change the items the decision creates, in the format in `.app-director/tasks.md`. Plan a big rework in stages.
   - Give each new item a Size, `Depends on`, `Touches`, `Done when` with tags, a `Brief:` heading and its `Stories:`.
   - A `done` item the decision changes gets a new item; don't reopen it.
   - Leave `in-progress` items alone and tell the human about them, since another session may be working on them.
   - Suggest reorders; don't make them.
6. **Numbers and thresholds** stay placeholders. Say what a value is for and how it should feel; the human sets it in config or environment variables.
7. **Layout:** where things sit on a screen goes to `ui-design.md`. A design session settles what a screen is for, not where its elements are.

## Finish
- Summarise what was decided, what's still open, and the next most useful question.
- Commit the product files as `docs: <summary>`, with a body listing the decisions, after the human approves (see `rules.md` › Git). The session's research notes and `R<n>` items go in the same commit. A design session doesn't edit source code.
- After the commit, suggest `/clear` (or starting a fresh session) before the next topic. The brief, decisions.md, the stories and TASKS.md hold everything; the conversation history no longer adds value and only grows the context.

## User stories
`product/user-stories.md` says which roles the app serves, and why each feature is built: the value for each role in one paragraph, the roles, and one table of stories per area, each with its ID, the story and the date the human confirmed it. You draft stories; only the human confirms them.
- **A story** is one thing a role does and why, in the role's words: "As a <role> I <do something>, so <why>". It names no screen, technology or implementation. Its role is one in Roles; a new role is added there, and its value paragraph with it.
- **New and changed stories** come from a design (For each question), from onboarding, or from a feature item that has none. A new one gets the next ID from the file's header, which you then bump; IDs are never reused. Until the human confirms it, its Confirmed column says `unconfirmed`.
- **A feature item with no story** (no `Stories:` line, or `-` while it changes what a user can do): draft the story it serves, add it `unconfirmed`, and set the item's `Stories:`. Name it in your report so the human can confirm it; a run of several items doesn't stop for it.
- **Confirmed** is the date the human last confirmed the story as it reads now: in a design, a validation or an acceptance check (`acceptance.md`).

### Validate the stories
`next-task.md` proposes this when `bash tools/stories.sh --due` says it's due: never validated, or `tools/check.cfg` › `[stories] every` built items (10 by default) since the commit on the file's Last validated line. It also runs on request.
1. **Collect.** The stories the items built since that commit serve: `git log --format=%s <commit>..HEAD` lists the items (subjects ending in `(T<n>)` or `(B<n>)`, or that and a squash merge's ` (#<pr>)`), and their `Stories:` lines name the stories. When the commit isn't in this history, or the line names none, use `git log --format=%s --since=<date>` instead. Add every story still `unconfirmed`. With Last validated `never`, take every story.
2. **Ask.** Show each story with the items that serve it, grouped by area, and ask the human to confirm, correct or drop it:
   - **confirm:** its Confirmed becomes today's date;
   - **correct:** write the new wording and date it. If you had to interpret the answer, show your reading and keep it `unconfirmed` until they confirm it. A correction that means the built behaviour is wrong is a design question: offer options as For each question says, or add an Open Question;
   - **drop:** delete its row. A `todo` item that names it goes to the human, who decides whether it's still needed.

   A story the human doesn't answer stays as it is; an unconfirmed one comes back next time.
3. **Record.** Set the header's Last validated to today and `git rev-parse --short HEAD`, as in ``**Last validated:** 2026-11-14 at `4e1f0c2` ``. Commit `product/user-stories.md` (and any items or Open Questions it changed) as `docs: validate the user stories`, after the human approves.

## Harvest a prototype
`prototype.md` › Harvest brings a prototype here: its notes (`PROTOTYPE.md`: what was tried, how it felt, what to keep) and its diff against main. It shows how a change feels; it decides nothing, and its code is never merged or cherry-picked.
1. **Context.** Show the notes in the human's words, then what the prototype changes as a user would see it, area by area from the diff rather than the code, with the brief sections, stories and decisions it touches, as Prepare says. Name what it skipped that a real build needs: tests, the layers in `rules.md` › Architecture defaults, and anything the OWASP baseline asks.
2. **Options,** as For each question says. They are usually to build it as tried, a variant the notes point to, or to leave it, and each says what it would take to build from main.
3. **Record** what the human chooses, as Record each decision says, naming the prototype in each: the decision's `why` ends with `(prototype: proto/<name>)`; a story it adds or changes gets the line `US-<n> came from the prototype proto/<name> on <date>.` under its area's table; and each item gets `- Prototype: proto/<name>` (`.app-director/tasks.md`). The items are built from main like any other, with the check and reviews. Nothing is filed without the human's answer: a part they don't answer stays out, and leaving the prototype files nothing. Unlike Record step 4, a drafted story the human doesn't answer stays out too. Commit as Finish says, as `docs: harvest the <name> prototype`.
