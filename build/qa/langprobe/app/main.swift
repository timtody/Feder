import Foundation
import AVFoundation
var paths: [String] = []
var skipNext = false
for argument in CommandLine.arguments.dropFirst() {
    if skipNext { skipNext = false; continue }
    if argument.hasPrefix("-") { skipNext = true; continue }   // -AppleLanguages "(…)": the iPhone's languages
    paths.append(argument)
}
for path in paths {
    let url = URL(fileURLWithPath: path)
    let file = try AVAudioFile(forReading: url)
    let duration = Double(file.length) / file.processingFormat.sampleRate
    let clock = ContinuousClock.now
    let chosen = Locale(identifier: ProcessInfo.processInfo.environment["CHOSEN"] ?? "de-DE")
    let locale = await LanguageProbe.language(of: url, duration: duration, chosen: chosen)
    print("\(url.lastPathComponent): \(locale.identifier) [\(ContinuousClock.now - clock)]")
}
