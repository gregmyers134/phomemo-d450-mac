import Foundation

/// The IPP side of the service: answers IPP requests as a driverless
/// ("IPP Everywhere") printer and turns received documents into labels.
public final class IppPrinter {
    // IPP status codes used here.
    enum Status {
        static let ok: UInt16 = 0x0000
        static let badRequest: UInt16 = 0x0400
        static let notPossible: UInt16 = 0x0404
        static let notFound: UInt16 = 0x0406
        static let formatNotSupported: UInt16 = 0x040A
        static let operationNotSupported: UInt16 = 0x0501
        static let versionNotSupported: UInt16 = 0x0503
        static let multipleDocumentsNotSupported: UInt16 = 0x0509
    }

    // IPP job states.
    enum JobState { static let pending = 3, processing = 5, canceled = 7, aborted = 8, completed = 9 }

    final class Job {
        let id: Int
        var name = "Untitled"
        var user = "anonymous"
        var state = JobState.pending
        var reasons = ["job-incoming"]
        var message = ""
        var copies = 1
        var created = 0
        var started = 0
        var finished = 0
        var labelsDone = 0
        var hasDocument = false
        var cancelRequested = false
        /// Sent to the queue that also prints what is left of a page once its label is cut out.
        var everything = false
        init(id: Int) { self.id = id }
    }

