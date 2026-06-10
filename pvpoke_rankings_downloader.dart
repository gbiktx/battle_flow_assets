#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';
import 'package:battleflow/db/models/stats_calculator.dart';
import 'package:http/http.dart' as http;
import 'package:battleflow/battle_flow.dart';
import 'package:battleflow/server/models/default_ivs.dart';
import 'package:battleflow/server/models/stats.dart';

/// Script to download and process PvPoke rankings for Battle Flow
/// Downloads rankings from PvPoke.com and formats them to match Battle Flow's data structure
class PvPokeRankingsDownloader {
  static const String pvPokeBaseUrl = 'https://pvpoke.com/data/rankings';
  static const String apiVersion = 'v1';
  static const String settingsFilePath = '$apiVersion/settings.json';
  static const String gamemasterFilePath = '$apiVersion/gamemaster.json';
  static const String rankingsOutputPath = '$apiVersion/rankings';

  Map<String, Pokemon> _pokemonData = {};

  /// Downloads and processes one cup/CP pair, independent of settings.json.
  Future<void> downloadSingleCup(String cupId, int cpLimit) async {
    print('Downloading single cup: $cupId @ $cpLimit...');
    await _loadGamemaster();
    if (_pokemonData.isEmpty) {
      print('Error: Could not load Pokemon data from gamemaster.json');
      return;
    }
    await _ensureRankingsDirectory();
    await _downloadAndProcessCupRankings(cupId, cpLimit, '$cupId-$cpLimit');
    print('Done: $cupId-$cpLimit');
  }

  Future<void> downloadAllRankings() async {
    print('Starting PvPoke rankings download...');

    // Load Pokemon data from gamemaster.json
    await _loadGamemaster();
    if (_pokemonData.isEmpty) {
      print('Error: Could not load Pokemon data from gamemaster.json');
      return;
    }

    // Read settings.json to get cup configurations
    final settings = await _readSettings();
    if (settings == null) {
      print('Error: Could not read settings.json');
      return;
    }

    // Create rankings directory if it doesn't exist
    await _ensureRankingsDirectory();

    // Process each league
    await _processLeague(settings['greatCups'], 'Great League');
    await _processLeague(settings['ultraCups'], 'Ultra League');
    await _processLeague(settings['masterCups'], 'Master League');
    await _processLeague(settings['littleCups'], 'Little League');

    print('All rankings downloaded successfully!');
  }

  Future<Map<String, dynamic>?> _readSettings() async {
    try {
      final file = File(settingsFilePath);
      if (!await file.exists()) {
        print('Error: settings.json not found at $settingsFilePath');
        return null;
      }

      final content = await file.readAsString();
      return json.decode(content) as Map<String, dynamic>;
    } catch (e) {
      print('Error reading settings.json: $e');
      return null;
    }
  }

  Future<void> _loadGamemaster() async {
    try {
      final file = File(gamemasterFilePath);
      if (!await file.exists()) {
        print('Error: gamemaster.json not found at $gamemasterFilePath');
        return;
      }

      final content = await file.readAsString();
      final gamemasterData = json.decode(content) as Map<String, dynamic>;

      final pokemonList = gamemasterData['pokemon'] as List<dynamic>?;
      if (pokemonList == null) {
        print('Error: No pokemon data found in gamemaster.json');
        return;
      }

      _pokemonData.clear();
      for (final pokemonJson in pokemonList) {
        final pokemonData = pokemonJson as Map<String, dynamic>;

        // Create Pokemon object from gamemaster data
        final types = List<String>.from(pokemonData['types'] ?? []);
        final pokemon = Pokemon(
          dex: pokemonData['dex'] ?? 0,
          speciesId: pokemonData['speciesId'],
          speciesName: pokemonData['speciesName'] ?? pokemonData['speciesId'],
          baseStats: Stats(
            attack: pokemonData['baseStats']['atk'].toDouble(),
            defense: pokemonData['baseStats']['def'].toDouble(),
            stamina: pokemonData['baseStats']['hp'].toInt(),
          ),
          defaultIVs: DefaultIvs(), // Empty for now
          primaryType: types.isNotEmpty ? types[0] : 'none',
          secondaryType: types.length > 1
              ? types[1]
              : types.isNotEmpty
                  ? types[0]
                  : 'none',
          spriteName: pokemonData['speciesId'], // Use speciesId as sprite name
          isShadow:
              (pokemonData['tags'] as List<dynamic>? ?? []).contains('shadow'),
          fastMovesIds: List<String>.from(pokemonData['fastMoves'] ?? []),
          chargedMovesIds: List<String>.from(pokemonData['chargedMoves'] ?? []),
          tags: List<String>.from(pokemonData['tags'] ?? []),
        );

        _pokemonData[pokemon.speciesId] = pokemon;
      }

      print('Loaded ${_pokemonData.length} Pokemon from gamemaster.json');
    } catch (e) {
      print('Error loading gamemaster.json: $e');
    }
  }

