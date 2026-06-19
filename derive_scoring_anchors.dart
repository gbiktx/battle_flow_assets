#!/usr/bin/env dart
// ignore_for_file: avoid_print

/// Production emitter for per-cup scoring anchors (safety floor + display
/// bands), written straight into the served `settings.json` so a new cup can
/// ship calibrated anchors WITHOUT an app release. The app reads them back via
/// `Settings.scoringAnchors` → `RatingThresholds.anchorOverrides`, falling back
/// to its compiled-in baselines for any cup not present here.
///
/// Methodology (ported from
/// `battle_flow/scripts/research/formula/derive_safety_band_anchors.dart`):
/// computes the format's safety distribution over fixed-seed random TRIPLES of
/// threat-pool members, rated through the real `TeamRatingService` (so the
/// values are exactly production `safetyRating`). The pool is the canonical
/// reference population — fully determined by the synced ranking data. The
/// anchors are this format's distribution read at the same percentiles the
/// GL-calibrated constants occupy in GL's own distribution:
///
///   safetyFloor / severe → P9.5    (33.0 in GL)
///   low                  → P25.5   (38.0 in GL)
///   coverageTrap         → P47.5   (43.0 in GL)
///   high                 → P90     (52.0 in GL)
///
/// `weakLead` is a DIFFERENT metric (the prominent-meta lead score, not the
/// safety distribution) and is not auto-derived here. Pass `--weak-lead=<v>`
/// to set it explicitly; omitted, the app keeps its compiled-in default.
///
/// Env: operates on `v1/` by default, `preview/` with `--preview` (rankings,
/// gamemaster, meta_groups and settings.json all resolve under the chosen root).
///
/// Usage:
///   fvm dart run derive_scoring_anchors.dart <cupId> <cpLimit> [options]
///     --preview            operate on preview/ instead of v1/
///     --triples=1000       distinct pool triples to sample
///     --seed=42            RNG seed (keep fixed for reproducibility)
///     --weak-lead=<v>      set the weakLead anchor (else left to the default)
///     --version=<v>        scoringAnchors.version stamp (default: today)
///     --dry-run            compute + print, do not write settings.json
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:battleflow/core/threat_pool_utils.dart';
import 'package:battleflow/db/models/cup_info.dart';
import 'package:battleflow/db/models/rank_pokemon.dart';
import 'package:battleflow/db/models/team.dart';
import 'package:battleflow/db/models/team_member.dart';
import 'package:battleflow/services/i_battle_pokemon_builder.dart';
import 'package:battleflow/services/team_rating_service.dart';

import '../battle_flow/scripts/script_team_generator.dart' as generator_script;