    private let config: ServiceConfig
    private let sink: LabelSink
    private let log: (String) -> Void
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "d450.print")
    private var jobs = [Int: Job]()
    private var nextJobId = 1
    private let startTime = Date()
    private static let keptJobs = 50

    public init(config: ServiceConfig, sink: LabelSink, firstJobId: Int = 1, log: @escaping (String) -> Void) {
        self.config = config
        self.sink = sink
        self.log = log
        self.nextJobId = max(1, firstJobId)
    }

    /// The service is two print queues. Both print the label found on a page.
    /// The second also prints the rest of that page (instructions, a packing
    /// slip) on a further label.
    public static let labelPath = "/ipp/print"
    public static let everythingPath = "/ipp/all"

    static func isEverything(path: String) -> Bool {
        path == everythingPath || path.hasPrefix(everythingPath + "/")
    }

    private func uri(_ everything: Bool) -> String {
        "ipp://localhost:\(config.port)" + (everything ? IppPrinter.everythingPath : IppPrinter.labelPath)
    }
    private var upTime: Int { max(1, Int(Date().timeIntervalSince(startTime))) }

    private var formats: [String] {
        ["image/pwg-raster"] + (config.advertiseURF ? ["image/urf"] : []) + ["application/octet-stream"]
    }

    // MARK: Requests

    /// Takes one IPP request (with any document data after it) and returns the IPP response.
    /// Returns nil when the bytes are not an IPP message at all.
    /// `path` is the HTTP path the request was sent to; it selects the queue.
    public func handle(_ body: [UInt8], path: String = IppPrinter.labelPath) -> [UInt8]? {
        let everything = IppPrinter.isEverything(path: path)
        let request: IppMessage
        let dataOffset: Int
        do {
            (request, dataOffset) = try IppMessage.parse(body)
        } catch {
            guard body.count >= 8 else { return nil }
            var reply = IppMessage(code: Status.badRequest, requestId: 1, groups: [IppPrinter.head("Malformed IPP request.")])
            reply.versionMajor = body[0] == 2 ? 2 : 1
            reply.versionMinor = body[0] == 2 ? 0 : 1
            return reply.encoded()
        }
        let data = Array(body[dataOffset...])
        return respond(to: request, data: data, everything: everything).encoded()
    }

    private static func head(_ message: String? = nil) -> IppGroup {
        var attrs = [IppAttribute("attributes-charset", .charset("utf-8")),
                     IppAttribute("attributes-natural-language", .language("en"))]
        if let m = message { attrs.append(IppAttribute("status-message", .text(m))) }
        return IppGroup(tag: IppGroup.operation, attrs)
    }

    private func reply(_ request: IppMessage, _ status: UInt16, _ message: String? = nil,
                       _ groups: [IppGroup] = []) -> IppMessage {
        var r = IppMessage(code: status, requestId: request.requestId, groups: [IppPrinter.head(message)] + groups)
        r.versionMajor = request.versionMajor
        r.versionMinor = request.versionMinor
        return r
    }

    func respond(to request: IppMessage, data: [UInt8], everything: Bool) -> IppMessage {
        guard request.versionMajor == 1 || request.versionMajor == 2 else {
            var r = reply(request, Status.versionNotSupported, "IPP version not supported.")
            r.versionMajor = 2; r.versionMinor = 0
            return r
        }
        guard request.requestId > 0, let op = request.groups.first, op.tag == IppGroup.operation,
              op.attributes.count >= 2, op.attributes[0].name == "attributes-charset",
              op.attributes[1].name == "attributes-natural-language" else {
            return reply(request, Status.badRequest, "Missing or misplaced required operation attributes.")
        }
        // Every operation must say what it is aimed at (RFC 8011 section 4.1.5).
        guard op["printer-uri"] != nil || op["job-uri"] != nil else {
            return reply(request, Status.badRequest, "Missing printer-uri or job-uri.")
        }
        switch request.code {
        case 0x0002: return printJob(request, data, everything)
        case 0x0004: return validateJob(request)
        case 0x0005: return createJob(request, everything)
        case 0x0006: return sendDocument(request, data)
        case 0x0008: return cancelJob(request)
        case 0x0009: return getJobAttributes(request)
        case 0x000A: return getJobs(request, everything)
        case 0x000B: return getPrinterAttributes(request, everything)
        case 0x0039: return cancelMyJobs(request)
        case 0x003B: return closeJob(request)
        case 0x003C:
            log("Identify-Printer requested")
            return reply(request, Status.ok)
        default:
            return reply(request, Status.operationNotSupported, "Operation 0x\(String(request.code, radix: 16)) is not supported.")
        }
    }

    /// The names in "requested-attributes", or nil for everything.
    private func requested(_ request: IppMessage) -> Set<String>? {
        guard let a = request.attribute("requested-attributes", in: IppGroup.operation) else { return nil }
        let names = Set(a.values.compactMap { $0.stringValue })
        return names.contains("all") ? nil : names
    }

    /// Refuses a document format this printer does not take. Returns nil when the format is fine.
    private func formatProblem(_ request: IppMessage) -> IppMessage? {
        guard let f = request.attribute("document-format", in: IppGroup.operation)?.values.first?.stringValue else { return nil }
        if formats.contains(f) { return nil }
        return reply(request, Status.formatNotSupported, "Document format \(f) is not supported.",
                     [IppGroup(tag: IppGroup.unsupported, [IppAttribute("document-format", .mime(f))])])
    }

    private func newJob(_ request: IppMessage, _ everything: Bool) -> Job {
        lock.lock(); defer { lock.unlock() }
        let job = Job(id: nextJobId)
        job.everything = everything
        nextJobId += 1
        job.created = upTime
        if let n = request.attribute("job-name", in: IppGroup.operation)?.values.first?.stringValue { job.name = n }
        if let u = request.attribute("requesting-user-name", in: IppGroup.operation)?.values.first?.stringValue { job.user = u }
        if let c = request.attribute("copies", in: IppGroup.job)?.values.first?.intValue { job.copies = max(1, min(99, c)) }
        jobs[job.id] = job
        // Forget the oldest finished jobs.
        let done = jobs.values.filter { $0.state >= JobState.canceled }.map { $0.id }.sorted()
        if done.count > IppPrinter.keptJobs { for id in done.prefix(done.count - IppPrinter.keptJobs) { jobs[id] = nil } }
        return job
    }

    private func findJob(_ request: IppMessage) -> Job? {
        var id = request.attribute("job-id", in: IppGroup.operation)?.values.first?.intValue
        if id == nil, let u = request.attribute("job-uri", in: IppGroup.operation)?.values.first?.stringValue,
           let last = u.split(separator: "/").last {
            id = Int(last)
        }
        guard let jobId = id else { return nil }
        lock.lock(); defer { lock.unlock() }
        return jobs[jobId]
    }

    private func printJob(_ request: IppMessage, _ data: [UInt8], _ everything: Bool) -> IppMessage {
        if let problem = formatProblem(request) { return problem }
        guard !data.isEmpty else { return reply(request, Status.badRequest, "No document data.") }
        let job = newJob(request, everything)
        start(job, data)
        return reply(request, Status.ok, nil, [jobGroup(job, nil)])
    }

    private func validateJob(_ request: IppMessage) -> IppMessage {
        formatProblem(request) ?? reply(request, Status.ok)
    }

    private func createJob(_ request: IppMessage, _ everything: Bool) -> IppMessage {
        let job = newJob(request, everything)
        return reply(request, Status.ok, nil, [jobGroup(job, nil)])
    }

    private func sendDocument(_ request: IppMessage, _ data: [UInt8]) -> IppMessage {
        if let problem = formatProblem(request) { return problem }
        guard let job = findJob(request) else { return reply(request, Status.notFound, "Job not found.") }
        guard let last = request.attribute("last-document", in: IppGroup.operation)?.values.first?.boolValue else {
            return reply(request, Status.badRequest, "Missing last-document.")
        }
        lock.lock()
        let closed = job.state != JobState.pending || job.hasDocument
        if !closed && !data.isEmpty { job.hasDocument = true }
        lock.unlock()
        if closed {
            return data.isEmpty && last
                ? reply(request, Status.ok, nil, [jobGroup(job, nil)])
                : reply(request, Status.multipleDocumentsNotSupported, "This printer takes one document per job.")
        }
        if data.isEmpty {
            guard last else { return reply(request, Status.badRequest, "No document data.") }
            finish(job, JobState.aborted, ["aborted-by-system"], "The job had no document.")
        } else {
            start(job, data)
        }
        return reply(request, Status.ok, nil, [jobGroup(job, nil)])
    }

    private func closeJob(_ request: IppMessage) -> IppMessage {
        guard let job = findJob(request) else { return reply(request, Status.notFound, "Job not found.") }
        lock.lock()
        let empty = job.state == JobState.pending && !job.hasDocument
        lock.unlock()
        if empty { finish(job, JobState.aborted, ["aborted-by-system"], "The job had no document.") }
        return reply(request, Status.ok)
    }

    /// Returns false when the job has already finished.
    private func cancel(_ job: Job) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if job.state >= JobState.canceled { return false }
        if job.state == JobState.pending && !job.hasDocument {
            job.state = JobState.canceled
            job.reasons = ["job-canceled-by-user"]
            job.finished = upTime
        } else {
            job.cancelRequested = true          // the worker stops before the next label
            job.reasons = ["processing-to-stop-point"]
        }
        return true
    }

    private func cancelJob(_ request: IppMessage) -> IppMessage {
        guard let job = findJob(request) else { return reply(request, Status.notFound, "Job not found.") }
        guard cancel(job) else { return reply(request, Status.notPossible, "The job has already finished.") }
        log("job \(job.id): cancel requested")
        return reply(request, Status.ok)
    }

    private func cancelMyJobs(_ request: IppMessage) -> IppMessage {
        lock.lock()
        let open = jobs.values.filter { $0.state < JobState.canceled }
        lock.unlock()
        for job in open { _ = cancel(job) }
        return reply(request, Status.ok)
    }

    private func getJobAttributes(_ request: IppMessage) -> IppMessage {
        guard let job = findJob(request) else { return reply(request, Status.notFound, "Job not found.") }
        return reply(request, Status.ok, nil, [jobGroup(job, requested(request))])
    }

    private func getJobs(_ request: IppMessage, _ everything: Bool) -> IppMessage {
        let which = request.attribute("which-jobs", in: IppGroup.operation)?.values.first?.stringValue ?? "not-completed"
        let limit = request.attribute("limit", in: IppGroup.operation)?.values.first?.intValue ?? Int.max
        // "my-jobs" limits the list to the jobs of the user asking.
        let mine = request.attribute("my-jobs", in: IppGroup.operation)?.values.first?.boolValue ?? false
        let user = request.attribute("requesting-user-name", in: IppGroup.operation)?.values.first?.stringValue
        lock.lock()
        let list = jobs.values.filter { $0.everything == everything && ($0.state >= JobState.canceled) == (which == "completed") }
            .filter { !mine || user == nil || $0.user == user }
            .sorted { $0.id < $1.id }.prefix(max(0, limit))
        lock.unlock()
        // Without "requested-attributes" a job list carries only the id and URI.
        let asked = request.attribute("requested-attributes", in: IppGroup.operation) != nil
        let wanted = asked ? requested(request) : ["job-id", "job-uri"]
        return reply(request, Status.ok, nil, list.map { jobGroup($0, wanted) })
    }

    private func getPrinterAttributes(_ request: IppMessage, _ everything: Bool) -> IppMessage {
        let wanted = requested(request)
        let attrs = printerAttributes(everything: everything).filter { a in
            guard let w = wanted else { return true }
            return w.contains(a.name) || w.contains(IppPrinter.isJobTemplate(a.name) ? "job-template" : "printer-description")
        }
        return reply(request, Status.ok, nil, [IppGroup(tag: IppGroup.printer, attrs)])
    }

    // MARK: Job attributes

    private func jobGroup(_ job: Job, _ wanted: Set<String>?) -> IppGroup {
        lock.lock(); defer { lock.unlock() }
        func time(_ t: Int) -> IppValue { t > 0 ? .integer(Int32(t)) : .outOfBand(0x13) }
        let all = [
            IppAttribute("job-id", .integer(Int32(job.id))),
            IppAttribute("job-uri", .uri("\(uri(job.everything))/\(job.id)")),
            IppAttribute("job-state", .enumeration(Int32(job.state))),
            IppAttribute("job-state-reasons", job.reasons.map { IppValue.keyword($0) }),
            IppAttribute("job-state-message", .text(job.message)),
            IppAttribute("job-name", .name(job.name)),
            IppAttribute("job-originating-user-name", .name(job.user)),
            IppAttribute("job-printer-uri", .uri(uri(job.everything))),
            IppAttribute("job-printer-up-time", .integer(Int32(upTime))),
            IppAttribute("job-impressions-completed", .integer(Int32(job.labelsDone))),
            IppAttribute("job-media-sheets-completed", .integer(Int32(job.labelsDone))),
            IppAttribute("time-at-creation", time(job.created)),
            IppAttribute("time-at-processing", time(job.started)),
            IppAttribute("time-at-completed", time(job.finished)),
        ]
        guard let w = wanted, !w.contains("job-description") else { return IppGroup(tag: IppGroup.job, all) }
        return IppGroup(tag: IppGroup.job, all.filter { w.contains($0.name) })
    }

    // MARK: Printing

    private func finish(_ job: Job, _ state: Int, _ reasons: [String], _ message: String) {
        lock.lock()
        job.state = state
        job.reasons = reasons
        job.message = message
        job.finished = upTime
        lock.unlock()
        log("job \(job.id): \(message)")
    }

    /// Queues the document. Labels are made on a background queue, one job at a
    /// time, so the reply to the client is not held up; the client polls the job state.
    private func start(_ job: Job, _ data: [UInt8]) {
        lock.lock()
        job.hasDocument = true
        job.reasons = ["job-queued"]
        lock.unlock()
        log("job \(job.id): received \(data.count) bytes, \"\(job.name)\" from \(job.user)")
        worker.async { self.process(job, data) }
    }

    private func process(_ job: Job, _ data: [UInt8]) {
        lock.lock()
        if job.cancelRequested {
            lock.unlock()
            return finish(job, JobState.canceled, ["job-canceled-by-user"], "canceled before printing")
        }
        job.state = JobState.processing
        job.reasons = ["job-printing"]
        job.started = upTime
        let copies = job.copies
        lock.unlock()

        guard let format = RasterDocument.format(of: data) else {
            return finish(job, JobState.aborted, ["aborted-by-system", "document-format-error"],
                          "aborted: the document is neither PWG Raster nor Apple Raster")
        }
        sink.received(jobId: job.id, document: data, format: format)
        let printer = config.printer
        var pageNumber = 0
        var labelNumber = 0      // labels made so far in this job; a page can hold more than one
        var stopped = false
        do {
            try RasterDocument.forEachPage(data) { page in
                self.lock.lock()
                let cancel = job.cancelRequested
                self.lock.unlock()
                if cancel { stopped = true; return false }
                pageNumber += 1
                let labels = LabelLayout.layoutAll(page, config: self.config, includeRest: job.everything)
                if labels.isEmpty {
                    self.log("job \(job.id) page \(pageNumber): \(page.source); blank, skipped")
                    return true
                }
                for label in labels {
                    self.lock.lock()
                    let cancelNow = job.cancelRequested
                    self.lock.unlock()
                    if cancelNow { stopped = true; return false }
                    labelNumber += 1
                    self.log("job \(job.id) page \(pageNumber): \(page.source); \(label.note)")
                    let canvas = Tspl.canvas(for: label.page, config: printer)
                    let bytes = try Tspl.job(canvas: canvas, config: printer, copies: copies)
                    try self.sink.deliver(jobId: job.id, label: labelNumber, copies: copies, canvas: canvas,
                                          speed: Tspl.speedCommand(printer), job: bytes)
                    self.lock.lock()
                    job.labelsDone += copies
                    self.lock.unlock()
                }
                return true
            }
        } catch {
            let formatError = error is RasterError
            return finish(job, JobState.aborted, ["aborted-by-system"] + (formatError ? ["document-format-error"] : []),
                          "aborted on page \(pageNumber + 1): \(error)")
        }
        if stopped {
            finish(job, JobState.canceled, ["job-canceled-by-user"], "canceled after \(job.labelsDone) label(s)")
        } else {
            finish(job, JobState.completed, ["job-completed-successfully"], "completed, \(job.labelsDone) label(s)")
        }
    }

    // MARK: Printer attributes

    /// The three page sizes offered, in hundredths of a millimetre.
    static let media: [(name: String, x: Int32, y: Int32)] = [
        ("na_index-4x6_4x6in", 10160, 15240),
        ("na_letter_8.5x11in", 21590, 27940),
        ("iso_a4_210x297mm", 21000, 29700),
    ]

    /// Margin advertised on every edge, in hundredths of a millimetre.
    /// It is 0.01 mm rather than 0 on purpose. With margins of exactly 0, CUPS
    /// names each size "<size>.Borderless" in the queue it builds but still
    /// makes plain "<size>" the default, a name that is then not in its list.
    static let margin: Int32 = 1

    private static func mediaSize(_ m: (name: String, x: Int32, y: Int32)) -> IppValue {
        .collection([IppAttribute("x-dimension", .integer(m.x)), IppAttribute("y-dimension", .integer(m.y))])
    }

    private static func mediaCol(_ m: (name: String, x: Int32, y: Int32), full: Bool) -> IppValue {
        var members = [
            IppAttribute("media-size", mediaSize(m)),
            IppAttribute("media-bottom-margin", .integer(margin)),
            IppAttribute("media-left-margin", .integer(margin)),
            IppAttribute("media-right-margin", .integer(margin)),
            IppAttribute("media-top-margin", .integer(margin)),
        ]
        if full {
            members.insert(IppAttribute("media-size-name", .keyword(m.name)), at: 1)
            members.append(IppAttribute("media-source", .keyword("main")))
            members.append(IppAttribute("media-type", .keyword("labels")))
        }
        return .collection(members)
    }

    /// Attributes a client gets when it asks for the "job-template" group.
    static func isJobTemplate(_ name: String) -> Bool {
        for suffix in ["-default", "-supported", "-ready", "-database"] where name.hasSuffix(suffix) {
            let base = String(name.dropLast(suffix.count))
            return ["copies", "finishings", "media", "media-col", "media-size", "media-source", "media-type",
                    "media-bottom-margin", "media-left-margin", "media-right-margin", "media-top-margin",
                    "orientation-requested", "output-bin", "print-color-mode", "print-quality",
                    "printer-resolution", "sides"].contains(base)
        }
        return false
    }

    func printerAttributes(everything: Bool = false) -> [IppAttribute] {
        lock.lock()
        let active = jobs.values.filter { $0.state < JobState.canceled && $0.everything == everything }
        let busy = active.contains { $0.state == JobState.processing }
        lock.unlock()
        let m = IppPrinter.media
        let dpi = IppValue.resolution(203, 203, units: 3)
        func kw(_ list: [String]) -> [IppValue] { list.map { IppValue.keyword($0) } }
        var a: [IppAttribute] = [
            IppAttribute("charset-configured", .charset("utf-8")),
            IppAttribute("charset-supported", .charset("utf-8")),
            IppAttribute("color-supported", .boolean(false)),
            IppAttribute("compression-supported", .keyword("none")),
            IppAttribute("copies-default", .integer(1)),
            IppAttribute("copies-supported", .range(1, 99)),
            IppAttribute("document-format-default", .mime("application/octet-stream")),
            IppAttribute("document-format-supported", formats.map { IppValue.mime($0) }),
            IppAttribute("finishings-default", .enumeration(3)),
            IppAttribute("finishings-supported", .enumeration(3)),
            IppAttribute("generated-natural-language-supported", .language("en")),
            IppAttribute("identify-actions-default", .keyword("display")),
            IppAttribute("identify-actions-supported", .keyword("display")),
            IppAttribute("ipp-features-supported", .keyword("ipp-everywhere")),
            IppAttribute("ipp-versions-supported", kw(["1.1", "2.0"])),
            IppAttribute("job-creation-attributes-supported", kw(["copies", "media", "media-col", "print-color-mode", "print-quality"])),
            IppAttribute("job-ids-supported", .boolean(true)),
            IppAttribute("media-bottom-margin-supported", .integer(IppPrinter.margin)),
            IppAttribute("media-col-database", m.map { IppPrinter.mediaCol($0, full: false) }),
            IppAttribute("media-col-default", IppPrinter.mediaCol(m[0], full: true)),
            IppAttribute("media-col-ready", IppPrinter.mediaCol(m[0], full: true)),
            IppAttribute("media-col-supported", kw(["media-bottom-margin", "media-left-margin", "media-right-margin",
                                                    "media-size", "media-size-name", "media-source", "media-top-margin", "media-type"])),
            IppAttribute("media-default", .keyword(m[0].name)),
            IppAttribute("media-left-margin-supported", .integer(IppPrinter.margin)),
            IppAttribute("media-ready", .keyword(m[0].name)),
            IppAttribute("media-right-margin-supported", .integer(IppPrinter.margin)),
            IppAttribute("media-size-supported", m.map { IppPrinter.mediaSize($0) }),
            IppAttribute("media-source-supported", .keyword("main")),
            IppAttribute("media-supported", kw(m.map { $0.name })),
            IppAttribute("media-top-margin-supported", .integer(IppPrinter.margin)),
            IppAttribute("media-type-supported", .keyword("labels")),
            IppAttribute("multiple-document-jobs-supported", .boolean(false)),
            IppAttribute("multiple-operation-time-out", .integer(60)),
            IppAttribute("multiple-operation-time-out-action", .keyword("abort-job")),
            IppAttribute("natural-language-configured", .language("en")),
            IppAttribute("operations-supported", [0x02, 0x04, 0x05, 0x06, 0x08, 0x09, 0x0A, 0x0B, 0x39, 0x3B, 0x3C]
                .map { IppValue.enumeration($0) }),
            // "face-down" keeps pages in order. CUPS prints the last page first for a face-up bin.
            // Pages arrive already turned the right way, so the requested orientation is not acted on.
            IppAttribute("orientation-requested-default", .outOfBand(0x13)),
            IppAttribute("orientation-requested-supported", [3, 4, 5, 6].map { IppValue.enumeration($0) }),
            IppAttribute("output-bin-default", .keyword("face-down")),
            IppAttribute("output-bin-supported", .keyword("face-down")),
            IppAttribute("pages-per-minute", .integer(12)),
            IppAttribute("pdl-override-supported", .keyword("attempted")),
            IppAttribute("print-color-mode-default", .keyword("monochrome")),
            IppAttribute("print-color-mode-supported", .keyword("monochrome")),
            IppAttribute("print-quality-default", .enumeration(4)),
            IppAttribute("print-quality-supported", .enumeration(4)),
            IppAttribute("printer-device-id", .text("MFG:Phomemo;MDL:D450;CMD:PWGRaster;")),
            IppAttribute("printer-get-attributes-supported", .keyword("document-format")),
            IppAttribute("printer-info", .text(everything ? "Phomemo D450 label + rest of page" : "Phomemo D450 label printer")),
            IppAttribute("printer-is-accepting-jobs", .boolean(true)),
            IppAttribute("printer-location", .text("")),
            IppAttribute("printer-make-and-model", .text("Phomemo D450")),
            IppAttribute("printer-more-info", .uri("http://localhost:\(config.port)/")),
            IppAttribute("printer-name", .name(config.printerName + (everything ? "_all" : ""))),
            IppAttribute("printer-resolution-default", dpi),
            IppAttribute("printer-resolution-supported", dpi),
            IppAttribute("printer-state", .enumeration(busy ? 4 : 3)),
            IppAttribute("printer-state-message", .text("")),
            IppAttribute("printer-state-reasons", .keyword("none")),
            IppAttribute("printer-up-time", .integer(Int32(upTime))),
            IppAttribute("printer-uri-supported", .uri(uri(everything))),
            IppAttribute("printer-uuid", .uri("urn:uuid:4c4d7d0e-d450-4d45-9d45-0d450000863" + (everything ? "2" : "1"))),
            IppAttribute("pwg-raster-document-resolution-supported", dpi),
            IppAttribute("pwg-raster-document-type-supported", kw(["black_1", "sgray_8"])),
            IppAttribute("queued-job-count", .integer(Int32(active.count))),
            IppAttribute("sides-default", .keyword("one-sided")),
            IppAttribute("sides-supported", .keyword("one-sided")),
            IppAttribute("uri-authentication-supported", .keyword("none")),
            IppAttribute("uri-security-supported", .keyword("none")),
            IppAttribute("which-jobs-supported", kw(["completed", "not-completed"])),
        ]
        if config.advertiseURF {
            a.append(IppAttribute("urf-supported", kw(["V1.4", "CP1", "IS1", "MT1", "OB9", "PQ4", "RS203", "W8"])))
        }
        return a.sorted { $0.name < $1.name }
    }
}
