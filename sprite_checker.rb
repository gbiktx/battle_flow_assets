require 'json'
require_relative 'env'

puts "Opening PvPoke Game Master..."
file = File.open("v1/gamemaster.json")

puts "Fetching Contents"
content = file.read

puts "Parsing JSON"
json = JSON.parse(content)

puts 'Checking sprites...'
required = []
optional = []
json['pokemon'].each { |p| 
    dex = p['dex']
    id = p['speciesId']

    if id.include?("mega") 
        next
    end

    speciesId = id.gsub("_xl", "").gsub("_xs", "").gsub("_shadow", "")

    if speciesId == "mr_mime_galarian"
        name = speciesId.split('_');
        spriteName = "#{dex}-#{name[2]}";
    elsif (speciesId.include?("_") &&
            dex != 29 && # Nidoran Female
            dex != 32 && # Nidoran Male
            dex != 122 && # Nidoran Male
            dex != 250 && # Ho-Oh
            dex != 474 && # Porygon-Z
            dex != 439 && # Mime (Jr)
            dex != 782 && # Jangmo-o
            dex != 783 && # Hakamo-o
            dex != 784 && # Kommo-o
            dex != 785 && # Tapu Koko
            dex != 786 && # Tapu Lele
            dex != 787 && # Tapu Bulu
            dex != 788 && # Tapu Fini
            dex != 866) # MR. Rime
        spriteName = "#{dex}-#{id.split('_')[1]}";
    else
        spriteName = "#{dex}";
    end

    unless (File.file?("#{Env::SPRITES_PATH}#{spriteName}.png"))
        if (p['released']) 
            required.push("name: #{id} sprite: #{spriteName}")
        else
            optional.push("name: #{id} sprite: #{spriteName}")
        end
    end
}

puts 'Required:'
puts
required.each { |name| puts "\e[31m#{name}\e[0m" }
puts 

puts 'Optional:'
puts
optional.each { |name| puts "\e[37m#{name}\e[0m" }

puts
puts "Task Completed! Missing: #{required.count}"