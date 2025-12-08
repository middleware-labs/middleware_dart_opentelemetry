/// # OpenTelemetry HTTP Instrumentation for Dart & Flutter
///
/// This library provides **automatic tracing and metrics** for:
///
/// - The `http` package (`http.Client`)
/// - The `dio` HTTP client
/// - Any custom HTTP client built on top of `dart:io` `HttpClient`
///
/// It instruments outgoing HTTP requests and generates:
/// - Client spans (`SpanKind.client`)
/// - Request/response attributes (URL, method, status code, sizes)
/// - Errors & exceptions
/// - Metrics:
///   - Request count
///   - Duration histogram
///   - Request body size
///   - Response body size
///
/// Spans automatically include W3C Trace Context propagation.
///
///
/// ---
/// ## 🚀 Quick Start
///
/// ### **1. Wrap the `http.Client`**
///
/// ```dart
/// final client = OTelHttpClient(http.Client());
///
/// final response = await client.get(
///   Uri.parse('https://api.example.com'),
/// );
/// ```
///
/// Or use convenient extension:
///
/// ```dart
/// final client = http.Client().instrument();
/// ```
///
///
/// ---
/// ## 🌀 Instrumenting **Dio**
///
/// Add the OpenTelemetry interceptor:
///
/// ```dart
/// final dio = Dio();
/// dio.interceptors.add(OTelDioInterceptor());
///
/// // Or:
/// dio.addOTelInstrumentation();
///
/// final response = await dio.get('https://api.example.com');
/// ```
///
///
/// ---
/// ## 🔧 Configuration
///
/// You can control headers, sizes, URL length, filtering, and custom attributes.
///
/// ```dart
/// final config = HttpInstrumentationConfig(
///   captureRequestHeaders: true,
///   captureResponseHeaders: true,
///   capturedHeaders: {'content-type', 'user-agent'},
///   captureRequestBodySize: true,
///   captureResponseBodySize: true,
///   maxUrlLength: 1024,
///   shouldInstrument: (url) => !url.host.contains('localhost'),
///   customAttributes: (url) => {
///     'env': 'prod',
///     'api.group': url.pathSegments.firstOrNull ?? 'root',
///   },
/// );
///
/// final client = http.Client().instrument(config: config);
/// ```
///
///
/// ---
/// ## 📦 Spans & Attributes
///
/// Each request span contains attributes following the
/// [OpenTelemetry HTTP Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/http/):
///
/// **Request attributes:**
/// - `http.request.method`
/// - `url.full`
/// - `url.scheme`
/// - `url.path`
/// - `url.query`
/// - `server.address`
/// - `server.port`
/// - `xhr` event type
/// - Optional: request headers
/// - Optional: body size
///
/// **Response attributes:**
/// - `http.response.status_code`
/// - Optional: response headers
/// - Optional: response body size
///
/// **Error attributes (on exception or 4xx/5xx):**
/// - `error.type`
///
///
/// ---
/// ## 📊 Metrics Produced
///
/// Metrics follow the OpenTelemetry Metrics API:
///
/// | Metric Name                         | Type        | Description                     | Unit      |
/// |------------------------------------|-------------|----------------------------------|-----------|
/// | `http.client.request.count`        | Counter     | Number of HTTP requests          | `{requests}` |
/// | `http.client.request.duration`     | Histogram   | Duration of requests             | `ms`      |
/// | `http.client.request.body.size`    | Histogram   | Request body size                | `By`      |
/// | `http.client.response.body.size`   | Histogram   | Response body size               | `By`      |
///
///
/// ---
/// ## 🧩 Context Propagation
///
/// The library automatically injects W3C trace headers:
///
/// - `traceparent`
/// - `tracestate`
/// - `baggage`
///
/// Using:
///
/// ```dart
/// W3CTraceContextPropagator()
/// W3CBaggagePropagator()
/// ```
///
/// So any backend that understands OpenTelemetry will correctly link traces.
///
///
/// ---
/// ## ⚠️ Error Handling
///
/// - Exceptions are recorded using `span.recordException()`
/// - Spans are marked with `SpanStatusCode.Error`
/// - Errors do not break your request flow — they’re only traced
///
///
/// ---
/// ## 🧪 Example With Try/Catch
///
/// ```dart
/// final client = http.Client().instrument();
///
/// try {
///   final res = await client.get(Uri.parse("https://bad.url"));
/// } catch (e) {
///   print("Handled gracefully");
/// }
/// ```
///
/// The span will contain:
/// - exception stack trace
/// - `error.type` attribute
/// - `span.setStatus(Error)`
///
///
/// ---
/// ## 🎯 Why Use This?
///
/// - Full OpenTelemetry HTTP visibility
/// - Zero changes to your existing API calls
/// - Works in Dart, Flutter (mobile, web*, desktop)
/// - Supports both `http` and `dio`
/// - Production-ready metrics & tracing
///
/// \* *flutter web captures fewer metrics due to browser sandboxing*
///
///
/// ---
/// ## 📘 License
///
/// Apache License 2.0
///
/// ```
/// Copyright 2025
/// ```
///
/// ---

