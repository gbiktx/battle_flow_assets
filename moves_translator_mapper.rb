require 'json'
require 'net/http'
require 'uri'
require_relative 'env'

def fetch_move_data(move_name_formatted)
  uri = URI("https://pokeapi.co/api/v2/move/#{move_name_formatted}/")
  response = Net::HTTP.get_response(uri)

  unless response.is_a?(Net::HTTPSuccess)
    puts "Error fetching data for move: #{move_name_formatted} (HTTP Status: #{response.code})"
    return nil
  end

  JSON.parse(response.body)
rescue JSON::ParserError => e
  puts "Error parsing JSON response for move: #{move_name_formatted} - #{e.message}"
  nil
rescue StandardError => e
  puts "An unexpected error occurred while fetching move data for #{move_name_formatted}: #{e.message}"
  nil
end

input_file = "#{Env::DATA_PATH}gamemaster.json"

unless File.exist?(input_file)
  puts "Error: Input file '#{input_file}' not found."
  exit
end

begin
  input_data = JSON.parse(File.read(input_file))
rescue JSON::ParserError => e
  puts "Error parsing input JSON file '#{input_file}': #{e.message}"
  exit
rescue StandardError => e
  puts "An unexpected error occurred while reading input file '#{input_file}': #{e.message}"
  exit
end

unless input_data.key?('moves') && input_data['moves'].is_a?(Array)
  puts "Error: Input JSON must contain a 'moves' key with an array of move objects."
  exit
end

all_translations = {}

input_data['moves'].each do |move|
  move_id_original = move['moveId']
  move_name = move['name']

  unless move_id_original
    puts "Warning: Skipping a move object with no 'moveId' key."
    next
  end

  move_id_formatted = move_name.gsub(/\(.*?\)/, '').gsub(/\s+/, ' ').strip.gsub('\'', '').gsub(' ', '-').downcase
  move_id_formatted = 'vice-grip' if move_id_formatted == 'vise-grip'


  move_data = fetch_move_data(move_id_formatted)

  if move_data && move_data.key?('names')
    move_data['names'].each do |name_entry|
      lang_code = name_entry['language']['name']
      translated_name = name_entry['name']

      all_translations[lang_code] ||= {}
      all_translations[lang_code][move_id_original] = translated_name
    end
  else
    puts "No translation data found for move: #{move_id_original}"
  end
end

all_translations.each do |lang_code, translations|
  file_name = "moves_#{lang_code}.json"
  output_file = File.join('localized_data/moves', file_name)
  begin
    File.write(output_file, JSON.pretty_generate(translations))
    puts "Created output file: #{file_name}"
  rescue StandardError => e
    puts "Error writing output file #{file_name}: #{e.message}"
  end
end

puts 'Script finished.'
