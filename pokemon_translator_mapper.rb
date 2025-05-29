#!/usr/bin/env ruby
require_relative 'env'
require 'json'

def read_translations(file_path)
  JSON.parse(File.read(file_path))
end

def clean_species_id_for_key(species_id)
  species_id.gsub(
    /_(shadow|alolan|galarian|hisuian|paldean|mega|zen|origin|hero|crowned_sword|crowned_shield|single_strike|rapid_strike|apex|ultimate|primal|rainy|snowy|sunny|core|meteor|full_belly|hangry|zero|male|female|dusk|midday|midnight|curly|droopy|stretchy|gigantamax|eternamax|amped|low_key|hero|three|two)/, ''
  )
end

def extract_pokemon_data(gamemaster)
  pokemon_data = {}

  pokes = gamemaster['pokemon'] || {}
  puts "Found #{pokes.size} Pokemon entries in gamemaster"
  pokes.each do |key, value|
    next unless key['dex'] && key['speciesId']

    dex = key['dex'].to_s
    species_id = clean_species_id_for_key(key['speciesId'].to_s)

    pokemon_data[species_id] = dex
  end

  pokemon_data
end

def generate_localized_files(pokemon_data, translations, output_dir)
  Dir.mkdir(output_dir) unless Dir.exist?(output_dir)

  sample_pokemon = translations.values.first
  return unless sample_pokemon

  available_langs = sample_pokemon.keys

  available_langs.each do |lang|
    localized_pokemon = {}

    pokemon_data.each do |species_id, dex|
      if translations[dex] && translations[dex][lang]
        localized_pokemon[dex] = translations[dex][lang]
      end
    end

    output_file = File.join(output_dir, "pokemon_#{lang}.json")
    File.write(output_file, JSON.pretty_generate(localized_pokemon))

    puts "Generated #{output_file} with #{localized_pokemon.size} Pokemon"
  end
end

begin
  gamemaster_file = "#{Env::DATA_PATH}gamemaster.json"
  translations_file = 'pokemon_translations.json'
  output_directory = 'localized_data/pokemon'

  unless File.exist?(gamemaster_file)
    puts "Error: #{gamemaster_file} not found"
    exit 1
  end

  unless File.exist?(translations_file)
    puts "Error: #{translations_file} not found"
    exit 1
  end

  puts "Parsing gamemaster.js..."
  gamemaster =  JSON.parse(File.read(gamemaster_file))

  puts "Reading translations..."
  translations =  JSON.parse(File.read(translations_file))

  puts "Extracting Pokemon data..."
  pokemon_data = extract_pokemon_data(gamemaster)

  puts "Found #{pokemon_data.size} Pokemon in gamemaster"

  puts "Generating localized files..."
  generate_localized_files(pokemon_data, translations, output_directory)

  puts "Done!"

rescue => e
  puts "Error: #{e.message}"
  exit 1
end