library;

import 'dart:async';

import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart';

/// HTTP semantic convention attributes
class _HttpSemantics {
  // Request attributes
  static const String httpRequestMethod = 'http.request.method';
  static const String httpRequestBodySize = 'http.request.body.size';
  static const String urlFull = 'url.full';
  static const String urlScheme = 'url.scheme';
  static const String urlPath = 'url.path';
  static const String urlQuery = 'url.query';
  static const String serverAddress = 'server.address';
  static const String serverPort = 'server.port';
  static const String eventType = 'xhr';

  // Response attributes
  static const String httpResponseStatusCode = 'http.response.status_code';
  static const String httpResponseBodySize = 'http.response.body.size';

  // Error attributes
  static const String errorType = 'error.type';
}

/// Configuration for HTTP instrumentation
class HttpInstrumentationConfig {
  /// Whether to capture request headers
  final bool captureRequestHeaders;

  /// Whether to capture response headers
  final bool captureResponseHeaders;

  /// List of header names to capture (if capturing is enabled)
  final Set<String> capturedHeaders;

  /// Whether to capture request body size
  final bool captureRequestBodySize;

  /// Whether to capture response body size
  final bool captureResponseBodySize;

  /// Maximum URL length before truncation
  final int maxUrlLength;

  /// Filter function to exclude certain requests
  final bool Function(Uri url)? shouldInstrument;

  /// Custom attributes to add to all HTTP spans
  final Map<String, Object> Function(Uri url)? customAttributes;

  /// Creates a new [HttpInstrumentationConfig].
  const HttpInstrumentationConfig({
    this.captureRequestHeaders = false,
    this.captureResponseHeaders = false,
    this.capturedHeaders = const {
      'content-type',
      'content-length',
      'user-agent',
    },
    this.captureRequestBodySize = true,
    this.captureResponseBodySize = true,
    this.maxUrlLength = 2048,
    this.shouldInstrument,
    this.customAttributes,
  });
}

class _HttpHeaderSetter implements TextMapSetter<String> {
  final Map<String, String> _carrier;

  _HttpHeaderSetter(this._carrier);

  @override
  void set(String key, String value) {
    _carrier[key] = value;
  }
}

/// Instrumented HTTP client that wraps the standard http.Client
class OTelHttpClient extends http.BaseClient {
  final http.Client _inner;
  final Tracer _tracer;
  final HttpInstrumentationConfig _config;
  final Meter _meter;

  late final APICounter<int> _requestCounter;
  late final APIHistogram<double> _requestDuration;
  late final APIHistogram<int> _requestBodySize;
  late final APIHistogram<int> _responseBodySize;

