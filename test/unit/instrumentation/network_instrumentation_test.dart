// Licensed under the Apache License, Version 2.0

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart';
import 'package:test/test.dart';

import '../../testing_utils/in_memory_span_exporter.dart';

/// Answers every Dio request with [statusCode] and a small JSON body, without
/// touching the network.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.statusCode);

  final int statusCode;

  /// Headers of the most recent request, to check what was propagated.
  Map<String, dynamic> lastHeaders = const {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastHeaders = Map<String, dynamic>.of(options.headers);
    return ResponseBody.fromString(
      jsonEncode({'ok': statusCode < 400}),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late InMemorySpanExporter exporter;

  setUp(() async {
    await OTel.reset();
    exporter = InMemorySpanExporter();
    await OTel.initialize(
      serviceName: 'network-instrumentation-test',
      serviceVersion: '1.0.0',
      spanProcessor: SimpleSpanProcessor(exporter),
      detectPlatformResources: false,
    );
  });

  tearDown(() async {
    try {
      await OTel.shutdown();
    } catch (_) {}
    await OTel.reset();
  });

  /// The single HTTP span the request produced.
  Future<Span> onlySpan() async {
    await OTel.tracerProvider().forceFlush();
    expect(exporter.spans, hasLength(1));
    return exporter.spans.single;
  }

  group('OTelHttpClient', () {
    test('records the response on the span under current semconv', () async {
      final client = OTelHttpClient(
        MockClient((_) async => http.Response('{}', 200)),
      );

      await client.get(Uri.parse('https://api.example.com:8443/v1/users?q=1'));
      final span = await onlySpan();

      expect(span.attributes.getString('url.full'),
          'https://api.example.com:8443/v1/users?q=1');
      expect(span.attributes.getString('http.request.method'), 'GET');
      expect(span.attributes.getString('server.address'), 'api.example.com');
      expect(span.attributes.getInt('server.port'), 8443);
      // Regression: this used to be set on a discarded copy and never arrive.
      expect(span.attributes.getInt('http.response.status_code'), 200);
      expect(span.status, SpanStatusCode.Ok);
    });

    test('tags the span with event.type, not an "xhr" key', () async {
      // Regression: 1.0.6 set the constant to 'xhr', producing `xhr=xhr`.
      final client = OTelHttpClient(
        MockClient((_) async => http.Response('{}', 200)),
      );

      await client.get(Uri.parse('https://api.example.com/v1/users'));
      final span = await onlySpan();

      expect(span.attributes.getString('event.type'), 'xhr');
      expect(span.attributes.keys, isNot(contains('xhr')));
    });

    test('exports a 4xx/5xx response as an error', () async {
      // Regression: an unconditional setStatus(Ok) overwrote the Error, since
      // OK always wins, so failed requests were exported as OK.
      final client = OTelHttpClient(
        MockClient((_) async => http.Response('nope', 503)),
      );

      await client.get(Uri.parse('https://api.example.com/v1/users'));
      final span = await onlySpan();

      expect(span.attributes.getInt('http.response.status_code'), 503);
      expect(span.status, SpanStatusCode.Error);
    });

    test('records error.type when the request throws', () async {
      final client = OTelHttpClient(
        MockClient((_) async => throw http.ClientException('connection reset')),
      );

      await expectLater(
        client.get(Uri.parse('https://api.example.com/v1/users')),
        throwsA(isA<http.ClientException>()),
      );
      final span = await onlySpan();

      expect(span.attributes.getString('error.type'), 'ClientException');
      expect(span.status, SpanStatusCode.Error);
    });

    test('names the span like the browser SDK: METHOD host/path', () async {
      final client = OTelHttpClient(
        MockClient((_) async => http.Response('{}', 200)),
      );

      await client.post(
          Uri.parse('https://api.example.com:8443/v1/users?token=secret#x'));
      final span = await onlySpan();

      // Regression: was `HTTP POST https://api.example.com:8443/v1/...?token=`.
      expect(span.name, 'POST api.example.com:8443/v1/users');
    });

    test('names a root URL with a "/" path and no default port', () async {
      final client = OTelHttpClient(
        MockClient((_) async => http.Response('{}', 200)),
      );

      await client.get(Uri.parse('https://api.example.com:443'));
      final span = await onlySpan();

      expect(span.name, 'GET api.example.com/');
    });

    group('propagation', () {
      Future<Map<String, String>> headersSent(
          TracePropagationFormat? format) async {
        late Map<String, String> sent;
        final client = OTelHttpClient(
          MockClient((request) async {
            sent = request.headers;
            return http.Response('{}', 200);
          }),
          config: format == null
              ? const HttpInstrumentationConfig()
              : HttpInstrumentationConfig(tracePropagationFormat: format),
        );
        await client.get(Uri.parse('https://api.example.com/v1/users'));
        return sent;
      }

      test('sends traceparent and both B3 encodings by default', () async {
        final headers = await headersSent(null);
        final span = await onlySpan();
        final traceId = span.spanContext.traceId.hexString;
        final spanId = span.spanContext.spanId.hexString;

        // The server's parent must be the HTTP span itself.
        expect(headers['traceparent'], '00-$traceId-$spanId-01');
        expect(headers['b3'], '$traceId-$spanId-1');
        expect(headers['x-b3-traceid'], traceId);
        expect(headers['x-b3-spanid'], spanId);
        expect(headers['x-b3-sampled'], '1');
      });

      test('w3c sends only traceparent', () async {
        final headers = await headersSent(TracePropagationFormat.w3c);
        expect(headers, contains('traceparent'));
        expect(headers.keys.where((k) => k.startsWith('x-b3') || k == 'b3'),
            isEmpty);
      });

      test('b3 sends only B3 headers', () async {
        final headers = await headersSent(TracePropagationFormat.b3);
        expect(headers, isNot(contains('traceparent')));
        expect(headers, containsPair('x-b3-sampled', '1'));
        expect(headers, contains('b3'));
      });

      test('continues the trace of the active span', () async {
        final parent = OTel.tracer().startSpan('screen');
        late Map<String, String> sent;
        final client = OTelHttpClient(MockClient((request) async {
          sent = request.headers;
          return http.Response('{}', 200);
        }));

        await Context.current
            .withSpan(parent)
            .run(() => client.get(Uri.parse('https://api.example.com/a')));
        parent.end();

        final traceId = parent.spanContext.traceId.hexString;
        expect(sent['traceparent'], startsWith('00-$traceId-'));
        expect(sent['b3'], startsWith('$traceId-'));
      });
    });

    test('records the response body size when captured', () async {
      final client = OTelHttpClient(
        MockClient((_) async => http.Response('0123456789', 200)),
        config: const HttpInstrumentationConfig(captureResponseBodySize: true),
      );

      await client.get(Uri.parse('https://api.example.com/v1/users'));
      final span = await onlySpan();

      expect(span.attributes.getInt('http.response.body.size'), 10);
    });
  });

  group('OTelDioInterceptor', () {
    late _FakeAdapter adapter;

    Dio dioAnswering(int statusCode) {
      adapter = _FakeAdapter(statusCode);
      final dio = Dio()..httpClientAdapter = adapter;
      dio.interceptors.add(OTelDioInterceptor());
      return dio;
    }

    test('lets the request through and propagates trace context', () async {
      // Regression: injecting into Dio's Map<String, dynamic> headers failed a
      // runtime type check and turned every request into a DioException.
      final response =
          await dioAnswering(200).get<Object>('https://api.example.com/v1/a');

      expect(response.statusCode, 200);
      expect(adapter.lastHeaders['traceparent'], isA<String>());
      expect(adapter.lastHeaders['b3'], isA<String>());
      expect(adapter.lastHeaders['x-b3-traceid'], isA<String>());
    });

    test('honours tracePropagationFormat', () async {
      adapter = _FakeAdapter(200);
      final dio = Dio()..httpClientAdapter = adapter;
      dio.interceptors.add(OTelDioInterceptor(
        config: const HttpInstrumentationConfig(
            tracePropagationFormat: TracePropagationFormat.b3),
      ));

      await dio.get<Object>('https://api.example.com/v1/a');

      expect(adapter.lastHeaders, isNot(contains('traceparent')));
      expect(adapter.lastHeaders['b3'], isA<String>());
    });

    test('names the span like the browser SDK: METHOD host/path', () async {
      await dioAnswering(200)
          .get<Object>('https://api.example.com/v1/users?token=secret');
      final span = await onlySpan();

      expect(span.name, 'GET api.example.com/v1/users');
    });

    test('records the response on the span under current semconv', () async {
      await dioAnswering(200).get<Object>('https://api.example.com/v1/users');
      final span = await onlySpan();

      expect(span.attributes.getString('url.full'),
          'https://api.example.com/v1/users');
      expect(span.attributes.getString('http.request.method'), 'GET');
      expect(span.attributes.getString('event.type'), 'xhr');
      // Regression: set on a discarded copy and never arrived.
      expect(span.attributes.getInt('http.response.status_code'), 200);
      expect(span.status, SpanStatusCode.Ok);
    });

    test('records status and error.type for a failed response', () async {
      // Dio rejects a 404 by default, which goes through onError.
      await expectLater(
        dioAnswering(404).get<Object>('https://api.example.com/v1/missing'),
        throwsA(isA<DioException>()),
      );
      final span = await onlySpan();

      expect(span.attributes.getInt('http.response.status_code'), 404);
      expect(span.attributes.getString('error.type'), isNotNull);
      expect(span.status, SpanStatusCode.Error);
    });
  });
}