Future<void> main(List<String> args) async {
  final config = _Config.fromArgs(args);
  if (config == null) {
    stderr.writeln(
      'Usage: dart derive_scoring_anchors.dart <cupId> <cpLimit> '
      '[--preview] [--triples=1000] [--seed=42] [--weak-lead=<v>] '
      '[--version=<v>] [--dry-run]',
    );
    exit(1);
  }

  final root = config.preview ? 'preview' : 'v1';
  print('Env       : $root/');
  print('Cup       : ${config.cupId} / ${config.cpLimit}');

  final gamemasterPath = '$root/gamemaster.json';
  await generator_script.setupScriptServices(
    gamemasterPath,
    verboseDiagnostics: false,
  );
  final ratingService = generator_script.scriptLocator<TeamRatingService>();
  final builder = generator_script.scriptLocator<IBattlePokemonBuilder>();
  final rankings = await _loadRankings(root, config.cupId, config.cpLimit);

  final safeties = await _safetyDistribution(
    config: config,
    rankings: rankings,
    ratingService: ratingService,
    builder: builder,
  );

  // Percentile of THIS distribution (value at share p below). Mirrors the
  // research script so anchors are byte-identical to a manual derivation.
  double pct(double p) =>
      safeties[math.min(safeties.length - 1, (safeties.length * p).floor())];
  double percentileOf(double value) =>
      safeties.where((s) => s < value).length / safeties.length;

  final rawSevere = pct(0.095); // P9.5 — also the floor
  final rawLow = pct(0.255); // P25.5
  final rawTrap = pct(0.475); // P47.5
  final rawHigh = pct(0.90); // P90

  // Floor rounds DOWN (conservative: a lower floor demotes fewer teams). The
  // `severe` band is the SAME P9.5 anchor as the floor — every shipped cup
  // keeps them equal — so tie them rather than rounding independently. The
  // remaining bands round to the nearest 0.5, matching the hand-derived values.
  final floor = _floorHalf(rawSevere);
  final bands = <String, double>{
    'severe': floor,
    'low': _roundHalf(rawLow),
    'coverageTrap': _roundHalf(rawTrap),
    'high': _roundHalf(rawHigh),
  };

  print('');
  print('Distribution (n=${safeties.length}):');
  print('  P9.5=${rawSevere.toStringAsFixed(1)}  '
      'P25.5=${rawLow.toStringAsFixed(1)}  '
      'P47.5=${rawTrap.toStringAsFixed(1)}  '
      'P90=${rawHigh.toStringAsFixed(1)}');
  // Pre-registered sanity check: if GL's 33 lands in a degenerate tail of this
  // distribution, pool-triples may be an unusable reference (see research doc).
  final p33 = percentileOf(33.0) * 100;
  print('  GL-33 sits at P${p33.toStringAsFixed(1)} of this distribution'
      '${p33 < 5 ? '  ⚠️  <P5 — verify pool-triples are a valid reference' : ''}');
  print('');
  print('Anchors (rounded):');
  print('  safetyFloor  = $floor');
  print('  bands        = severe ${bands['severe']}, low ${bands['low']}, '
      'coverageTrap ${bands['coverageTrap']}, high ${bands['high']}');
  if (config.weakLead != null) print('  weakLead     = ${config.weakLead}');

  final cupEntry = <String, dynamic>{
    'safetyFloor': floor,
    if (config.weakLead != null) 'weakLead': config.weakLead,
    'bands': bands,
  };

  if (config.dryRun) {
    print('');
    print('[dry-run] would write $root/settings.json '
        'scoringAnchors.cups["${config.cupId}:${config.cpLimit}"]:');
    print(const JsonEncoder.withIndent('  ').convert(cupEntry));
    return;
  }

  await _patchSettings(root: root, config: config, cupEntry: cupEntry);
}

/// Builds the production safety distribution over fixed-seed pool triples.
Future<List<double>> _safetyDistribution({
  required _Config config,
  required Map<String, RankPokemon> rankings,
  required TeamRatingService ratingService,
  required IBattlePokemonBuilder builder,
}) async {
  final poolSize = recommendedDynamicThreatPoolSize(
    config.cupId,
    config.cpLimit,
  );
  final pool = selectDynamicThreatPool(rankings.values, maxCount: poolSize);
  print('Pool      : ${pool.length} members (target $poolSize)');

  final context = await ratingService.prepareContext(
    rankings,
    config.cupId,
    config.cpLimit,
    bait: true,
  );
  final cupInfo = CupInfo(
    name: config.cupId,
    title: config.cupId.toUpperCase(),
    cpLimit: config.cpLimit,
    badge: '',
    active: true,
  );

  // Fixed-seed distinct triples of pool members (same sampler as research).
  final rng = math.Random(config.seed);
  final seen = <String>{};
  final triples = <List<RankPokemon>>[];
  final maxTriples = pool.length * (pool.length - 1) * (pool.length - 2) ~/ 6;
  final target = math.min(config.triples, maxTriples);
  while (triples.length < target) {
    final idx = <int>{};
    while (idx.length < 3) {
      idx.add(rng.nextInt(pool.length));
    }
    final sorted = idx.toList()..sort();
    if (seen.add(sorted.join(','))) {
      triples.add(sorted.map((i) => pool[i]).toList());
    }
  }
  print('Triples   : ${triples.length} distinct (seed ${config.seed})');

  final teams = <Team>[
    for (final triple in triples)
      Team.fromMembers(
        members: [
          for (var j = 0; j < 3; j++)
            TeamMember.from(
              builder.buildFromRanking(
                triple[j].speciesId,
                triple[j],
                cupInfo.cpLimit,
                true,
              ),
              j,
            ),
        ],
        cupId: cupInfo.name,
        cupCpLimit: cupInfo.cpLimit,
      ),
  ];

  final safeties = <double>[];
  const batch = 100;
  for (var i = 0; i < teams.length; i += batch) {
    final slice = teams.sublist(i, math.min(i + batch, teams.length));
    final rated = await ratingService.rateTeamsWithContext(
      slice,
      rankings,
      context,
      bait: true,
    );
    for (final r in rated) {
      final a = r.ratingResults.strategicAnalysis;
      if (a != null) safeties.add(a.safetyRating);
    }
    stderr.writeln('  rated ${math.min(i + batch, teams.length)}/${teams.length}');
  }
  if (safeties.isEmpty) {
    throw StateError('No safety values produced — check rankings/gamemaster.');
  }
  safeties.sort();
  return safeties;
}