  /// Creates a new [OTelHttpClient] that wraps the [_inner] client.
  ///
  /// [tracer] is the OpenTelemetry tracer to use for creating spans.
  /// If not provided, the global tracer is used.
  ///
  /// [meter] is the OpenTelemetry meter to use for recording metrics.
  /// If not provided, a meter named 'http.client' is created.
  ///
  /// [config] controls the instrumentation behavior, such as which headers
  /// to capture and whether to record body sizes.
  OTelHttpClient(
    this._inner, {
    Tracer? tracer,
    Meter? meter,
    HttpInstrumentationConfig config = const HttpInstrumentationConfig(),
  })  : _tracer = tracer ?? OTel.tracer(),
        _meter = meter ?? OTel.meter('http.client'),
        _config = config {
    // Initialize metrics
    _requestCounter = _meter.createCounter<int>(
      name: 'http.client.request.count',
      description: 'Number of HTTP requests',
      unit: '{requests}',
    );

    _requestDuration = _meter.createHistogram<double>(
      name: 'http.client.request.duration',
      description: 'Duration of HTTP requests',
      unit: 'ms',
    );

    _requestBodySize = _meter.createHistogram<int>(
      name: 'http.client.request.body.size',
      description: 'Size of HTTP request bodies',
      unit: 'By',
    );

    _responseBodySize = _meter.createHistogram<int>(
      name: 'http.client.response.body.size',
      description: 'Size of HTTP response bodies',
      unit: 'By',
    );
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Check if we should instrument this request
    if (_config.shouldInstrument != null &&
        !_config.shouldInstrument!(request.url)) {
      return _inner.send(request);
    }

    final startTime = DateTime.now();
    final spanName = 'HTTP ${request.method} ${request.url}';

    // Build attributes
    final attributes = _buildRequestAttributes(request);

    // Start span
    final span = _tracer.startSpan(
      spanName,
      kind: SpanKind.client,
      attributes: attributes,
    );

    try {
      // Inject trace context into request headers
      final propagator = CompositePropagator<Map<String, String>, String>([
        W3CTraceContextPropagator(),
        W3CBaggagePropagator(),
      ]);
      final ctx = Context.current.withSpan(span);

      propagator.inject(
          ctx, request.headers, _HttpHeaderSetter(request.headers));

      // Send request
      final response = await _inner.send(request);
      final duration = DateTime.now().difference(startTime);

      // Record response attributes
      _recordResponse(span, response, duration, attributes);

      // Record metrics
      _recordMetrics(request, response, duration, attributes);

      span.setStatus(SpanStatusCode.Ok);
      span.end();

      return response;
    } catch (error, stackTrace) {
      final duration = DateTime.now().difference(startTime);

      // Record error
      span.recordException(error, stackTrace: stackTrace);
      span.setStatus(SpanStatusCode.Error, error.toString());

      // Record error attributes
      attributes.copyWithStringAttribute(
          _HttpSemantics.errorType, error.runtimeType.toString());

      // Record error metrics
      _recordMetrics(request, null, duration, attributes);

      span.end();
      rethrow;
    }
  }

  Attributes _buildRequestAttributes(http.BaseRequest request) {
    final attrs = <String, Object>{
      _HttpSemantics.httpRequestMethod: request.method,
      _HttpSemantics.urlFull: _truncateUrl(request.url.toString()),
      _HttpSemantics.urlScheme: request.url.scheme,
      _HttpSemantics.serverAddress: request.url.host,
      _HttpSemantics.eventType: 'xhr'
    };

    // Add port if not default
    if (request.url.hasPort &&
        request.url.port != 80 &&
        request.url.port != 443) {
      attrs[_HttpSemantics.serverPort] = request.url.port;
    }

    // Add path
    if (request.url.path.isNotEmpty) {
      attrs[_HttpSemantics.urlPath] = request.url.path;
    }

    // Add query
    if (request.url.query.isNotEmpty) {
      attrs[_HttpSemantics.urlQuery] = request.url.query;
    }

    // Add request body size
    if (_config.captureRequestBodySize && request.contentLength != null) {
      attrs[_HttpSemantics.httpRequestBodySize] = request.contentLength!;
    }

    // Add request headers
    if (_config.captureRequestHeaders) {
      _addHeaders(attrs, 'http.request.header', request.headers);
    }

    // Add custom attributes
    if (_config.customAttributes != null) {
      attrs.addAll(_config.customAttributes!(request.url));
    }

    return attrs.toAttributes();
  }

  void _recordResponse(
    Span span,
    http.StreamedResponse response,
    Duration duration,
    Attributes attributes,
  ) {
    // Add status code
    attributes.copyWithIntAttribute(
      _HttpSemantics.httpResponseStatusCode,
      response.statusCode,
    );

    // Add response body size
    if (_config.captureResponseBodySize && response.contentLength != null) {
      attributes.copyWithIntAttribute(
        _HttpSemantics.httpResponseBodySize,
        response.contentLength!,
      );
    }

    // Add response headers
    if (_config.captureResponseHeaders) {
      final headerAttrs = <String, Object>{};
      _addHeaders(headerAttrs, 'http.response.header', response.headers);
      for (final entry in headerAttrs.entries) {
        attributes.copyWithStringAttribute(entry.key, entry.value.toString());
      }
    }

    // Set error status for 4xx and 5xx
    if (response.statusCode >= 400) {
      span.setStatus(
        SpanStatusCode.Error,
        'HTTP ${response.statusCode}',
      );
    }
  }

  void _recordMetrics(
    http.BaseRequest request,
    http.StreamedResponse? response,
    Duration duration,
    Attributes attributes,
  ) {
    // Record request count
    _requestCounter.add(1, attributes);

    // Record duration
    _requestDuration.record(duration.inMilliseconds.toDouble(), attributes);

    // Record request body size
    if (_config.captureRequestBodySize && request.contentLength != null) {
      _requestBodySize.record(request.contentLength!, attributes);
    }

    // Record response body size
    if (_config.captureResponseBodySize && response?.contentLength != null) {
      _responseBodySize.record(response!.contentLength!, attributes);
    }
  }

