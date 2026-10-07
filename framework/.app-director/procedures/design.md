<!-- App Director · framework-owned: replaced on upgrade. -->
# Design session

Brainstorm a topic, answer open design questions, or change how part of the app works. Write down only what the human decides. Your job is to make the human's decisions fast and well informed, never to make them.

## Prepare
- Read brief › Open Questions and the brief sections the topic touches, and the related lines in `product/decisions.md`. Don't re-propose something decided against there without saying what has changed since.
- **Ranking the open questions** (no topic, or "which questions block development?"): order them by what they unblock in TASKS.md:
  1. a question blocking a ready item;
  2. one that would cause rework if answered later;
  3. one that gates a placeholder value;
  4. long-term questions.

  Give a one-line reason for each position.

## For each question
1. Offer 2-4 concrete options. For each: what the user experiences, what it would take to build (which systems in AGENTS.md › Architecture), and how it fits the product goals.
2. Recommend one, with a one-line reason.
3. Wait for the human. If they answer only part, record only that part. If you had to interpret the answer, write down your reading and ask them to confirm it.

## Record each decision in one change
1. **brief:** write the rule into its section as the current design, replacing any text it supersedes. A new area gets a new subsection.
2. **`product/decisions.md`:** append one line in the format given at the top of that file.
3. **brief › Open Questions:** delete the answered question. Follow-up questions become new open questions (bump the counter in the brief's Open Questions section).
4. **TASKS.md:** add or change the items the decision creates, in the format in `.app-director/tasks.md`. Plan a big rework in stages.
   - Give each new item a Size, `Depends on`, `Touches`, `Done when` with tags, and a `Brief:` heading.
   - A `done` item the decision changes gets a new item; don't reopen it.
   - Leave `in-progress` items alone and tell the human about them, since another session may be working on them.
   - Suggest reorders; don't make them.
5. **Numbers and thresholds** stay placeholders. Say what a value is for and how it should feel; the human sets it in config or environment variables.

## Finish
- Summarise what was decided, what's still open, and the next most useful question.
- Commit the product files as `docs: <summary>`, with a body listing the decisions, after the human approves (see `rules.md` › Git). A design session doesn't edit source code.
- After the commit, suggest `/clear` (or starting a fresh session) before the next topic. The brief, decisions.md and TASKS.md hold everything; the conversation history no longer adds value and only grows the context.