  Future<void> _ensureRankingsDirectory() async {
    final dir = Directory(rankingsOutputPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      print('Created rankings directory: $rankingsOutputPath');
    }
  }

  Future<void> _processLeague(List<dynamic>? cups, String leagueName) async {
    if (cups == null) {
      print('No cups found for $leagueName');
      return;
    }

    print('\nProcessing $leagueName...');

    for (final cupData in cups) {
      final cup = cupData as Map<String, dynamic>;
      final isActive = cup['active'] as bool? ?? false;

      if (!isActive) {
        continue;
      }

      final cupTitle = cup['title'] as String;
      final cpLimitRaw = cup['cpLimit'] ?? cup['cp'];
      if (cpLimitRaw == null) {
        print('  Skipping cup ${cup['title']} - no CP limit defined');
        continue;
      }

      // Handle both string and int CP limits
      final cpLimit =
          cpLimitRaw is String ? int.parse(cpLimitRaw) : cpLimitRaw as int;
      final cupId = cup['name'] as String;

      print('  Processing cup: $cupTitle (CP: $cpLimit)');

      try {
        await _downloadAndProcessCupRankings(cupId, cpLimit, cupTitle);
        print('  ✓ Successfully processed $cupTitle');
      } catch (e) {
        print('  ✗ Failed to process $cupTitle: $e');
        // Continue processing other cups even if one fails
        continue;
      }
    }
  }

  Future<void> _downloadAndProcessCupRankings(
      String cupId, int cpLimit, String cupTitle) async {
    // Use the correct PvPoke API format
    final url = '$pvPokeBaseUrl/$cupId/overall/rankings-$cpLimit.json';

    List<Map<String, dynamic>> rankings = [];

    try {
      print('    Downloading rankings from: $url');

      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final List<dynamic> pvpokeRankings = json.decode(response.body);

        rankings = await _processRankings(pvpokeRankings, cpLimit);

        print('      ${rankings.length} rankings processed');

        if (rankings.isEmpty) {
          throw Exception('No rankings found for $cupTitle (CP: $cpLimit)');
        }
      } else {
        throw Exception(
            'Failed to download rankings for $cupTitle: HTTP ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error downloading rankings for $cupTitle: $e');
    }

    // Save processed rankings with correct filename
    await _saveRankings(cupId, cpLimit, rankings);
  }

