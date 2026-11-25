import Foundation

/// Ties the HTTP listener to the IPP printer.
public final class D450Service {
    public let config: ServiceConfig
    private let printer: IppPrinter
    private let log: (String) -> Void
    private var server: HttpServer?

    public init(config: ServiceConfig, sink: LabelSink, firstJobId: Int = 1, log: @escaping (String) -> Void) {
        self.config = config
        self.log = log
        self.printer = IppPrinter(config: config, sink: sink, firstJobId: firstJobId, log: log)
    }

    public func start() throws {
        let server = HttpServer(port: UInt16(config.port), log: log,
                                precheck: { [config] method, path, headers in
                                    D450Service.precheck(method, path, headers, port: config.port)
                                },
                                handler: { [config, printer] request in
                                    D450Service.handle(request, config: config, printer: printer)
                                })
        try server.start()
        self.server = server
        log("listening on http://localhost:\(config.port)/ipp/print and /ipp/all (loopback only)")
    }

    /// Requests are refused before their body is read unless they name this
    /// machine as the host. A web page in a browser cannot fake that, which
    /// stops a hostile page from sending print jobs to this port.
    static func precheck(_ method: String, _ path: String, _ headers: [String: String], port: Int) -> HttpResponse? {
        let host = (headers["host"] ?? "").lowercased()
        let allowed = ["localhost", "127.0.0.1", "[::1]"].flatMap { [$0, "\($0):\(port)"] }
        guard allowed.contains(host) else { return .text(403, "This service only answers to localhost.") }
        switch method {
        case "GET", "HEAD":
            return path == "/" ? nil : .text(404, "Not found")
        case "POST":
            let queues = [IppPrinter.labelPath, IppPrinter.everythingPath]
            guard queues.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return .text(404, "Not found") }
            let type = (headers["content-type"] ?? "").lowercased()
            guard type == "application/ipp" || type.hasPrefix("application/ipp;") else {
                return .text(415, "Send application/ipp")
            }
            return nil
        default:
            return .text(405, "Method not allowed")
        }
    }

    private static func handle(_ request: HttpRequest, config: ServiceConfig, printer: IppPrinter) -> HttpResponse {
        if request.method != "POST" {
            return .text(200, "d450d: Phomemo D450 print service.\n"
                + "Label only: ipp://localhost:\(config.port)\(IppPrinter.labelPath)\n"
                + "Label and the rest of the page: ipp://localhost:\(config.port)\(IppPrinter.everythingPath)")
        }
        guard let reply = printer.handle(request.body, path: request.path) else { return .text(400, "Not an IPP request") }
        return HttpResponse(status: 200, contentType: "application/ipp", body: reply)
    }
}
