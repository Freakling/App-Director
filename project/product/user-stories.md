# User stories: {{APP_NAME}}

The roles the app serves, and why each feature is built: the value for each role, the roles, and one table of stories per area. Every feature item in `TASKS.md` names the stories it serves (`Stories:`). The AI drafts stories; the director confirms them.

**Next ID:** US-6 · **Last validated:** never

<!-- How this file works (.app-director/procedures/design.md › User stories):
     - A story is one thing a role does and why, in the role's words: "As a <role> I <do something>, so <why>". It never says how it's built.
     - Confirmed: the date the director last confirmed the story as it reads now, or `unconfirmed` (drafted, not confirmed yet).
     - Next ID: the ID the next story gets; bump it. IDs are never reused: a dropped story's row is deleted.
     - Last validated: `never`, or the date and commit of the last validation, such as 2026-11-14 at `4e1f0c2`.
       /next-task proposes the next one after [stories] every built items (tools/check.cfg).
     The roles and stories below are a worked example, a small book club app. Onboarding replaces them with this app's own. -->

## The value in one paragraph per role

- **Member:** one place for the club. You see when and where the next meeting is and which book it's about, say whether you're coming, and have a say in the next book, without scrolling back through a group chat.
- **Organiser:** schedule a meeting once and every member is told, see who's coming, and run the vote on the next book without counting replies by hand.

## Roles

- **Member:** anyone in the club, signed in with their email.
- **Organiser:** a member who runs the meetings; a club can have more than one.

## Meetings

| ID | Story | Confirmed |
|---|---|---|
| US-1 | As a member I see the next meeting's date, place and book when I open the app, so I never miss one. | 2026-11-01 |
| US-2 | As a member I say whether I'm coming with one tap, so the organiser knows how many to expect. | 2026-11-01 |
| US-3 | As an organiser I schedule a meeting and every member is told, so I don't have to message each of them. | unconfirmed |

## Choosing the next book

| ID | Story | Confirmed |
|---|---|---|
| US-4 | As a member I suggest a book with a short reason, so the club picks from what members want to read. | 2026-11-01 |
| US-5 | As an organiser I close the vote and announce the winning book, so the choice is fair and final. | unconfirmed |
