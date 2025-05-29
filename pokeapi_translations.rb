require 'net/http'
require 'json'
require 'uri'

BASE_URL = 'https://pokeapi.co/api/v2/'
OUTPUT_FILENAME = 'pokemon_translations.json'

def fetch_all_pokemon_species_data
  all_pokemon_species = []
  url = URI.parse("#{BASE_URL}pokemon-species?limit=10000")

  loop do
    response = Net::HTTP.get_response(url)

    unless response.is_a?(Net::HTTPSuccess)
      raise "Failed to fetch data from #{url}: #{response.code} #{response.message}"
    end

    data = JSON.parse(response.body)

    data['results'].each do |pokemon_entry|
      all_pokemon_species << pokemon_entry['url']
    end

    break unless data['next']

    url = URI.parse(data['next'])
  end
  all_pokemon_species
end

def get_pokemon_translations
  pokemon_map = {}
  species_urls = fetch_all_pokemon_species_data

  puts "Fetching details for #{species_urls.length} Pokémon species..."

  species_urls.each_with_index do |species_url, index|
    print "\rProcessing Pokémon #{index + 1}/#{species_urls.length}..."
    species_response = Net::HTTP.get_response(URI.parse(species_url))

    unless species_response.is_a?(Net::HTTPSuccess)
      warn "\nWarning: Failed to fetch species data from #{species_url}: #{species_response.code} #{species_response.message}. Skipping."
      next
    end

    species_data = JSON.parse(species_response.body)

    dex_number = species_data['id']
    translated_names = {}

    species_data['names'].each do |name_entry|
      language = name_entry['language']['name']
      name = name_entry['name']
      translated_names[language] = name
    end
    pokemon_map[dex_number] = translated_names
  end
  puts "\nDone fetching data."
  pokemon_map
end

def write_to_file(data, filename)
  File.open(filename, 'w') do |file|
    file.write(JSON.pretty_generate(data))
  end
  puts "Successfully wrote data to #{filename}"
end

if __FILE__ == $PROGRAM_NAME
  begin
    all_pokemon_with_translations = get_pokemon_translations
    write_to_file(all_pokemon_with_translations, OUTPUT_FILENAME)

    puts "\n--- Example Output from Data (first 3 entries) ---"
    all_pokemon_with_translations.first(3).each do |dex_number, translations|
      puts "Dex ##{dex_number}:"
      translations.each do |lang, name|
        puts "  #{lang}: #{name}"
      end
    end
  rescue StandardError => e
    puts "An error occurred: #{e.message}"
    puts e.backtrace.join("\n")
  end
end
