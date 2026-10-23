// Design 06 phase 1b: the group registry is complete and honest.
//
// RED until `kAnalyticsGroupRegistry` declares the real groups. The registry
// is a hand-written claim ("this group's output depends on these files"), so
// the test re-derives the truth from the source and compares:
//
//  (a) the registry validates (ids, deps, cycles, <=3 members, counter >= 1);
//  (b) every member is a real public top-level name of the package;
//  (c) the import closure of each group's member files stays inside the
//      group's own `files` plus those of the foundations it depends on;
//  (d) every lib/src file reachable from any exported function belongs to
//      some group.
//
// HOW (b) KNOWS THE PUBLIC API. The package has no runtime or analyzer
// dependency (pure Dart, zero deps, by design), so the test does not link the
// analyzer. It follows `export` directives from lib/onehz.dart (honouring
// `show`/`hide`, which this package uses) and reads top-level declarations at
// column 0 after stripping comments. That reads the same files the compiler
// does, needs no hand-maintained map to rot, and a rename or a removed export
// fails here. Its one weakness is an unusual top-level layout the regex does
// not see; the sanity test below pins known names so a scanner regression is
// loud rather than silently permissive.
//
// HOW (c)/(d) WALK. Directives `import`, `export`, `part`, `part of` that name
// a lib/src file (relative, or package:openstrap_analytics/src/...) are edges.
// A `part` file is the same compilation unit, so it is an edge both ways.
import 'dart:io';

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

const _registryFile = 'lib/src/onehz/registry/group_registry.dart';
const _pkg = 'package:openstrap_analytics/';

final _root = Directory.current.path;

String _read(String rel) => File('$_root/$rel').readAsStringSync();

String _stripComments(String s) => s
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .replaceAll(RegExp(r'^\s*//.*$', multiLine: true), '');

String _norm(String from, String target) {
  if (target.startsWith(_pkg)) return 'lib/${target.substring(_pkg.length)}';
  final base = from.substring(0, from.lastIndexOf('/'));
  final parts = <String>[...base.split('/')];
  for (final seg in target.split('/')) {
    if (seg == '..') {
      parts.removeLast();
    } else if (seg != '.' && seg.isNotEmpty) {
      parts.add(seg);
    }
  }
  return parts.join('/');
}

/// One whole directive statement; its URIs are pulled out separately because a
/// conditional import/export names several (`'a.dart' if (cond) 'b.dart'`).
final _directive = RegExp(
    r'^(import|export|part of|part)\s+([^;]*);',
    multiLine: true);
final _quoted = RegExp(r'''(['"])(.*?)\1''');

typedef _Directive = ({
  String kind,
  String path,
  List<String> show,
  List<String> hide
});

/// lib/src files named by directive source [src] (the text of [file]), with
/// their kind and filters. Every URI of a conditional directive is an edge
/// (the closure must cover each platform's alternative), and both quote
/// styles are read. `show`/`hide` follow the last URI.
List<_Directive> _parseDirectives(String file, String src) {
  final out = <_Directive>[];
  for (final m in _directive.allMatches(_stripComments(src))) {
    final body = m.group(2)!;
    final uris = _quoted.allMatches(body).toList();
    if (uris.isEmpty) continue; // `part of name;`
    final rest = body.substring(uris.last.end);
    List<String> names(String kw) {
      final mm = RegExp('$kw\\s+([\\w\\s,]+)').firstMatch(rest);
      if (mm == null) return const [];
      return mm.group(1)!.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    }

    for (final u in uris) {
      final target = u.group(2)!;
      if (target.startsWith('dart:')) continue;
      if (target.startsWith('package:') && !target.startsWith(_pkg)) continue;
      final path = _norm(file, target);
      if (!path.startsWith('lib/src/')) continue;
      out.add((kind: m.group(1)!, path: path, show: names('show'), hide: names('hide')));
    }
  }
  return out;
}

List<_Directive> _directives(String file) =>
    _parseDirectives(file, _read(file));

final _typeDecl = RegExp(
    r'^(?:(?:abstract|final|base|sealed|interface|mixin)\s+)*(?:class|mixin|enum|typedef|extension type)\s+(\w+)',
    multiLine: true);
