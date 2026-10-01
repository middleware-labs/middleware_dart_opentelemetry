// Licensed under the Apache License, Version 2.0

import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';

import '../otel.dart';

/// Which B3 header layout [B3Propagator] writes.
enum B3InjectEncoding {
  /// One `b3: {traceId}-{spanId}-{sampled}` header.
  single,

  /// `x-b3-traceid`, `x-b3-spanid` and `x-b3-sampled` headers.
  multi,
}

/// Zipkin B3 propagation, as specified at https://github.com/openzipkin/b3-propagation.
///
/// Injection writes one encoding (see [B3InjectEncoding]); extraction reads
/// either, preferring the single `b3` header when both are present. Header
/// names are lower case, matching `@opentelemetry/propagator-b3`.
class B3Propagator implements TextMapPropagator<Map<String, String>, String> {
  /// Creates a B3 propagator that injects [injectEncoding].
  B3Propagator({this.injectEncoding = B3InjectEncoding.single});

  /// The header layout written by [inject].
  final B3InjectEncoding injectEncoding;

  static const _b3 = 'b3';
  static const _traceId = 'x-b3-traceid';
  static const _spanId = 'x-b3-spanid';
  static const _sampled = 'x-b3-sampled';
  static const _flags = 'x-b3-flags';

  static final _hex = RegExp(r'^[0-9a-f]+$');

  @override
  List<String> fields() => injectEncoding == B3InjectEncoding.single
      ? const [_b3]
      : const [_traceId, _spanId, _sampled, _flags];

  @override
  void inject(
    Context context,
    Map<String, String> carrier,
    TextMapSetter<String> setter,
  ) {
    final spanContext = context.spanContext;
    if (spanContext == null || !spanContext.isValid) return;

    final traceId = spanContext.traceId.hexString;
    final spanId = spanContext.spanId.hexString;
    final sampled = spanContext.traceFlags.isSampled ? '1' : '0';

    if (injectEncoding == B3InjectEncoding.single) {
      setter.set(_b3, '$traceId-$spanId-$sampled');
    } else {
      setter.set(_traceId, traceId);
      setter.set(_spanId, spanId);
      setter.set(_sampled, sampled);
    }
  }

  @override
  Context extract(
    Context context,
    Map<String, String> carrier,
    TextMapGetter<String> getter,
  ) {
    final spanContext = _extractSingle(getter) ?? _extractMulti(getter);
    if (spanContext == null) return context;
    return context.withSpanContext(spanContext);
  }

  /// `{traceId}-{spanId}[-{sampling}[-{parentSpanId}]]`. A bare sampling
  /// state (`0`, `1`, `d`) carries no ids, so there is nothing to extract.
  SpanContext? _extractSingle(TextMapGetter<String> getter) {
    final value = getter.get(_b3)?.trim().toLowerCase();
    if (value == null || value.isEmpty) return null;

    final parts = value.split('-');
    if (parts.length < 2 || parts.length > 4) return null;

    final sampling = parts.length >= 3 ? parts[2] : null;
    return _spanContext(parts[0], parts[1], _isSampled(sampling, null));
  }

  SpanContext? _extractMulti(TextMapGetter<String> getter) {
    final traceId = getter.get(_traceId)?.trim().toLowerCase();
    final spanId = getter.get(_spanId)?.trim().toLowerCase();
    if (traceId == null || spanId == null) return null;

    final sampled = _isSampled(
      getter.get(_sampled)?.trim().toLowerCase(),
      getter.get(_flags)?.trim(),
    );
    return _spanContext(traceId, spanId, sampled);
  }

  /// Debug (`d`, or `x-b3-flags: 1`) implies sampled. `true` is the legacy
  /// spelling some tracers still send.
  bool _isSampled(String? sampling, String? flags) =>
      flags == '1' || sampling == '1' || sampling == 'd' || sampling == 'true';

  SpanContext? _spanContext(String traceIdHex, String spanIdHex, bool sampled) {
    // B3 allows 64-bit trace ids; OTel's are 128-bit, so left-pad them.
    if (traceIdHex.length == 16) traceIdHex = traceIdHex.padLeft(32, '0');
    if (traceIdHex.length != 32 || !_hex.hasMatch(traceIdHex)) return null;
    if (spanIdHex.length != 16 || !_hex.hasMatch(spanIdHex)) return null;

    try {
      final traceId = OTel.traceIdFrom(traceIdHex);
      final spanId = OTel.spanIdFrom(spanIdHex);
      if (!traceId.isValid || !spanId.isValid) return null;

      return OTel.spanContext(
        traceId: traceId,
        spanId: spanId,
        traceFlags: sampled ? TraceFlags.sampled : TraceFlags.none,
        isRemote: true,
      );
    } catch (e) {
      if (OTelLog.isDebug()) OTelLog.debug('Error parsing B3 headers: $e');
      return null;
    }
  }
}
