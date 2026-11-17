# Hearth Spark

Suggests who you're close to from Messages, call history, Apple Mail and Contacts on your Mac, and
writes a small file for Hearth on your iPhone. Everything runs locally. See
[docs/hearth-spark-privacy.md](../../docs/hearth-spark-privacy.md) for exactly what it
reads, sends and keeps.

## The app

```bash
scripts/make-app.sh
```

```bash
open "build/Hearth Spark.app"
```

The app has its own permissions, so Full Disk Access goes to *Hearth Spark* rather than
to your whole terminal. It walks through:

1. **What to read, and permissions.** Switch Messages, Call history or Mail off if you'd
   rather they weren't read; a source that's off is never opened. It asks for Contacts. For Full Disk Access, open Settings, add Hearth
   Spark with the + button, and reopen the app. Full Disk Access is optional: without it,
   suggestions come from Contacts alone.
2. **Find My People.** Counts who you message and call, on this Mac.
3. **Review.** Everyone it would send, with reasons. Change anyone's closeness from the
   menu on their row, untick anyone to leave them out of the file, and expand "Exact
   file contents" to see the bytes.
4. **Send to iPhone with AirDrop**, or **Save File…**.
5. **Did it arrive?** After AirDrop, the app keeps a temporary copy until you confirm
   Hearth on your iPhone has it, so a failed or invisible AirDrop never loses the file.
   Confirm, and it deletes the copy and checks it's gone. Or send again, or save it
   instead. Quitting with an unconfirmed file asks first.
6. **Done.** Shows what it kept on the Mac, which is nothing after a confirmed AirDrop.
   Run it again anytime to refresh your list.

The build refuses to package the app if it links any networking API
(`scripts/check-no-network.sh`). Hearth Spark doesn't use the internet at all.

The script signs with an Apple Development or Developer ID certificate if your keychain
has one. Otherwise it signs ad hoc, and macOS forgets the app's permissions each time
it's rebuilt. Add a certificate in Xcode → Settings → Accounts → Manage Certificates to
avoid that.

## The command-line tool

Same scan, for scripting and testing. Run it in Terminal (or iTerm), not an editor's or
app's built-in shell: macOS asks for Contacts access on the first run, and only a real
terminal can show that prompt. The terminal also needs Full Disk Access.

```bash
swift run -q hearth-spark
```

```bash
swift run -q hearth-spark --summary
```

```bash
swift run -q hearth-spark --show-json
```

```bash
swift run -q hearth-spark --no-mail
```

```bash
swift run -q hearth-spark --write ~/Desktop/me.hearthspark
```

With no options it shows the review and writes nothing. `--summary` prints counts only,
with no names. `--no-messages`, `--no-calls` and `--no-mail` leave a source out, unopened. `--show-json` prints the file's exact contents. `--write` saves the file,
then tells you it's the only thing it kept.

## Test

```bash
swift test
```
