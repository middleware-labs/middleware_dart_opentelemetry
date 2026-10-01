// Licensed under the Apache License, Version 2.0

import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart';
import 'package:test/test.dart';

const _traceId = '4bf92f3577b34da6a3ce929d0e0e4736';
const _spanId = '00f067aa0ba902b7';

class _Getter implements TextMapGetter<String> {
  _Getter(this._carrier);
  final Map<String, String> _carrier;

  @override
  String? get(String key) => _carrier[key];

  @override
  Iterable<String> keys() => _carrier.keys;
}

class _Setter extends TextMapSetter<String> {
  _Setter(this._carrier);
  final Map<String, String> _carrier;

  @override
  void set(String key, String value) => _carrier[key] = value;
}

void main() {
  setUpAll(() async {
    await OTel.initialize(
      serviceName: 'test-service',
      endpoint: 'http://localhost:4317',
    );
  });

  tearDownAll(() async {
    await OTel.reset();
  });

  Context contextWith({required bool sampled}) => OTel.context(
        spanContext: OTel.spanContext(
          traceId: OTel.traceIdFrom(_traceId),
          spanId: OTel.spanIdFrom(_spanId),
          traceFlags: sampled ? TraceFlags.sampled : TraceFlags.none,
        ),
      );

  Map<String, String> inject(B3Propagator propagator, Context context) {
    final carrier = <String, String>{};
    propagator.inject(context, carrier, _Setter(carrier));
    return carrier;
  }

  SpanContext? extract(Map<String, String> carrier) => B3Propagator()
      .extract(OTel.context(), carrier, _Getter(carrier))
      .spanContext;

  group('inject', () {
    test('writes the single b3 header by default', () {
      expect(inject(B3Propagator(), contextWith(sampled: true)), {
        'b3': '$_traceId-$_spanId-1',
      });
    });

    test('writes the multi x-b3-* headers', () {
      final propagator = B3Propagator(injectEncoding: B3InjectEncoding.multi);
      expect(inject(propagator, contextWith(sampled: true)), {
        'x-b3-traceid': _traceId,
        'x-b3-spanid': _spanId,
        'x-b3-sampled': '1',
      });
    });

    test('carries an unsampled decision', () {
      expect(inject(B3Propagator(), contextWith(sampled: false))['b3'],
          '$_traceId-$_spanId-0');
    });

    test('writes nothing without a valid span context', () {
      expect(inject(B3Propagator(), OTel.context()), isEmpty);
    });
  });

  group('extract', () {
    test('reads the single header', () {
      final ctx = extract({'b3': '$_traceId-$_spanId-1'})!;
      expect(ctx.traceId.hexString, _traceId);
      expect(ctx.spanId.hexString, _spanId);
      expect(ctx.traceFlags.isSampled, isTrue);
      expect(ctx.isRemote, isTrue);
    });

    test('reads the multi headers', () {
      final ctx = extract({
        'x-b3-traceid': _traceId,
        'x-b3-spanid': _spanId,
        'x-b3-sampled': '0',
      })!;
      expect(ctx.traceId.hexString, _traceId);
      expect(ctx.traceFlags.isSampled, isFalse);
    });

    test('left-pads a 64-bit trace id', () {
      final ctx = extract({'b3': 'a3ce929d0e0e4736-$_spanId-d'})!;
      expect(ctx.traceId.hexString, '0000000000000000a3ce929d0e0e4736');
      expect(ctx.traceFlags.isSampled, isTrue, reason: 'debug implies sampled');
    });

    test('round-trips what it injects', () {
      final carrier = inject(B3Propagator(), contextWith(sampled: true));
      expect(extract(carrier)!.spanId.hexString, _spanId);
    });

    test('ignores a bare sampling decision and malformed ids', () {
      expect(extract({'b3': '0'}), isNull);
      expect(extract({'b3': 'xyz-$_spanId-1'}), isNull);
      expect(extract({'b3': '$_traceId-0000000000000000-1'}), isNull);
      expect(extract({}), isNull);
    });
  });
}