  Future<List<Map<String, dynamic>>> _processRankings(
      List<dynamic> pvpokeRankings, int cpLimit) async {
    final processed = <Map<String, dynamic>>[];

    for (final entry in pvpokeRankings) {
      final entryMap = entry as Map<String, dynamic>;
      final speciesId = entryMap['speciesId'] as String;
      final score = (entryMap['score'] as num).toDouble();

      // Skip entries with very low scores
      // if (score < 50.0) continue;

      Pokemon? pokemon = _pokemonData[speciesId];
      if (pokemon == null) {
        print('      Warning: Pokemon not found in gamemaster: $speciesId');
        continue;
      }

      // Calculate best IV combination using StatsCalculator from battleflow
      final calculator = StatsCalculator(pokemon, cpLimit, 51);
      final bestEntry =
          calculator.generateIvRanking(count: 1).values.firstOrNull;

      if (bestEntry == null) {
        print(
            '      Warning: Could not calculate IVs for $speciesId at CP $cpLimit');
        continue;
      }

      // Extract rating from PvPoke data (often called 'rating' in their format)
      final rating = (entryMap['rating'] as num).toInt();

      // Determine if this is a shadow Pokemon
      final isShadow = pokemon.isShadow || speciesId.contains('_shadow');

      // Process moveset data
      final moveset = entryMap['moveset'] != null
          ? List<String>.from(entryMap['moveset'])
          : [];

      // Extract or generate recommended moveset string
      String recommendedMoveset = "";
      if (moveset.isNotEmpty && moveset.length >= 3) {
        // Format: "Fast Move, Charged Move 1, Charged Move 2"
        recommendedMoveset =
            "${_formatMoveName(moveset[0])}, ${_formatMoveName(moveset[1])}, ${_formatMoveName(moveset[2])}";
      }

      // Use actual PvPoke data when available, otherwise generate mock data
      final matchups = entryMap['matchups'] != null
          ? List<Map<String, dynamic>>.from(entryMap['matchups'])
          : _generateMockMatchups(speciesId, 5);

      final counters = entryMap['counters'] != null
          ? List<Map<String, dynamic>>.from(entryMap['counters'])
          : _generateMockCounters(speciesId, 5);

      // Extract scores array or generate mock data
      final scores = entryMap['scores'] != null
          ? (entryMap['scores'] as List)
              .map((e) => (e as num).toDouble())
              .toList()
          : _generateDetailedScores(score);

      // Extract move usage statistics or generate mock data
      final moves = entryMap['moves'] as Map<String, dynamic>?;
      final rankingFastMoves = moves?['rankingFastMoves'] != null
          ? List<Map<String, dynamic>>.from(moves!['rankingFastMoves'])
          : _generateMockFastMoves(pokemon.fastMovesIds);

      final rankingChargedMoves = moves?['rankingChargedMoves'] != null
          ? List<Map<String, dynamic>>.from(moves!['rankingChargedMoves'])
          : _generateMockChargedMoves(pokemon.chargedMovesIds);

      // Create processed entry matching 1500.json structure
      final processedEntry = {
        'rank': 0, // Will be set later when sorting
        'speciesId': speciesId,
        'rating': rating,
        'isShadow': isShadow,
        'bestIvs': {
          'level': bestEntry.level,
          'stats': {
            'atk': bestEntry.stats.attack, // double
            'def': bestEntry.stats.defense, // double
            'hp': bestEntry.stats.stamina, // int
          },
          'ivs': {
            'atk': bestEntry.ivs.atk,
            'def': bestEntry.ivs.def,
            'hp': bestEntry.ivs.hp,
          },
          'overall': bestEntry.overall,
          'cp': bestEntry.cp,
          'rank': bestEntry.rank,
          'perfectionPercent': bestEntry.perfectionPercent.toInt(),
        },
        'matchups': matchups,
        'counters': counters,
        'rankingFastMoves': rankingFastMoves,
        'rankingChargedMoves': rankingChargedMoves,
        'moveset': moveset,
        'recommendedMoveset': recommendedMoveset,
        'score': score,
        'scores': scores,
      };

      processed.add(processedEntry);
    }

    processed.sort((a, b) {
      final ratingA = a['score'] as double;
      final ratingB = b['score'] as double;
      return ratingB.compareTo(ratingA);
    });

    // Add rank numbers
    for (int i = 0; i < processed.length; i++) {
      processed[i]['rank'] = i + 1;
    }

    return processed;
  }

  Future<void> _saveRankings(
      String cupId, int cpLimit, List<Map<String, dynamic>> rankings) async {
    // Generate correct filename based on cup type
    final fileName = cupId == 'all' ? '$cpLimit.json' : '$cupId-$cpLimit.json';
    final outputFile = File('$rankingsOutputPath/$fileName');

    final output = {
      'cupId': cupId,
      'cpLimit': cpLimit.toString(),
      'entries': rankings,
    };

    await outputFile.writeAsString(json.encode(output));
    print('    Saved rankings to: ${outputFile.path}');
  }

  /// Format move name from API format to readable format
  String _formatMoveName(String moveId) {
    return moveId
        .toLowerCase()
        .split('_')
        .map((word) => word[0].toUpperCase() + word.substring(1))
        .join(' ');
  }

