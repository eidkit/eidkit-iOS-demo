#if canImport(UIKit)
import UIKit
#endif
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import EidKit
import EidKitOtlp

enum TelemetrySetup {

    // Sentry OTLP endpoint for the eidkit demo project.
    // Key is intentionally committed -- rotate via CI/CD when needed.
    private static let sentryEndpoint = URL(
        string: "https://o203117.ingest.us.sentry.io/api/4511106211840001/integration/otlp/v1/traces"
    )!
    private static let sentryHeaders = [
        "x-sentry-auth": "Sentry sentry_key=22e233bd3faf6fd24e2c749885443184"
    ]

    // Single provider instance shared between EidKit and any direct app spans.
    static let provider: TracerProviderSdk = {
        let resource = Resource(attributes: [
            "service.name":           .string("eidkit-ios-demo"),
            "sdk.name":               .string("eidkit-ios"),
            "sdk.version":            .string("0.1.4"),
            "device.model":           .string(deviceModel),
            "device.os_version":      .string(osVersion),
            "nfc.tech":               .string("IsoDep"),
            "deployment.environment": .string(environment),
        ])
        return TracerProviderBuilder()
            .add(spanProcessor: SimpleSpanProcessor(spanExporter: ConsoleSpanExporter()))
            .add(spanProcessor: SimpleSpanProcessor(spanExporter: OtlpHttpSpanExporter(
                endpoint: sentryEndpoint,
                headers: sentryHeaders,
                resource: resource
            )))
            .with(resource: resource)
            .build()
    }()

    static func makeTracerProvider() -> any TracerProvider { provider }

    /// Adapter that bridges EidKit's onSpan callback into the OTel provider.
    static let adapter = EidKitSpanAdapter(
        tracer: provider.get(instrumentationName: "io.eidkit.sdk", instrumentationVersion: "0.1.4")
    )

    /// Fires a single span on app start to verify the full OTel pipeline.
    /// Look for `[EidKitOtlp] HTTP 2xx` in the Xcode console to confirm delivery.
    static func emitProbeSpan() {
        let tracer = provider.get(
            instrumentationName: "eidkit-demo-app",
            instrumentationVersion: "1.0.0"
        )
        let span = tracer.spanBuilder(spanName: "app.start.probe")
            .setSpanKind(spanKind: .internal)
            .startSpan()
        span.setAttribute(key: "probe", value: AttributeValue.bool(true))
        span.end()
    }

    // MARK: -

    #if DEBUG
    private static let environment = "debug"
    #else
    private static let environment = "production"
    #endif

    private static var deviceModel: String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return "unknown"
        #endif
    }

    private static var osVersion: String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
}
