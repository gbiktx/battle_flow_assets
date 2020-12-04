require 'json'

puts "Opening PvPoke Game Master..."
file = File.open('gamemaster.json')

puts "Fetching Contents"
content = file.read

puts "Parsing JSON"
json = JSON.parse(content)

puts 'Generating our game master...'
filtered = { pokemon: json['pokemon'], moves: json['moves'] }
File.open("filtered_gamemaster.json", 'w') do |new_file|
    new_file.write(filtered.to_json)
end

puts 'Task Completed!'