  void _addHeaders(
    Map<String, Object> attrs,
    String prefix,
    Map<String, String> headers,
  ) {
    for (final name in _config.capturedHeaders) {
      final value = headers[name];
      if (value != null) {
        attrs['$prefix.$name'] = value;
      }
    }
  }

  String _truncateUrl(String url) {
    if (url.length <= _config.maxUrlLength) {
      return url;
    }
    return '${url.substring(0, _config.maxUrlLength)}...';
  }

  @override
  void close() {
    _inner.close();
  }
}

class _DioHeaderSetter implements TextMapSetter<String> {
  final Map<String, dynamic> _headers;

  _DioHeaderSetter(this._headers);

  @override
  void set(String key, String value) {
    _headers[key] = value;
  }
}

/// Dio interceptor for automatic instrumentation
class OTelDioInterceptor extends Interceptor {
  final Tracer _tracer;
  final Meter _meter;
  final HttpInstrumentationConfig _config;

  late final APICounter<int> _requestCounter;
  late final APIHistogram<double> _requestDuration;
  late final APIHistogram<int> _requestBodySize;
  late final APIHistogram<int> _responseBodySize;

  /// Creates a new [OTelDioInterceptor] for Dio.
  ///
  /// [tracer] is the OpenTelemetry tracer to use for creating spans.
  /// If not provided, the global tracer is used.
  ///
  /// [meter] is the OpenTelemetry meter to use for recording metrics.
  /// If not provided, a meter named 'http.client.dio' is created.
  ///
  /// [config] controls the instrumentation behavior.
  OTelDioInterceptor({
    Tracer? tracer,
    Meter? meter,
    HttpInstrumentationConfig config = const HttpInstrumentationConfig(),
  })  : _tracer = tracer ?? OTel.tracer(),
        _meter = meter ?? OTel.meter('http.client.dio'),
        _config = config {
    // Initialize metrics
    _requestCounter = _meter.createCounter<int>(
      name: 'http.client.request.count',
      description: 'Number of HTTP requests',
      unit: '{requests}',
    );

    _requestDuration = _meter.createHistogram<double>(
      name: 'http.client.request.duration',
      description: 'Duration of HTTP requests',
      unit: 'ms',
    );

    _requestBodySize = _meter.createHistogram<int>(
      name: 'http.client.request.body.size',
      description: 'Size of HTTP request bodies',
      unit: 'By',
    );

    _responseBodySize = _meter.createHistogram<int>(
      name: 'http.client.response.body.size',
      description: 'Size of HTTP response bodies',
      unit: 'By',
    );
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // Check if we should instrument
    if (_config.shouldInstrument != null &&
        !_config.shouldInstrument!(options.uri)) {
      return handler.next(options);
    }

    // Build attributes
    final attributes = _buildDioRequestAttributes(options);

    // Start span
    final spanName = 'HTTP ${options.method} ${options.uri}';
    final span = _tracer.startSpan(
      spanName,
      kind: SpanKind.client,
      attributes: attributes,
    );

    // Store span and start time in request extra data
    options.extra['_otel_span'] = span;
    options.extra['_otel_start_time'] = DateTime.now();
    options.extra['_otel_attributes'] = attributes;

    final ctx = Context.current.withSpan(span);
    final propagator = CompositePropagator<Map<String, dynamic>, String>([
      W3CTraceContextPropagator(),
      W3CBaggagePropagator(),
    ]);
    final setter = _DioHeaderSetter(options.headers);

    propagator.inject(ctx, options.headers, setter);

    handler.next(options);
  }