final _fnDecl = RegExp(
    r'^(?!(?:import|export|part|library|class|enum|typedef|const|final|var|late|abstract|mixin|extension|static|return|if|for|while|switch|else|sealed|base|interface)\b)[A-Za-z_][\w<>,?\[\]. ]*?\s(\w+)\s*(?:<[^>(]*>)?\(',
    multiLine: true);

/// Public top-level names declared in [file] itself, split by kind.
({Set<String> fns, Set<String> types}) _declared(String file) {
  final src = _stripComments(_read(file));
  final types = {for (final m in _typeDecl.allMatches(src)) m.group(1)!};
  final fns = {for (final m in _fnDecl.allMatches(src)) m.group(1)!}
    ..removeWhere((n) => n.startsWith('_') || types.contains(n));
  types.removeWhere((n) => n.startsWith('_'));
  return (fns: fns, types: types);
}

/// name -> declaring file, for everything lib/onehz.dart exports (public API).
/// [fnsOnly] keeps top-level functions only (constructors/types excluded).
Map<String, String> _publicApi(
    {bool fnsOnly = false, List<String> libs = const ['lib/onehz.dart']}) {
  final api = <String, String>{};
  final seen = <String>{};
  // Returns the names [file] exposes to an importer.
  Map<String, String> expose(String file) {
    final out = <String, String>{};
    final d = _declared(file);
    for (final n in d.fns) {
      out[n] = file;
    }
    if (!fnsOnly) {
      for (final n in d.types) {
        out[n] = file;
      }
    }
    for (final e in _directives(file).where((e) => e.kind == 'export')) {
      final sub = expose(e.path);
      for (final en in sub.entries) {
        if (e.show.isNotEmpty && !e.show.contains(en.key)) continue;
        if (e.hide.contains(en.key)) continue;
        out[en.key] = en.value;
      }
    }
    return out;
  }

  // The libraries are not under lib/src, so read their exports directly.
  for (final lib in libs) {
    for (final e in _directives(lib).where((e) => e.kind == 'export')) {
      if (!seen.add(e.path)) continue;
      for (final en in expose(e.path).entries) {
        if (e.show.isNotEmpty && !e.show.contains(en.key)) continue;
        if (e.hide.contains(en.key)) continue;
        api[en.key] = en.value;
      }
    }
  }
  return api;
}

/// Every lib/src file reachable from [start] over imports/exports/parts
/// (parts count both ways: a `part of` file belongs to its library).
Set<String> _closure(Iterable<String> start) {
  final seen = <String>{};
  final queue = <String>[...start];
  while (queue.isNotEmpty) {
    final f = queue.removeLast();
    if (!seen.add(f)) continue;
    for (final d in _directives(f)) {
      queue.add(d.path);
    }
  }
  return seen;
}

/// Edge also calls `prsaAggregator`, exported by the second public library
/// (lib/aggregate.dart), so members and api entries may name either.
const _publicLibs = ['lib/onehz.dart', 'lib/aggregate.dart'];

/// Declaring file of member [name] (`fn`, `Type`, or `Type.method`), or null.
String? _memberFile(Map<String, String> api, String name) {
  final dot = name.indexOf('.');
  if (dot < 0) return api[name];
  final file = api[name.substring(0, dot)];
  if (file == null) return null;
  final method = name.substring(dot + 1);
  return _stripComments(_read(file)).contains(RegExp('\\b$method\\s*[(<]'))
      ? file
      : null;
}

/// `name -> group ids` for every name owned by more than one slot: a name in
/// two groups, or in one group's members and api (or twice in either).
Map<String, List<String>> _duplicateOwners(GroupRegistry r) {
  final owners = <String, List<String>>{};
  for (final g in r.groups) {
    for (final m in [...g.members, ...g.api]) {
      (owners[m] ??= <String>[]).add(g.id);
    }
  }
  return owners..removeWhere((_, v) => v.length < 2);
}

Set<String> _transitiveDeps(GroupRegistry r, GroupDecl g) {
  final byId = {for (final x in r.groups) x.id: x};
  final out = <String>{};
  final q = <String>[...g.deps];
  while (q.isNotEmpty) {
    final d = q.removeLast();
    if (d == g.id || !out.add(d)) continue;
    q.addAll(byId[d]?.deps ?? const []);
  }
  return out;
}

