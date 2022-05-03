// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/context.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/globals_null_migrated.dart' as globals;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as path; // flutter_ignore: package_path_import
import 'package:test_api/test_api.dart' as test_package show test; // ignore: deprecated_member_use
import 'package:test_api/test_api.dart' hide test; // ignore: deprecated_member_use

export 'package:test_api/test_api.dart' hide test, isInstanceOf; // ignore: deprecated_member_use

void tryToDelete(Directory directory) {
  // This should not be necessary, but it turns out that
  // on Windows it's common for deletions to fail due to
  // bogus (we think) "access denied" errors.
  try {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  } on FileSystemException catch (error) {
    print('Failed to delete ${directory.path}: $error');
  }
}

/// Gets the path to the root of the Flutter repository.
///
/// This will first look for a `FLUTTER_ROOT` environment variable. If the
/// environment variable is set, it will be returned. Otherwise, this will
/// deduce the path from `platform.script`.
String getFlutterRoot() {
  const Platform platform = LocalPlatform();
  if (platform.environment.containsKey('FLUTTER_ROOT')) {
    return platform.environment['FLUTTER_ROOT']!;
  }

  Error invalidScript() => StateError('Could not determine flutter_tools/ path from script URL (${globals.platform.script}); consider setting FLUTTER_ROOT explicitly.');

  Uri scriptUri;
  switch (platform.script.scheme) {
    case 'file':
      scriptUri = platform.script;
      break;
    case 'data':
      final RegExp flutterTools = RegExp(r'(file://[^"]*[/\\]flutter_tools[/\\][^"]+\.dart)', multiLine: true);
      final Match? match = flutterTools.firstMatch(Uri.decodeFull(platform.script.path));
      if (match == null) {
        throw invalidScript();
      }
      scriptUri = Uri.parse(match.group(1)!);
      break;
    default:
      throw invalidScript();
  }

  final List<String> parts = path.split(globals.localFileSystem.path.fromUri(scriptUri));
  final int toolsIndex = parts.indexOf('flutter_tools');
  if (toolsIndex == -1) {
    throw invalidScript();
  }
  final String toolsPath = path.joinAll(parts.sublist(0, toolsIndex + 1));
  return path.normalize(path.join(toolsPath, '..', '..'));
}

/// Capture console print events into a string buffer.
Future<StringBuffer> capturedConsolePrint(Future<void> Function() body) async {
  final StringBuffer buffer = StringBuffer();
  await runZoned<Future<void>>(() async {
    // Service the event loop.
    await body();
  }, zoneSpecification: ZoneSpecification(print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
    buffer.writeln(line);
  }));
  return buffer;
}

/// Matcher for functions that throw [AssertionError].
final Matcher throwsAssertionError = throwsA(isA<AssertionError>());

/// Matcher for functions that throw [ToolExit].
Matcher throwsToolExit({ int? exitCode, Pattern? message }) {
  Matcher matcher = _isToolExit;
  if (exitCode != null) {
    matcher = allOf(matcher, (ToolExit e) => e.exitCode == exitCode);
  }
  if (message != null) {
    matcher = allOf(matcher, (ToolExit e) => e.message?.contains(message) ?? false);
  }
  return throwsA(matcher);
}

/// Matcher for [ToolExit]s.
final TypeMatcher<ToolExit> _isToolExit = isA<ToolExit>();

/// Matcher for functions that throw [ProcessException].
Matcher throwsProcessException({ Pattern? message }) {
  Matcher matcher = _isProcessException;
  if (message != null) {
    matcher = allOf(matcher, (ProcessException e) => e.message.contains(message));
  }
  return throwsA(matcher);
}

/// Matcher for [ProcessException]s.
final TypeMatcher<ProcessException> _isProcessException = isA<ProcessException>();

Future<void> expectToolExitLater(Future<dynamic> future, Matcher messageMatcher) async {
  try {
    await future;
    fail('ToolExit expected, but nothing thrown');
  } on ToolExit catch(e) {
    expect(e.message, messageMatcher);
  // Catch all exceptions to give a better test failure message.
  } catch (e, trace) { // ignore: avoid_catches_without_on_clauses
    fail('ToolExit expected, got $e\n$trace');
  }
}