/// Reads, patches, and rewrites `<root>/settings.json` in place, preserving the
/// pipeline's pretty-print convention (2-space indent + trailing newline).
Future<void> _patchSettings({
  required String root,
  required _Config config,
  required Map<String, dynamic> cupEntry,
}) async {
  final file = File('$root/settings.json');
  if (!await file.exists()) {
    throw StateError('$root/settings.json not found');
  }
  final settings = jsonDecode(await file.readAsString()) as Map<String, dynamic>;

  final anchors = (settings['scoringAnchors'] as Map<String, dynamic>?) ?? {};
  // Explicit --version wins; otherwise keep the existing block's version (don't
  // re-stamp other cups' anchors when patching a second cup in); fall back to
  // today only when stamping the first cup of a fresh block.
  final version =
      config.version ?? (anchors['version'] as String?) ?? _today();
  anchors['version'] = version;
  final cups = (anchors['cups'] as Map<String, dynamic>?) ?? {};
  final key = '${config.cupId}:${config.cpLimit}';
  cups[key] = cupEntry;
  anchors['cups'] = cups;
  settings['scoringAnchors'] = anchors;

  const encoder = JsonEncoder.withIndent('  ');
  await file.writeAsString('${encoder.convert(settings)}\n');
  print('');
  print('Wrote $root/settings.json → scoringAnchors.version=$version, '
      'cups["$key"]');
}

Future<Map<String, RankPokemon>> _loadRankings(
  String root,
  String cupId,
  String cpLimit,
) async {
  // Limited cups → "<cupId>-<cpLimit>.json"; open formats (cupId == 'all') →
  // "<cpLimit>.json". See MEMORY "Ranking File Naming Convention".
  final candidates = [
    File('$root/rankings/$cupId-$cpLimit.json'),
    File('$root/rankings/$cpLimit.json'),
  ];
  File? rankingsFile;
  for (final candidate in candidates) {
    if (await candidate.exists()) {
      rankingsFile = candidate;
      break;
    }
  }
  if (rankingsFile == null) {
    throw StateError('Ranking file not found for $cupId/$cpLimit under $root/');
  }
  final json =
      jsonDecode(await rankingsFile.readAsString()) as Map<String, dynamic>;
  final entries =
      ((json['entries'] as List?) ?? const []).cast<Map<String, dynamic>>();
  return {
    for (final entry in entries)
      RankPokemon.fromJson(entry).speciesId: RankPokemon.fromJson(entry),
  };
}

double _roundHalf(double v) => (v * 2).round() / 2;
double _floorHalf(double v) => (v * 2).floorToDouble() / 2;

String _today() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

class _Config {
  final String cupId;
  final String cpLimit;
  final bool preview;
  final int triples;
  final int seed;
  final double? weakLead;

  /// Explicit `--version` stamp, or null to preserve the existing
  /// scoringAnchors.version (see [_patchSettings]).
  final String? version;
  final bool dryRun;

  _Config({
    required this.cupId,
    required this.cpLimit,
    required this.preview,
    required this.triples,
    required this.seed,
    required this.weakLead,
    required this.version,
    required this.dryRun,
  });

  static _Config? fromArgs(List<String> args) {
    final positional = args.where((a) => !a.startsWith('--')).toList();
    if (positional.length < 2) return null;

    String? opt(String name) {
      final prefix = '--$name=';
      for (final a in args) {
        if (a.startsWith(prefix)) return a.substring(prefix.length);
      }
      return null;
    }

    final triples = int.tryParse(opt('triples') ?? '') ?? 1000;
    if (triples <= 0) {
      stderr.writeln('--triples must be a positive integer (got "${opt('triples')}")');
      return null;
    }

    return _Config(
      cupId: positional[0],
      cpLimit: positional[1],
      preview: args.contains('--preview'),
      triples: triples,
      seed: int.tryParse(opt('seed') ?? '') ?? 42,
      weakLead: double.tryParse(opt('weak-lead') ?? ''),
      version: opt('version'),
      dryRun: args.contains('--dry-run'),
    );
  }
}
