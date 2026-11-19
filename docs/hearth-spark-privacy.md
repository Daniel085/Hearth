# Hearth Spark: what it reads, sends and keeps

**Status:** Prototype Mac app and command-line tool in [`mac/HearthSpark`](../mac/HearthSpark),
and the import in the Hearth iOS app.

## The promise

This is the wording on the app's welcome screen:

> Hearth Spark looks at your contacts, messages, calls and email on this Mac — and your
> LinkedIn export, if you add it — to recommend the people to keep close in Hearth.
>
> - **Stays on your Mac.** Everything is processed here. Nothing is ever sent to a
>   server — Hearth Spark doesn't use the internet at all.
> - **Who and when, never what.** It sees who you message, call and email, and when. It
>   never reads what was said.
> - **Nothing hidden.** You review everything it found, and choose who's included,
>   before anything goes to Hearth.
> - **Nothing kept.** No data is saved except the file you choose to send. At the end,
>   it shows you exactly what's left.

Every rule below exists to make that sentence literally true, and most are enforced by
tests rather than by good intentions.

## Why a Mac at all

iOS gives apps no access to Messages or call history — the two strongest signals of who
someone is close to. macOS does, to an app the user grants Full Disk Access. See the
research summary in the conversation that led here, and
[people-album-access.md](./people-album-access.md) for the Photos side.

## What is read

Contacts is always read. Messages, Call history and Mail each have an on/off switch on
the first screen (`--no-messages`, `--no-calls`, `--no-mail` on the command line).
LinkedIn is off until you switch it on and choose your unzipped LinkedIn data export
(`--linkedin FOLDER`); Hearth Spark never signs in to LinkedIn. A
source that's switched off is never opened, and a test checks that its reader is never
called. With all three off, Full Disk Access isn't needed at all.

Mail means Apple Mail only. Webmail such as Gmail in a browser has nothing on the Mac to
read, and fetching it would need the network, which Hearth Spark never uses. Mail counts
only email addressed to five people or fewer, so mailing lists and newsletters don't
count, and it skips Sent-to-self, Junk and Trash.

LinkedIn only adds to people already in your Contacts. A connection is matched to a
contact by email when the export includes one, otherwise by name, and only when exactly
one contact has that name. Connections who aren't in your Contacts are left out; the
iPhone app's own LinkedIn import covers them. LinkedIn's contribution to anyone's score
is capped, so working together can lift someone but never outrank people you actually
talk to. Its reasons appear in the review prefixed "LinkedIn:".

Your own contact card is skipped, so you're never recommended to yourself.

| Source | Exactly what | Never |
|---|---|---|
| Messages (`~/Library/Messages/chat.db`) | `message.date`, `message.is_from_me`, `message.associated_message_type`, `handle.id`, and the two join tables linking them to chats | Message text, rich text (`attributedBody`), subjects, attachments, group names |
| Call history (`CallHistory.storedata`) | `ZADDRESS`, `ZDATE`, `ZDURATION`, `ZANSWERED` | Names stored with calls, locations, anything else |
| Mail (`~/Library/Mail/V*/MailData/Envelope Index`) | `messages.sender`, `messages.mailbox`, `messages.date_sent`, `messages.date_received`, `addresses.address`, `recipients.message`, `recipients.address`, `mailboxes.url` | Email bodies (separate files, never opened), subjects, summaries, attachments |
| LinkedIn export (a folder you choose) | Connections (names, profile links, company, connected date, email if shared, used only to match); who endorsed or recommended whom; *whether* an invitation had a note; your own job history | Recommendation text, invitation notes, and every other file in the export |
| Contacts | Name, phone numbers, emails; whether a birthday, address or nickname is *filled in*; relation labels on your own card ("mother") | Birthday and address values, notes, photos, job details, social profiles |

The column lists are constants in the code (`MessagesSource.columnsRead`,
`CallsSource.columnsRead`). The tests build fake databases containing **only** those
columns, so a query that reached for anything else — message text included — would
fail. Databases are opened read-only (`mode=ro`); Hearth Spark cannot modify them.

If macOS changes these tables, Hearth Spark checks the schema first and skips the source
with a message rather than guessing.

## What is computed, and where

On the Mac, in memory, for the life of one run:

- **Counting happens inside SQLite.** The queries return one row per phone number or
  email with totals — messages sent and received in the past year, connected calls and
  minutes, first and last contact. Individual messages and calls never enter the
  process.
- **Only one-to-one conversations count.** Group chats and tapback reactions are excluded.
- **Strangers are dropped.** Any number or email not in your Contacts — businesses,
  verification codes, people you never saved — is discarded before scoring. It appears
  only as a count ("Left out: 214 numbers…").
- **Scoring is a transparent sum**, each part with a sentence. Reciprocity matters: a
  stream of messages you never answer scores nothing.

## What would be sent

A small JSON file, written only when you run with `--write`, and only moved to your
iPhone by you (AirDrop or Files). Per person:

