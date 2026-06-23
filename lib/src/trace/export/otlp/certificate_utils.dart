// Licensed under the Apache License, Version 2.0
// Copyright 2025, Michael Bushe, All rights reserved.

import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart';

export 'certificate_utils_stub.dart'
    if (dart.library.io) 'certificate_utils_io.dart';
