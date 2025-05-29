require 'json'
require 'fileutils' # For creating directories
require 'active_support/core_ext/string/inflections' # For camelize method
require 'set' # For managing unique keys
require_relative 'env'

def to_camel_case(snake_str)
  components = snake_str.split('_')
  # Capitalize the first letter of each component except the first one
  # and join them together.
  components[0] + components[1..-1].map(&:capitalize).join('')
end

def clean_species_id_for_key(species_id)
  # Remove _shadow, _alolan, _galarian, _hisuian, _paldean and other form suffixes
  # This list should cover all forms you want to consolidate for the base key.
  species_id.gsub(
    /_(shadow|alolan|galarian|hisuian|paldean|mega|zen|origin|hero|crowned_sword|crowned_shield|single_strike|rapid_strike|apex|ultimate|primal|rainy|snowy|sunny|core|meteor|full_belly|hangry|zero|male|female|dusk|midday|midnight|curly|droopy|stretchy|gigantamax|eternamax|amped|low_key|hero|three|two)/, ''
  )
end

def clean_species_name_from_parentheses(species_name)
  # Remove everything inside parentheses including parentheses
  species_name.gsub(/\s*\(.*?\)/, '').strip
end

# Define supported locales and their corresponding filename prefixes
LOCALES = {
  'en' => {
    "pokemon_file": 'pokemon_en.json',
    "move_file": 'moves_en.json'
  },
  'es' => {
    "pokemon_file": 'pokemon_es.json',
    "move_file": 'moves_es.json'
  },
  'zh' => {
    "pokemon_file": 'pokemon_zh.json',
    "move_file": 'moves_zh.json'
  },
  'ja' => {
    "pokemon_file": 'pokemon_ja.json',
    "move_file": 'moves_ja.json'
  },
  'fr' => {
    "pokemon_file": 'pokemon_fr.json',
    "move_file": 'moves_fr.json'
  },
  'de' => {
    "pokemon_file": 'pokemon_de.json',
    "move_file": 'moves_de.json'
  },
  'pt' => {
    "pokemon_file": 'pokemon_pt.json',
    "move_file": 'moves_pt.json'
  },
  'it' => {
    "pokemon_file": 'pokemon_it.json',
    "move_file": 'moves_it.json'
  }
}

# Load the gamemaster data
begin
  gamemaster_data = JSON.parse(File.read("#{Env::DATA_PATH}gamemaster.json"))
  puts 'Loaded gamemaster.json'
rescue Errno::ENOENT
  puts 'Error: gamemaster.json not found. Please place it in the same directory.'
  exit
rescue JSON::ParserError
  puts 'Error: gamemaster.json is not valid JSON.'
  exit
end

# --- Generate ARB data for each locale ---
all_pokemon_keys_generated = Set.new # Track all unique Pokémon keys for Dart extension
all_move_keys_generated = Set.new # Track all unique Move keys for Dart extension