| Field | Example | Why it's needed |
|---|---|---|
| `name` | Jane Doe | To show and create the person |
| `suggestedTier` | `innerCircle` | The point of the exercise |
| `lastContactMonth` | `2026-10` | To start "Last noted" — a month, not a date |
| `reasons` | "Messaged both ways this past year (120 sent, 140 received)" | So you can judge the suggestion |
| `matchKeys` | salted SHA-256 hashes | So the phone can find the same person in its own Contacts |

Plus a random `salt` and the month the file was made. Only people scoring above a
threshold are included, at most 150.

Not in the file: phone numbers or emails in the clear, exact dates, any counts beyond
what a reason states, anyone not in your Contacts, message content of any kind.

Run `hearth-spark --show-json` to see the exact bytes before writing.

In the app, each person has a closeness menu: change it and the file carries your
choice, with a note in the review that you changed it. You can also move someone to
"Distant", a tier the recommender never suggests on its own. In the app, unticking
someone in the review removes them from the file, not just from
view. "Exact file contents" shows the bytes as they'll be sent.

## What is kept

- **App, AirDrop:** nothing, once you confirm. The file is written to a private
  temporary folder (readable only by you) and sent. It is *not* deleted the moment
  AirDrop finishes: macOS reports "sent" when the transfer is handed off, not when
  Hearth has it, and an iPhone that never appeared would otherwise mean a lost file.
  The app asks "Did it arrive?" and deletes the copy only when you confirm, then checks
  it's gone. Until then you can send again or save it instead. Discarding deletes it,
  and quitting with an unconfirmed file asks first ("Delete and Quit" or "Cancel").
- **App, Save File:** exactly the file you saved, readable only by your user account.
- **Command-line tool:** nothing, unless you pass `--write`; then exactly that one file.

Scan results live in memory only, and the app clears them as soon as you confirm, save
or discard. No cache, no logs, no analytics, and no network connections at all. Both the
app and the tool end by stating what they left behind. Spark files are git-ignored
(`*.hearthspark`).

## No network, checked at build time

Hearth Spark makes no network connections, and the build enforces it.
`scripts/check-no-network.sh` runs on every app build and fails if the binary links a
networking framework (Network, CFNetwork, WebKit) or references networking APIs
(`URLSession`, sockets, `NWConnection`, name lookups). It was confirmed to fail on a
test program that uses `URLSession`.

Two honest notes:

- **This is a build check, not an OS guarantee.** The App Sandbox could make macOS
  enforce "no network", but Full Disk Access needs the app outside the sandbox. Anyone
  can confirm the behaviour with a network monitor such as LuLu or Little Snitch: Hearth
  Spark should show no connections.
- **AirDrop isn't the app's network use.** "Send with AirDrop" hands the file to macOS,
  which transfers it directly between your own devices. Hearth Spark itself never opens
  a connection.

## Its own permissions

The app is its own process with its own bundle identifier, so Contacts and Full Disk
Access are granted to *Hearth Spark* specifically. They appear under its name in System
Settings and can be revoked there. The command-line tool, by contrast, borrows whatever
the terminal has been granted, which is why the app is the recommended way to run it.

## Honest limits

- **Full Disk Access is broad.** macOS has no "Messages only" permission. Hearth Spark
  opens three databases and Contacts, only while a scan runs, and the code is short
  enough to check — but the grant itself covers far more. Keeping the grant lets you
  run Hearth Spark again later to refresh your list; it can be revoked anytime in
  System Settings.
- **Hashes are not anonymization.** Phone numbers are a small space; anyone with a Spark
  file and its salt could recover numbers by brute force. The hashes keep numbers out
  of plain sight in a file you send to your own phone. We don't claim more.
- **Names are in the file**, in the clear. The phone needs them to show suggestions.
- **This is a suggestion engine.** People who matter but rarely text or call — a
  grandparent you visit — won't score well. The iOS app must let the user add and
  correct freely.
- **Distribution.** Reading Messages needs an app outside the App Sandbox, so a shipped
  Mac app would likely be distributed directly (Developer ID, notarized) rather than
  through the Mac App Store.

## On the iPhone

Hearth registers the `.hearthspark` file type, so a file AirDropped from the Mac (or
opened from Files) opens straight into Hearth. The same promise holds there:

- **Review first.** A sheet lists everyone in the file by closeness, with the reasons.
  Untick anyone. Nothing is saved until you tap Add.
- **Contacts only if already allowed.** If Hearth already has Contacts access, it hashes
  this phone's numbers and emails with the file's salt and links matching people to
  their contact cards. If not, it doesn't ask: people are imported unlinked, and the
  sheet says so.
- **The minimum is saved:** each person's name and closeness, a contact link if one was
  found, and the month of last contact as a single "in touch (from your Mac)" entry,
  dated mid-month, at the lowest confidence Hearth uses (0.4). It's skipped if Hearth
  already knows of more recent contact. People already in Hearth keep the closeness you
  gave them.
- **Not saved:** the reasons and the match codes.
- **The file is deleted** from Hearth's inbox after Add, and after Cancel too. iOS
  copies received files into the app rather than opening them in place, so Hearth owns
  that copy and removes it. The last screen lists what was kept and confirms the file
  was deleted.

The file format and phone-number normalization are compiled into the iOS app from the
Mac app's own source, so the two sides can't disagree about the format.
