// Licensed under the Apache License, Version 2.0

import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart';

/// App-specific attribute keys as a typed enum. Prefer enums over raw
/// strings; for any attribute that exists in the OTel semantic
/// conventions, use the corresponding API enum instead.
enum ExampleAttribute implements OTelSemantic {
  exampleKey('example.key');

  @override
  final String key;

  @override
  String toString() => key;

  const ExampleAttribute(this.key);
}

void main() async {
  // Initialize OTel first with the endpoint
  // String endpoint = 'https://app.middleware.op';
  // var secure = true;
  final endpoint = 'http://app.middleware.io';
  final secure = false;
  await OTel.initialize(
      secure: secure,
      endpoint: endpoint,
      serviceName: 'middleware-examples',
      tracerName: 'otlp_grpc_example',
      tracerVersion: '1.0.0',
      // Always consult the OTel Semantic Conventions to find an existing
      // convention name for an attribute:
      // https://opentelemetry.io/docs/specs/semconv/general/attributes/
      resourceAttributes: {
        DeploymentResource.deploymentEnvironmentName.key:
            'dev', //https://opentelemetry.io/docs/specs/semconv/resource/deployment-environment/
      }.toAttributes());

  // Get the default tracer
  final tracer = OTel.tracer();

  //Add attributes
  // Always consult the OTel Semantic Conventions to find an existing
  // convention name for an attribute:
  // https://opentelemetry.io/docs/specs/semconv/general/attributes/
  tracer.attributes = OTel.attributesFromSemanticMap({
    SourceCode.codeFunctionName: 'main',
  });

  // Create a new root span. Prefer typed enum keys over raw strings.
  final rootSpan = tracer.startSpan(
    'root-operation-middleware',
    attributes: OTel.attributesFromMap({
      'middlewareAccountKey': 'example-value-middleware',
    }),
  );

  try {
    // Add an event to match Python example
    rootSpan.addEventNow('Event within span-middleware');

    print('Middleware Trace with a span sent to OpenTelemetry.');

    // Simulate some work.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Create a child span.
    final childSpan = tracer.startSpan(
      'child-operation-middleware',
      parentSpan: rootSpan,
    );

    try {
      print('Doing some more work...');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    } catch (e, stackTrace) {
      // The span has a status of SpanStatus.Ok on creation, set it to
      // Error when an error occurs in the span.
      childSpan.recordException(e, stackTrace: stackTrace);
      childSpan.setStatus(SpanStatusCode.Error, e.toString());
      rethrow;
    } finally {
      childSpan.end();
    }
  } catch (e, stackTrace) {
    // The span has a status of SpanStatus.Ok on creation, set it to
    // Error when an error occurs in the span.
    rootSpan.recordException(e, stackTrace: stackTrace);
    rootSpan.setStatus(SpanStatusCode.Error, e.toString());
  } finally {
    rootSpan.end();
  }

  // Force flush before shutdown
  await OTel.tracerProvider().forceFlush();

  // Wait for any pending exports
  await Future<void>.delayed(const Duration(seconds: 1));

  // Shutdown - TODO - forceFlush inside?
  await OTel.tracerProvider().shutdown();
}
