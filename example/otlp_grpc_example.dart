// Licensed under the Apache License, Version 2.0

import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart';

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
  tracer.attributes =
      OTel.attributesFromMap({SourceCodeResource.codeFunctionName.key: 'main'});

  // Create a new root span
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

    // Simulate some work
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Create a child span
    final childSpan = tracer.startSpan(
      'child-operation-middleware',
      parentSpan: rootSpan,
    );

    try {
      print('Doing some more work...');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    } catch (e) {
      childSpan.recordException(e);
      childSpan.setStatus(SpanStatusCode.Error);
    } finally {
      childSpan.end();
    }
  } catch (e) {
    rootSpan.recordException(e);
    rootSpan.setStatus(SpanStatusCode.Error);
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