Matcher containsIgnoringWhitespace(String toSearch) {
  return predicate(
    (String source) {
      return collapseWhitespace(source).contains(collapseWhitespace(toSearch));
    },
    'contains "$toSearch" ignoring whitespace.',
  );
}

/// The tool overrides `test` to ensure that files created under the
/// system temporary directory are deleted after each test by calling
/// `LocalFileSystem.dispose()`.
@isTest
void test(String description, FutureOr<void> Function() body, {
  String? testOn,
  Timeout? timeout,
  dynamic skip,
  List<String>? tags,
  Map<String, dynamic>? onPlatform,
  int? retry,
}) {
  test_package.test(
    description,
    () async {
      addTearDown(() async {
        await globals.localFileSystem.dispose();
      });
      return body();
    },
    timeout: timeout,
    skip: skip,
    tags: tags,
    onPlatform: onPlatform,
    retry: retry,
    testOn: testOn,
  );
}

/// Executes a test body in zone that does not allow context-based injection.
///
/// For classes which have been refactored to excluded context-based injection
/// or globals like [fs] or [platform], prefer using this test method as it
/// will prevent accidentally including these context getters in future code
/// changes.
///
/// For more information, see https://github.com/flutter/flutter/issues/47161
@isTest
void testWithoutContext(String description, FutureOr<void> Function() body, {
  String? testOn,
  Timeout? timeout,
  dynamic skip,
  List<String>? tags,
  Map<String, dynamic>? onPlatform,
  int? retry,
  }) {
  return test(
    description, () async {
      return runZoned(body, zoneValues: <Object, Object>{
        contextKey: const _NoContext(),
      });
    },
    timeout: timeout,
    skip: skip,
    tags: tags,
    onPlatform: onPlatform,
    retry: retry,
    testOn: testOn,
  );
}

/// An implementation of [AppContext] that throws if context.get is called in the test.
///
/// The intention of the class is to ensure we do not accidentally regress when
/// moving towards more explicit dependency injection by accidentally using
/// a Zone value in place of a constructor parameter.
class _NoContext implements AppContext {
  const _NoContext();

  @override
  T get<T>() {
    throw UnsupportedError(
      'context.get<$T> is not supported in test methods. '
      'Use Testbed or testUsingContext if accessing Zone injected '
      'values.'
    );
  }

  @override
  String get name => 'No Context';

  @override
  Future<V> run<V>({
    required FutureOr<V> Function() body,
    String? name,
    Map<Type, Generator>? overrides,
    Map<Type, Generator>? fallbacks,
    ZoneSpecification? zoneSpecification,
  }) async {
    return body();
  }
}

<<<<<<< HEAD
/// Allows inserting file system exceptions into certain
/// [MemoryFileSystem] operations by tagging path/op combinations.
=======
/// A fake implementation of a vm_service that mocks the JSON-RPC request
/// and response structure.
class FakeVmServiceHost {
  FakeVmServiceHost({
    @required List<VmServiceExpectation> requests,
  }) : _requests = requests {
    _vmService = vm_service.VmService(
      _input.stream,
      _output.add,
    );
    _applyStreamListen();
    _output.stream.listen((String data) {
      final Map<String, Object> request = json.decode(data) as Map<String, Object>;
      if (_requests.isEmpty) {
        throw Exception('Unexpected request: $request');
      }
      final FakeVmServiceRequest fakeRequest = _requests.removeAt(0) as FakeVmServiceRequest;
      expect(request, isA<Map<String, Object>>()
        .having((Map<String, Object> request) => request['method'], 'method', fakeRequest.method)
        .having((Map<String, Object> request) => request['params'], 'args', fakeRequest.args)
      );
      if (fakeRequest.close) {
        _vmService.dispose();
        expect(_requests, isEmpty);
        return;
      }
      if (fakeRequest.errorCode == null) {
        _input.add(json.encode(<String, Object>{
          'jsonrpc': '2.0',
          'id': request['id'],
          'result': fakeRequest.jsonResponse ?? <String, Object>{'type': 'Success'},
        }));
      } else {
        _input.add(json.encode(<String, Object>{
          'jsonrpc': '2.0',
          'id': request['id'],
          'error': <String, Object>{
            'code': fakeRequest.errorCode,
          }
        }));
      }
      _applyStreamListen();
    });
  }