const _expectedGroups = [
  'sleep.stage',
  'hrv.freq',
  'night.rhythm',
  'day.blocks',
  'readiness.stress_illness',
  'activity.load',
  'body.spo2_temp_coverage',
];

void main() {
  const reg = kAnalyticsGroupRegistry;

  group('scanner sanity (guards the guard)', () {
    test('finds known public functions and types', () {
      final api = _publicApi();
      expect(api['hrvFreq'], isNotNull);
      expect(api['dispersionBelowQuantum'], isNotNull);
      expect(api['RunningMoments'] ?? api['RrCorrector'], isNotNull);
      expect(_publicApi(fnsOnly: true).length, greaterThan(100));
    });
    test('closure walk reaches transitive imports', () {
      final f = _publicApi()['hrvFreq']!;
      final c = _closure([f]);
      expect(c, contains(f));
      expect(c.length, greaterThan(1));
      expect(_closure(_publicApi(fnsOnly: true).values.toSet()).length,
          greaterThan(60));
    });
    test('hide filters are honoured', () {
      expect(_publicApi().containsKey('readinessLnRmssdFromSuffix'), isFalse);
    });
  });

  group('directive parser (guards the guard)', () {
    const f = 'lib/src/onehz/a.dart';
    List<String> paths(String src) =>
        _parseDirectives(f, src).map((d) => d.path).toList();
    test('reads double-quoted directives', () {
      expect(paths('import "b.dart";\nexport "c/d.dart" show X;'),
          ['lib/src/onehz/b.dart', 'lib/src/onehz/c/d.dart']);
    });
    test('reads every URI of a conditional import', () {
      expect(
          paths("import 'stub.dart'\n    if (dart.library.io) 'io.dart'\n"
              '    if (dart.library.js_interop) "web.dart" as impl;'),
          ['lib/src/onehz/stub.dart', 'lib/src/onehz/io.dart', 'lib/src/onehz/web.dart']);
    });
    test('conditional export keeps show/hide for every alternative', () {
      final d = _parseDirectives(
          f, "export 'a1.dart' if (dart.library.io) 'a2.dart' show Foo, Bar;");
      expect(d.map((e) => e.path),
          ['lib/src/onehz/a1.dart', 'lib/src/onehz/a2.dart']);
      for (final e in d) {
        expect(e.kind, 'export');
        expect(e.show, ['Foo', 'Bar']);
      }
    });
    test('part, part of by URI, package URIs; skips dart: and foreign packages', () {
      expect(
          paths("part 'p.dart';\npart of \"q.dart\";\n"
              "import 'package:openstrap_analytics/src/onehz/z.dart';\n"
              "import 'dart:io';\nimport 'package:other/x.dart';\npart of lib;"),
          ['lib/src/onehz/p.dart', 'lib/src/onehz/q.dart', 'lib/src/onehz/z.dart']);
    });
    test('commented-out directives are ignored', () {
      expect(paths("// import 'gone.dart';\n/* export 'also.dart'; */"), isEmpty);
    });
  });

  group('registry declares the analytics groups', () {
    test('declares every expected algorithm group and >= 1 foundation', () {
      final ids = reg.groups.map((g) => g.id).toSet();
      expect(ids, containsAll(_expectedGroups));
      expect(ids.where((i) => i.startsWith('found.')), isNotEmpty);
    });

    test('(a) validates: unique ids, deps resolve, acyclic, <=3 members, counter>=1', () {
      final problems = <String>[];
      final byId = <String, GroupDecl>{};
      for (final g in reg.groups) {
        if (byId.containsKey(g.id)) problems.add('${g.id}: duplicate id');
        byId[g.id] = g;
        if (g.members.isEmpty) problems.add('${g.id}: no members');
        if (g.members.length > 3) problems.add('${g.id}: >3 members');
        if (g.counter < 1) problems.add('${g.id}: counter < 1');
      }
      for (final g in reg.groups) {
        for (final d in g.deps) {
          if (!byId.containsKey(d)) problems.add('${g.id}: dep $d undeclared');
        }
      }
      final state = <String, int>{};
      void visit(String id) {
        state[id] = 1;
        for (final d in byId[id]!.deps) {
          if (!byId.containsKey(d)) continue;
          if (state[d] == 1) problems.add('$id: cycle through $d');
          if (state[d] == null) visit(d);
        }
        state[id] = 2;
      }

      for (final id in byId.keys) {
        if (state[id] == null) visit(id);
      }
      expect(reg.groups, isNotEmpty, reason: 'registry is empty');
      expect(problems, isEmpty, reason: problems.join('\n'));
    });

    test('every listed file exists under lib/src', () {
      final bad = <String>[];
      for (final g in reg.groups) {
        for (final f in g.files) {
          if (!f.startsWith('lib/src/') || !File('$_root/$f').existsSync()) {
            bad.add('${g.id}: $f');
          }
        }
      }
      expect(reg.groups, isNotEmpty, reason: 'registry is empty');
      expect(bad, isEmpty, reason: bad.join('\n'));
    });
  });

  test('a function is a member or api entry of exactly one group', () {
    final dup = [
      for (final e in _duplicateOwners(reg).entries)
        '${e.key}: ${e.value.join(', ')}',
    ];
    expect(reg.groups, isNotEmpty, reason: 'registry is empty');
    expect(dup, isEmpty, reason: dup.join('\n'));
  });

  group('duplicate-owner check (guards the guard)', () {
    GroupDecl g(String id, List<String> m, [List<String> api = const []]) =>
        GroupDecl(id: id, kind: GroupKind.algorithm, counter: 1, members: m, api: api);
    test('flags one name in two groups', () {
      final r = GroupRegistry(1, [g('a', ['f']), g('b', [], ['f'])]);
      expect(_duplicateOwners(r).keys, ['f']);
    });
    test('flags a name in one group\'s members and api', () {
      final r = GroupRegistry(1, [g('a', ['f'], ['f'])]);
      expect(_duplicateOwners(r).keys, ['f']);
    });
    test('accepts distinct names', () {
      final r = GroupRegistry(1, [g('a', ['f']), g('b', ['h'], ['i'])]);
      expect(_duplicateOwners(r), isEmpty);
    });
  });

  test('(b) every member is a real public top-level name', () {
    final api = _publicApi(libs: _publicLibs);
    final bad = [
      for (final g in reg.groups)
        for (final m in [...g.members, ...g.api])
          if (_memberFile(api, m) == null) '${g.id}: $m',
    ];
    expect(reg.groups, isNotEmpty, reason: 'registry is empty');
    expect(bad, isEmpty, reason: 'not exported: ${bad.join(', ')}');
  });

  test('(c) a group\'s import closure stays inside its files + foundations', () {
    final api = _publicApi(libs: _publicLibs);
    final byId = {for (final g in reg.groups) g.id: g};
    final leaks = <String>[];
    for (final g in reg.groups) {
      final allowed = <String>{...g.files};
      for (final d in _transitiveDeps(reg, g)) {
        final dg = byId[d];
        if (dg != null && dg.kind == GroupKind.foundation) {
          allowed.addAll(dg.files);
        }
      }
      final start = [
        for (final m in [...g.members, ...g.api])
          if (_memberFile(api, m) != null) _memberFile(api, m)!,
      ];
      final missing = _closure(start).difference(allowed)
        ..remove(_registryFile);
      for (final f in missing.toList()..sort()) {
        leaks.add('${g.id} reaches unlisted $f');
      }
    }
    expect(reg.groups, isNotEmpty, reason: 'registry is empty');
    expect(leaks, isEmpty, reason: leaks.join('\n'));
  });

  test('(d) every file reachable from an exported function is in some group', () {
    final api = _publicApi(fnsOnly: true);
    final owned = {for (final g in reg.groups) ...g.files};
    final reach = _closure(api.values.toSet())..remove(_registryFile);
    final orphans = reach.difference(owned).toList()..sort();
    expect(reg.groups, isNotEmpty, reason: 'registry is empty');
    expect(orphans, isEmpty,
        reason: '${orphans.length} unowned: ${orphans.take(20).join(', ')}');
  });
}
