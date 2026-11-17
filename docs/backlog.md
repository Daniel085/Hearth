# Backlog

Ideas worth building, not yet scheduled. Each entry says why it matters, where the data
could come from, and what to watch out for.

## Family dates: partner and children's birthdays, baby due dates

**Why:** The moments people most regret missing are often not the friend's own birthday
but their child's first birthday, their partner's birthday, or the week the baby is
due. "Sam's daughter turns 5 on Saturday" is a warmer reason to reach out than "you
haven't talked in 40 days", and it's exactly the kind of reason the Launchpad is built
to surface.

**What exists today:** Each person's own birthday is stored (`CDPerson.birthday`), read
from Contacts or entered by hand, and drives a Launchpad signal that spikes as the day
approaches (`RelationshipScoring`).

**Where the data could come from:**

| Data | Source | Notes |
|---|---|---|
| Partner's and children's names | Contacts: the *person's* card can list relations ("spouse: Tom", "child: Ava") via `contactRelations` | Many cards won't have these filled in |
| Their birthdays | The related person's own contact card, if one exists and the name matches | Matching by name is fuzzy; ask the user to confirm the link |
| Anniversaries and other dates | Contacts `dates` field (labelled dates like "anniversary") | Already on the card; just unread |
| Baby due dates | Entered by the user | There's no reliable source; don't infer it |
| Any of the above | Entered by the user on the person's detail screen | Always available as the fallback |

**Hearth Spark** could pick these up on the Mac too: when a contact card lists a spouse
or child, include their names and birthdays in the Spark file. That would need its own
line in the review screen, so the user sees exactly which family dates are being sent.

**Shape of the feature:**

- A person gains "people around them": partner and children, each with a name and an
  optional date, and a label ("birthday", "due date", "anniversary").
- These are not Hearth people of their own and don't get their own cadence. They're
  reasons to contact the person they belong to.
- New Launchpad reasons, worded around the relationship: "Ava (Sam's daughter) turns 5
  on Saturday", "Priya's baby is due in two weeks".
- A due date should turn into a birthday once the baby arrives, prompted gently rather
  than assumed.

**Watch out for:**

- **Sensitivity.** A pregnancy is information people share selectively, and pregnancies
  don't always end in a birth. Due dates must be entered by the user, stay on the
  device, never be inferred, and be easy to remove. Reminder wording should stay
  neutral, and an expired due date should quietly ask the user what to do rather than
  announce anything.
- **Data model.** This needs a new entity (for example, `CDPersonDate`, owned by
  `CDPerson`) and a schema bump, so `HearthModel.currentVersion` goes to 3 with the
  same explicit migration as version 2.
- **Ages.** Showing "turns 5" needs a birth year. Contacts often omits it, so the text
  has to work without one ("Ava's birthday is Saturday").
