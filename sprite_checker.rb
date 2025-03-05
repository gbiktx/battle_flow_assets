require 'json'
require_relative 'env'

white_list = [
  29, # Nidoran Female
  32, # Nidoran Male
  122, # Nidoran Male
  250, # Ho-Oh
  474, # Porygon-Z
  439, # Mime (Jr)
  782, # Jangmo-o
  783, # Hakamo-o
  784, # Kommo-o
  785, # Tapu Koko
  786, # Tapu Lele
  787, # Tapu Bulu
  788, # Tapu Fini
  866, # MR. Rime
  1001, # Wo Chien
  1002, # Chien Pao
  1003, # Ting Lu
  1004 # Chi Yu
]
puts 'Opening PvPoke Game Master...'
file = File.open('v1/gamemaster.json')

puts 'Fetching Contents'
content = file.read

puts 'Parsing JSON'
json = JSON.parse(content)

puts 'Checking sprites...'
required = []
optional = []

json['pokemon'].each do |p|
  dex = p['dex']
  id = p['speciesId']

  species_id = id.gsub('_xl', '').gsub('_xs', '').gsub('_shadow', '')

  if species_id.include?('_alolan')
    sprite_name = "#{dex}-alolan"
  elsif species_id.include?('_galarian')
    sprite_name = "#{dex}-galarian"
  elsif species_id.include?('_hisuian')
    sprite_name = "#{dex}-hisuian"
  elsif species_id.include?('_') && !white_list.include?(dex)
    names = species_id.split('_')
    names[0] = dex
    sprite_name = names.join('-')
  else
    sprite_name = dex.to_s
  end

  unless File.file?("#{Env::SPRITES_PATH}#{sprite_name}.png")
    if p['released']
      required.push("name: #{id} sprite: #{sprite_name}")
    else
      optional.push("name: #{id} sprite: #{sprite_name}")
    end
  end
end

puts 'Required:'
puts
required.each { |name| puts "\e[31m#{name}\e[0m" }
puts

puts 'Optional:'
puts
optional.each { |name| puts "\e[37m#{name}\e[0m" }

puts
puts "Task Completed! Missing: #{required.count}"
