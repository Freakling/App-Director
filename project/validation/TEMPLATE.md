# Acceptance check

<!-- Onboarding replaces {{FLOW_N}} sections with one section per core flow from the brief
     (usually 3-5 flows). Keep the fixed descriptions' wording stable: changing it makes
     earlier results incomparable. Keep the sections after the flows as they are. -->

- **Date:**
- **Tester:**
- **Build:** <!-- git rev-parse --short HEAD -->
- **Environment** (local / staging / prod):
- **Flows checked:** [ ] {{FLOW_1}} · [ ] {{FLOW_2}}

This is about whether each built behaviour works in the running app, not whether features exist. Tick one box per item. Write what went wrong in Notes; leave both empty if you didn't check it.

---

## {{FLOW_1}}

<!-- Replace with the flow's name. Write one item per built outcome in this flow. -->

- **{{OUTCOME_1_1}}** *How: {{HOW_TO_VERIFY}}*
  - [ ] Works   - [ ] Broken / missing
  - Notes:

- **{{OUTCOME_1_2}}** *How: {{HOW_TO_VERIFY}}*
  - [ ] Works   - [ ] Broken / missing
  - Notes:

## {{FLOW_2}}

- **{{OUTCOME_2_1}}** *How: {{HOW_TO_VERIFY}}*
  - [ ] Works   - [ ] Broken / missing
  - Notes:

---

## Bugs

One block per bug you noticed that isn't already an item above. Copy as often as you need.

**Bug:** (one line: what's wrong)
- **Where:** (screen or flow)
- **Steps:**
- **Expected:**
- **Actual:**
- **How often:** always / sometimes / once
- **Severity:** high (data lost, core flow blocked, crash) / med (wrong but workable) / low (cosmetic)

**Might be a bug, might be intended:**
-

## Free-Format Comments

Anything else: ideas, friction you felt, things that seemed off, features you wished for.