  /// Generate mock matchup data (favorable opponents)
  List<Map<String, dynamic>> _generateMockMatchups(
      String speciesId, int count) {
    // In a real implementation, this would come from PvPoke's battle simulation data
    // For now, we'll generate mock data based on common type effectiveness
    final commonOpponents = [
      'azumarill',
      'registeel',
      'altaria',
      'medicham',
      'skarmory',
      'bastiodon',
      'swampert',
      'venusaur',
      'deoxys_defense',
      'tropius',
      'cresselia',
      'umbreon',
      'hypno',
      'whiscash',
      'meganium'
    ];

    final matchups = <Map<String, dynamic>>[];
    for (int i = 0; i < count && i < commonOpponents.length; i++) {
      matchups.add({
        'opponent': commonOpponents[i],
        'rating': 500 + (i * 50) + (speciesId.hashCode % 200), // Mock rating
      });
    }

    return matchups;
  }

  /// Generate mock counter data (unfavorable opponents)
  List<Map<String, dynamic>> _generateMockCounters(
      String speciesId, int count) {
    // In a real implementation, this would come from PvPoke's battle simulation data
    final commonCounters = [
      'machamp',
      'lucario',
      'toxapex',
      'galvantula',
      'raichu_alolan',
      'lapras',
      'charizard',
      'blaziken',
      'magnezone',
      'clefable'
    ];

    final counters = <Map<String, dynamic>>[];
    for (int i = 0; i < count && i < commonCounters.length; i++) {
      counters.add({
        'opponent': commonCounters[i],
        'rating': 200 + (i * 30) + (speciesId.hashCode % 150), // Mock rating
      });
    }

    return counters;
  }

  /// Generate mock fast move usage statistics
  List<Map<String, dynamic>> _generateMockFastMoves(List<String> fastMoves) {
    final moves = <Map<String, dynamic>>[];
    int totalUses = 100000;

    for (int i = 0; i < fastMoves.length; i++) {
      final uses = totalUses ~/ (i + 1); // Decreasing usage for each move
      moves.add({
        'moveId': fastMoves[i],
        'uses': uses,
      });
      totalUses -= uses;
    }

    return moves;
  }

  /// Generate mock charged move usage statistics
  List<Map<String, dynamic>> _generateMockChargedMoves(
      List<String> chargedMoves) {
    final moves = <Map<String, dynamic>>[];
    int baseUses = 50000;

    for (int i = 0; i < chargedMoves.length; i++) {
      final uses = baseUses ~/ (i + 1); // Decreasing usage for each move
      moves.add({
        'moveId': chargedMoves[i],
        'uses': uses,
      });
    }

    return moves;
  }

  /// Generate detailed scores array for different performance metrics
  List<double> _generateDetailedScores(double baseScore) {
    // These represent different aspects of performance (leads, switches, closers, etc.)
    // In a real implementation, these would come from PvPoke's detailed analysis
    return [
      baseScore, // Overall score
      baseScore - 2.0, // Lead performance
      baseScore - 5.0, // Switch performance
      baseScore - 8.0, // Closer performance
      baseScore + 3.0, // Consistency
      baseScore - 1.0, // Attacker rating
    ];
  }

  /// Helper method to validate that our Pokemon data is correctly loaded
  void validatePokemonData() {
    print('\nValidating Pokemon data...');

    final samplePokemon = ['venusaur', 'charizard', 'blastoise', 'pikachu'];

    for (final speciesId in samplePokemon) {
      final pokemon = _pokemonData[speciesId];
      if (pokemon != null) {
        print(
            '✓ $speciesId: ${pokemon.speciesName} (${pokemon.baseStats.attack}/${pokemon.baseStats.defense}/${pokemon.baseStats.stamina})');
      } else {
        print('✗ $speciesId: NOT FOUND');
      }
    }
  }
}

/// Entry point
void main(List<String> args) async {
  final downloader = PvPokeRankingsDownloader();

  if (args.contains('--validate')) {
    await downloader._loadGamemaster();
    downloader.validatePokemonData();
    return;
  }

  // One-off download for a single cup/CP without touching settings.json
  // (cup activation stays a separate product decision):
  //   dart pvpoke_rankings_downloader.dart --cup fantasy --cp 2500
  final cupIdx = args.indexOf('--cup');
  final cpIdx = args.indexOf('--cp');
  if (cupIdx != -1 && cpIdx != -1) {
    final cupId = args[cupIdx + 1];
    final cpLimit = int.parse(args[cpIdx + 1]);
    await downloader.downloadSingleCup(cupId, cpLimit);
    return;
  }

  await downloader.downloadAllRankings();
}
