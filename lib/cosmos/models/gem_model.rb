# encoding: ascii-8bit

# Copyright 2021 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU Affero General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# This program may also be used under the terms of a commercial or
# enterprise edition license of COSMOS if purchased from the
# copyright holder

require 'open-uri'
require 'nokogiri'
require 'httpclient'

module Cosmos
  class GemModel
    GEMINABOX_URL = ENV['COSMOS_GEMS_URL'] || (ENV['COSMOS_DEVEL'] ? 'http://127.0.0.1:9292' : 'http://cosmos-gems:9292')

    def self.get(name, dir)
      client = HTTPClient.new(nil)
      path = File.join(dir, name)
      File.open(path, 'wb') do |file|
        file.write(client.get_content("#{GEMINABOX_URL}/gems/#{name}"))
      end
      return path
    end

    def self.put(gem_file_path)
      # Install gem to geminabox - gem push pkg/my-awesome-gem-1.0.gem --host HOST
      result = false
      thread = Thread.new do
        result = system("gem inabox #{gem_file_path} --host #{GEMINABOX_URL}")
      end
      thread.join
      return result
    end

    def self.destroy(name)
      gem_dot_split = name.split('.')
      gem_dot_dash_split = gem_dot_split[0].split('-')
      gem_name = gem_dot_dash_split[0..-2].join('-')
      gem_version = [gem_dot_dash_split[-1]].concat(gem_dot_split[1..-2]).join('.')

      #STDOUT.puts "Removing gem: #{name} (#{gem_name} -v #{gem_version})"

      # Remove gem from geminabox - gem yank my-awesome-gem -v 1.0 --host HOST
      result = false
      thread = Thread.new do
        result = system("gem yank #{gem_name} -v #{gem_version} --host #{GEMINABOX_URL}")
      end
      thread.join
      return result
    end

    def self.names
      doc = Nokogiri::XML(URI.open("#{GEMINABOX_URL}/atom.xml"))
      doc.remove_namespaces!
      gems = []
      doc.xpath('//entry/link').each do |a|
        gems << File.basename(a.attributes['href'])
      end
      gems
    end
  end
end