LOCALES.each do |locale_code, files|
  puts "\n--- Generating ARB for #{locale_code} ---"

  # Load locale-specific translation files
  begin
    pokemon_translations = JSON.parse(File.read("#{Env::LOCALE_PATH}/pokemon/#{files[:pokemon_file]}"))
    puts "Loaded #{files[:pokemon_file]}"
  rescue Errno::ENOENT
    puts "Warning: #{files[:pokemon_file]} not found. Using English fallbacks for Pokémon names."
    pokemon_translations = {} # Use empty hash if file not found
  rescue JSON::ParserError
    puts "Error: #{files[:pokemon_file]} is not valid JSON. Skipping this locale for Pokémon."
    next
  end

  begin
    move_translations = JSON.parse(File.read("#{Env::LOCALE_PATH}/moves/#{files[:move_file]}"))
    puts "Loaded #{files[:move_file]}"
  rescue Errno::ENOENT
    puts "Warning: #{files[:move_file]} not found. Using English fallbacks for Move names."
    move_translations = {} # Use empty hash if file not found
  rescue JSON::ParserError
    puts "Error: #{files[:move_file]} is not valid JSON. Skipping this locale for Moves."
    next
  end

  current_arb_data = {
    "@@locale": locale_code
  }

  # Process Pokémon data
  gamemaster_data['pokemon'].each do |pokemon|
    original_species_id = pokemon['speciesId']
    dex_number = pokemon['dex']

    # Get the base species ID for lookup in translation JSON
    base_species_id_for_lookup = clean_species_id_for_key(original_species_id)

    # Construct the Dart/ARB key (e.g., 'pokemonBulbasaur')
    arb_key_camel = 'pokemon' + base_species_id_for_lookup.camelize(:upper)

    # Add to master set of all keys for Dart extension generation later
    all_pokemon_keys_generated.add(arb_key_camel)

    # Get translated name, fallback to original English name if not found in custom file
    # Then apply final cleaning from parentheses
    translated_name = pokemon_translations.fetch(dex_number.to_s,
                                                 clean_species_name_from_parentheses(pokemon['speciesName']))

    # Add to current locale's ARB data (only once per unique camelCase key)
    current_arb_data[arb_key_camel] = translated_name unless current_arb_data.key?(arb_key_camel)
  end

  # Process Moves data
  gamemaster_data['moves'].each do |move|
    move_id = move['moveId']
    original_move_name = move['name']

    # Convert moveId to camelCase and prefix with 'move'
    arb_key_camel = 'move' + move_id.downcase.camelize(:upper)

    # Add to master set of all keys for Dart extension generation later
    all_move_keys_generated.add(arb_key_camel)

    # Get translated name, fallback to original English name if not found in custom file
    translated_name = move_translations.fetch(move_id, original_move_name)

    # Add to current locale's ARB data (only once per unique camelCase key)
    current_arb_data[arb_key_camel] = translated_name unless current_arb_data.key?(arb_key_camel)
  end

  # Create lib/l10n directory if it doesn't exist
  FileUtils.mkdir_p('lib/l10n') unless File.directory?('lib/l10n')

  # Write the ARB file for the current locale
  arb_filename = "lib/l10n/pokemon_and_move_#{locale_code}.arb"
  File.open(arb_filename, 'w:UTF-8') do |f|
    f.write(JSON.pretty_generate(current_arb_data))
  end
  puts "Generated #{arb_filename}"
end

pokemon_switch_cases_dart = []
saved_pokemon = Set.new
gamemaster_data['pokemon'].each do |pokemon|
  original_species_id = pokemon['speciesId']
  dex_number = pokemon['dex']
  base_species_id_for_lookup = clean_species_id_for_key(original_species_id)
  arb_key_camel = 'pokemon' + base_species_id_for_lookup.camelize(:upper)

  unless saved_pokemon.include?(dex_number)
    saved_pokemon.add(dex_number)
    pokemon_switch_cases_dart << "      case '#{dex_number}': return #{arb_key_camel};"
  end
end

move_switch_cases_dart = []
gamemaster_data['moves'].each do |move|
  move_id = move['moveId']
  arb_key_camel = 'move' + move_id.downcase.camelize(:upper)

  if all_move_keys_generated.include?(arb_key_camel)
    move_switch_cases_dart << "      case '#{move_id}': return #{arb_key_camel};"
  end
end

pokemon_fallback_dart = 'return dexNumber;'
move_fallback_dart = 'return moveId;'

dart_extension_code = <<~DART
  // lib/localization/app_localizations_extension.dart

  import 'package:flutter_gen/gen_l10n/app_localizations.dart';

  extension DataLocalization on AppLocalizations {
    String translatePokemonName(String dexNumber) {
      switch (dexNumber) {
  #{pokemon_switch_cases_dart.join("\n")}
        default:
  #{pokemon_fallback_dart.gsub(/^ {8}/, '        ')} // Adjust indentation
      }
    }

    String translateMoveName(String moveId) {
      switch (moveId) {
  #{move_switch_cases_dart.join("\n")}
        default:
  #{move_fallback_dart.gsub(/^ {8}/, '        ')} // Adjust indentation
      }
    }
  }
DART

# Create lib/localization directory if it doesn't exist
FileUtils.mkdir_p('lib/localization') unless File.directory?('lib/localization')

# Write the Dart extension file
File.open('lib/localization/app_localizations_extension.dart', 'w:UTF-8') do |f|
  f.write(dart_extension_code)
end

puts "\nGenerated lib/localization/app_localizations_extension.dart"