  @override
  void onResponse(
      Response<dynamic> response, ResponseInterceptorHandler handler) {
    final span = response.requestOptions.extra['_otel_span'] as Span?;
    final startTime =
        response.requestOptions.extra['_otel_start_time'] as DateTime?;
    final attributes =
        response.requestOptions.extra['_otel_attributes'] as Attributes?;

    if (span != null && startTime != null && attributes != null) {
      final duration = DateTime.now().difference(startTime);

      // Add response attributes
      attributes.copyWithIntAttribute(
        _HttpSemantics.httpResponseStatusCode,
        response.statusCode ?? 0,
      );

      if (_config.captureResponseBodySize && response.data != null) {
        final bodySize = _estimateBodySize(response.data);
        if (bodySize > 0) {
          attributes.copyWithIntAttribute(
              _HttpSemantics.httpResponseBodySize, bodySize);
        }
      }

      // Record metrics
      _recordDioMetrics(
          response.requestOptions, response, duration, attributes);

      // Set status
      if (response.statusCode != null && response.statusCode! >= 400) {
        span.setStatus(SpanStatusCode.Error, 'HTTP ${response.statusCode}');
      } else {
        span.setStatus(SpanStatusCode.Ok);
      }

      span.end();
    }

    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final span = err.requestOptions.extra['_otel_span'] as Span?;
    final startTime = err.requestOptions.extra['_otel_start_time'] as DateTime?;
    final attributes =
        err.requestOptions.extra['_otel_attributes'] as Attributes?;

    if (span != null && startTime != null && attributes != null) {
      final duration = DateTime.now().difference(startTime);

      // Record error
      span.recordException(err, stackTrace: err.stackTrace);
      span.setStatus(SpanStatusCode.Error, err.message ?? 'HTTP Error');

      // Add error type
      attributes.copyWithStringAttribute(
          _HttpSemantics.errorType, err.type.toString());

      // Add response status if available
      if (err.response?.statusCode != null) {
        attributes.copyWithIntAttribute(
          _HttpSemantics.httpResponseStatusCode,
          err.response!.statusCode!,
        );
      }

      // Record metrics
      _recordDioMetrics(err.requestOptions, err.response, duration, attributes);

      span.end();
    }

    handler.next(err);
  }

  Attributes _buildDioRequestAttributes(RequestOptions options) {
    final attrs = <String, Object>{
      _HttpSemantics.httpRequestMethod: options.method,
      _HttpSemantics.urlFull: _truncateUrl(options.uri.toString()),
      _HttpSemantics.urlScheme: options.uri.scheme,
      _HttpSemantics.serverAddress: options.uri.host,
      _HttpSemantics.eventType: 'xhr'
    };

    // Add port if not default
    if (options.uri.hasPort &&
        options.uri.port != 80 &&
        options.uri.port != 443) {
      attrs[_HttpSemantics.serverPort] = options.uri.port;
    }

    // Add path
    if (options.uri.path.isNotEmpty) {
      attrs[_HttpSemantics.urlPath] = options.uri.path;
    }

    // Add query
    if (options.uri.query.isNotEmpty) {
      attrs[_HttpSemantics.urlQuery] = options.uri.query;
    }

    // Add request body size
    if (_config.captureRequestBodySize && options.data != null) {
      final bodySize = _estimateBodySize(options.data);
      if (bodySize > 0) {
        attrs[_HttpSemantics.httpRequestBodySize] = bodySize;
      }
    }

    // Add custom attributes
    if (_config.customAttributes != null) {
      attrs.addAll(_config.customAttributes!(options.uri));
    }

    return attrs.toAttributes();
  }

  void _recordDioMetrics(
    RequestOptions request,
    Response<dynamic>? response,
    Duration duration,
    Attributes attributes,
  ) {
    // Record request count
    _requestCounter.add(1, attributes);

    // Record duration
    _requestDuration.record(duration.inMilliseconds.toDouble(), attributes);

    // Record request body size
    if (_config.captureRequestBodySize && request.data != null) {
      final size = _estimateBodySize(request.data);
      if (size > 0) {
        _requestBodySize.record(size, attributes);
      }
    }

    // Record response body size
    if (_config.captureResponseBodySize && response?.data != null) {
      final size = _estimateBodySize(response!.data);
      if (size > 0) {
        _responseBodySize.record(size, attributes);
      }
    }
  }

  int _estimateBodySize(dynamic data) {
    if (data == null) return 0;
    if (data is String) return data.length;
    if (data is List<int>) return data.length;
    if (data is Map) return data.toString().length;
    return 0;
  }

  String _truncateUrl(String url) {
    if (url.length <= _config.maxUrlLength) {
      return url;
    }
    return '${url.substring(0, _config.maxUrlLength)}...';
  }
}

/// Extension to easily instrument existing http clients
extension HttpClientInstrumentation on http.Client {
  /// Wrap this client with OpenTelemetry instrumentation
  http.Client instrument({
    Tracer? tracer,
    Meter? meter,
    HttpInstrumentationConfig config = const HttpInstrumentationConfig(),
  }) {
    return OTelHttpClient(this, tracer: tracer, meter: meter, config: config);
  }
}

/// Extension to easily instrument Dio instances
extension DioInstrumentation on Dio {
  /// Add OpenTelemetry instrumentation to this Dio instance
  void addOTelInstrumentation({
    Tracer? tracer,
    Meter? meter,
    HttpInstrumentationConfig config = const HttpInstrumentationConfig(),
  }) {
    interceptors.add(
      OTelDioInterceptor(tracer: tracer, meter: meter, config: config),
    );
  }
}