  final List<VmServiceExpectation> _requests;
  final StreamController<String> _input = StreamController<String>();
  final StreamController<String> _output = StreamController<String>();

  vm_service.VmService get vmService => _vmService;
  vm_service.VmService _vmService;

  bool get hasRemainingExpectations => _requests.isNotEmpty;

  // remove FakeStreamResponse objects from _requests until it is empty
  // or until we hit a FakeRequest
  void _applyStreamListen() {
    while (_requests.isNotEmpty && !_requests.first.isRequest) {
      final FakeVmServiceStreamResponse response = _requests.removeAt(0) as FakeVmServiceStreamResponse;
      _input.add(json.encode(<String, Object>{
        'jsonrpc': '2.0',
        'method': 'streamNotify',
        'params': <String, Object>{
          'streamId': response.streamId,
          'event': response.event.toJson(),
        },
      }));
    }
  }
}

abstract class VmServiceExpectation {
  bool get isRequest;
}

class FakeVmServiceRequest implements VmServiceExpectation {
  const FakeVmServiceRequest({
    @required this.method,
    this.args = const <String, Object>{},
    this.jsonResponse,
    this.errorCode,
    this.close = false,
  });

  final String method;

  /// When true, the vm service is automatically closed.
  final bool close;

  /// If non-null, the error code for a [vm_service.RPCError] in place of a
  /// standard response.
  final int errorCode;
  final Map<String, Object> args;
  final Map<String, Object> jsonResponse;

  @override
  bool get isRequest => true;
}

class FakeVmServiceStreamResponse implements VmServiceExpectation {
  const FakeVmServiceStreamResponse({
    @required this.event,
    @required this.streamId,
  });

  final vm_service.Event event;
  final String streamId;

  @override
  bool get isRequest => false;
}

class TestFlutterCommandRunner extends FlutterCommandRunner {
  @override
  Future<void> runCommand(ArgResults topLevelResults) async {
    final Logger topLevelLogger = globals.logger;
    final Map<Type, dynamic> contextOverrides = <Type, dynamic>{
      if (topLevelResults['verbose'] as bool)
        Logger: VerboseLogger(topLevelLogger),
    };
    return context.run<void>(
      overrides: contextOverrides.map<Type, Generator>((Type type, dynamic value) {
        return MapEntry<Type, Generator>(type, () => value);
      }),
      body: () {
        Cache.flutterRoot ??= Cache.defaultFlutterRoot(
          platform: globals.platform,
          fileSystem: globals.fs,
          userMessages: UserMessages(),
        );
        // For compatibility with tests that set this to a relative path.
        Cache.flutterRoot = globals.fs.path.normalize(globals.fs.path.absolute(Cache.flutterRoot));
        return super.runCommand(topLevelResults);
      }
    );
  }
}

/// A file system that allows preconfiguring certain entities.
>>>>>>> 4d7946a68d26794349189cf21b3f68cc6fe61dcb
///
/// Example use:
///
/// ```
/// void main() {
///   var handler = FileExceptionHandler();
///   var fs = MemoryFileSystem(opHandle: handler.opHandle);
///
///   var file = fs.file('foo')..createSync();
///   handler.addError(file, FileSystemOp.read, FileSystemException('Error Reading foo'));
///
///   expect(() => file.writeAsStringSync('A'), throwsA(isA<FileSystemException>()));
/// }
/// ```
class FileExceptionHandler {
  final Map<String, Map<FileSystemOp, FileSystemException>> _contextErrors = <String, Map<FileSystemOp, FileSystemException>>{};

  /// Add an exception that will be thrown whenever the file system attached to this
  /// handler performs the [operation] on the [entity].
  void addError(FileSystemEntity entity, FileSystemOp operation, FileSystemException exception) {
    final String path = entity.path;
    _contextErrors[path] ??= <FileSystemOp, FileSystemException>{};
    _contextErrors[path]![operation] = exception;
  }

  // Tear-off this method and pass it to the memory filesystem `opHandle` parameter.
  void opHandle(String path, FileSystemOp operation) {
    final Map<FileSystemOp, FileSystemException>? exceptions = _contextErrors[path];
    if (exceptions == null) {
      return;
    }
    final FileSystemException? exception = exceptions[operation];
    if (exception == null) {
      return;
    }
    throw exception;
  }
}
