import Foundation

/// Where finished labels go: the printer, or files in dry-run mode.
public protocol LabelSink {
    /// The document exactly as the print system sent it. Called once per job.
    func received(jobId: Int, document: [UInt8], format: RasterFormat)
    /// One label ready to print: the `label`-th of its job, counting from 1.
    /// `speed` is sent first, then `job`, which already asks for `copies` copies.
    func deliver(jobId: Int, label: Int, copies: Int, canvas: MonoBitmap, speed: [UInt8], job: [UInt8]) throws
}

public enum SinkError: Error, Equatable { case cannotWrite(String) }

/// Dry run: writes each label as a PNG next to the exact bytes that would
/// have gone to the printer, and keeps the document that was received.
public final class DryRunSink: LabelSink {
    public let directory: String
    private let log: (String) -> Void

    public init(directory: String, log: @escaping (String) -> Void) throws {
        self.directory = directory
        self.log = log
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    private func write(_ name: String, _ bytes: [UInt8]) throws {
        let path = directory + "/" + name
        guard FileManager.default.createFile(atPath: path, contents: Data(bytes)) else {
            throw SinkError.cannotWrite(path)
        }
    }

    private func stem(_ jobId: Int) -> String { String(format: "job-%04d", jobId) }

    /// Highest job number already used by files in the directory, so a
    /// restarted service does not overwrite the output of an earlier run.
    public func highestJobNumber() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.compactMap { name -> Int? in
            guard name.hasPrefix("job-") else { return nil }
            return Int(name.dropFirst(4).prefix { $0.isNumber })
        }.max() ?? 0
    }

    public func received(jobId: Int, document: [UInt8], format: RasterFormat) {
        let name = "\(stem(jobId))-received.\(format.rawValue)"
        if (try? write(name, document)) == nil { log("could not write \(name)") }
    }

    public func deliver(jobId: Int, label: Int, copies: Int, canvas: MonoBitmap, speed: [UInt8], job: [UInt8]) throws {
        let base = "\(stem(jobId))-label-\(String(format: "%02d", label))"
        try write(base + ".png", Png.encode(canvas))
        try write(base + ".tspl", speed + job)
        log("dry run: wrote \(base).png and \(base).tspl (\(speed.count + job.count) bytes)")
    }
}
