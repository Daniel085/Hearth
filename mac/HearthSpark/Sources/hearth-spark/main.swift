import Foundation
import HearthSparkCore

// hearth-spark — suggest who you're close to, from Messages, calls and Contacts on this
// Mac, and write a small file for Hearth on your iPhone.
//
//   hearth-spark                    review only: shows what would be sent, writes nothing
//   hearth-spark --summary          counts only, no names
//   hearth-spark --write FILE       write the Spark file after showing the review
//   hearth-spark --show-json        also print the file's exact contents
//   hearth-spark --no-messages --no-calls --no-mail
//   hearth-spark --linkedin FOLDER  also use an unzipped LinkedIn data export
//                                   leave a source out; it is never opened
//
// Everything runs on this Mac. Nothing is sent anywhere by this tool.

let args = CommandLine.arguments.dropFirst()
func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), args.index(after: i) < args.endIndex else { return nil }
    return args[args.index(after: i)]
}
let summaryOnly = args.contains("--summary")
let showJSON = args.contains("--show-json")
let writePath = value(after: "--write")
let linkedInFolder = value(after: "--linkedin").map {
    URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
}
var sources = Set(SparkSource.handleSources.filter { !args.contains("--no-\($0.rawValue)") })
if linkedInFolder != nil { sources.insert(.linkedIn) }

if args.contains("--help") || args.contains("-h") {
    print("""
    usage: hearth-spark [--summary] [--show-json] [--no-messages] [--no-calls] [--no-mail] [--linkedin FOLDER] [--write FILE]

    Reads who you message and call (never what), plus your Contacts, on this Mac.
    Shows who it would suggest to Hearth and why. Writes a file only with --write.
    Needs Full Disk Access (Messages, call history) and Contacts access for your terminal.
    """)
    exit(0)
}

func stderr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let scan: SparkScan
do {
    scan = try SparkScan.run(sources: sources, linkedInFolder: linkedInFolder)
} catch {
    stderr(error.localizedDescription)
    exit(1)
}
let result = scan.result
let data: Data
do {
    data = try result.file.encoded()
} catch {
    stderr("Couldn't encode the Spark file: \(error.localizedDescription)")
    exit(1)
}

print(Review.whatWasRead(scan.reports))
if summaryOnly {
    print(Review.summary(result, cardCount: scan.cardCount, interactionHandles: scan.interactionHandles))
} else {
    print(Review.whatWouldBeSent(result, encodedSize: data.count))
}
if showJSON, let json = String(data: data, encoding: .utf8) {
    print("EXACT FILE CONTENTS\n\(json)\n")
}

if let writePath {
    let url = URL(fileURLWithPath: (writePath as NSString).expandingTildeInPath)
    do {
        try data.write(to: url, options: [.atomic])
        // Readable by this user only.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        print(Review.whatWasKept(written: url.path, bytes: data.count))
    } catch {
        stderr("Couldn't write \(url.path): \(error.localizedDescription)")
        exit(1)
    }
} else {
    print(Review.whatWasKept(written: nil, bytes: 0))
}
