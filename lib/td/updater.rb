# -*- coding: utf-8 -*-
require "fileutils"
require "shellwords"
require "zip/zip"

module TreasureData
  module Updater
    #
    # Toolbelt upgrade
    #

    DEFAULT_TOOLBELT_URL = "http://toolbelt.treasuredata.com/"

    def self.raise_error(message)
      # TODO: Replace better Exception class
      raise RuntimeError.new(message)
    end

    # copied from TreasureData::Helpers to avoid load issue.
    def self.home_directory
      on_windows? ? ENV['USERPROFILE'].gsub("\\","/") : ENV['HOME']
    end

    def self.on_windows?
      RUBY_PLATFORM =~ /mswin32|mingw32/
    end

    def self.on_mac?
      RUBY_PLATFORM =~ /-darwin\d/
    end

    def self.updating_lock_path
      File.join(home_directory, ".td", "updating")
    end

    def self.installed_client_path
      File.expand_path("../../../../../..", __FILE__)
    end

    def self.updated_client_path
      File.join(home_directory, ".td", "updated")
    end

    def self.latest_local_version
      installed_version = client_version_from_path(installed_client_path)
      updated_version = client_version_from_path(updated_client_path)
      if compare_versions(updated_version, installed_version) > 0
        updated_version
      else
        installed_version
      end
    end

    def self.get_client_version_file(path)
      td_gems = Dir[File.join(path, "vendor/gems/td-*")]
      td_gems.each { |td_gem|
        if td_gem =~ /#{"#{Regexp.escape(path)}\/vendor\/gems\/td-\\d*.\\d*.\\d*"}/
          return File.join(td_gem, "/lib/td/version.rb")
        end
      }
      nil
    end

    def self.client_version_from_path(path)
      if version_file = get_client_version_file(path)
        File.read(version_file).match(/VERSION = '([^']+)'/)[1]
      else
        '0.0.0'
      end
    end

    def self.disable(message)
      @disable = message
    end

    def self.disable?
      !@disable.nil?
    end

    def self.disable_message
      @disable
    end

    def self.wait_for_lock(path, wait_for = 5, check_every = 0.5)
      start = Time.now.to_i
      while File.exists?(path)
        sleep check_every
        if (Time.now.to_i - start) > wait_for
          raise_error "Unable to acquire update lock"
        end
      end
      begin
        FileUtils.touch(path)
        ret = yield
      ensure
        FileUtils.rm_f(path)
      end
      ret
    end

    def self.package_category
      case
      when on_windows?
        'exe'
      when on_mac?
        'pkg'
      else
        raise_error "Non supported environment"
      end
    end

    def self.fetch(uri)
      require 'net/http'
      require 'openssl'

      # open-uri can't treat 'http -> https' redirection and
      # Net::HTTP.get_response can't get response from HTTPS endpoint.
      # So we use following code to avoid above issues.
      u = URI(uri)
      response =
        if u.scheme == 'https'
          http = Net::HTTP.new(u.host, u.port)
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
          http.request(Net::HTTP::Get.new(u.path))
        else
          Net::HTTP.get_response(u)
        end

      case response
      when Net::HTTPSuccess then response.body
      when Net::HTTPRedirection then fetch(response['Location'])
      else
        raise "An error occurred when fetching from '#{uri}'."
        response.error!
      end
    end

    def self.endpoint_root
      ENV['TD_TOOLBELT_UPDATE_ROOT'] || DEFAULT_TOOLBELT_URL
    end
    #puts "endpoint_root: #{self.endpoint_root}"

    def self.version_endpoint
      "#{endpoint_root}/version.#{package_category}"
    end

    def self.update_package_endpoint
      "#{endpoint_root}/td-update-#{package_category}.zip"
    end

    def self.update(autoupdate = false)
      wait_for_lock(updating_lock_path, 5) do
        require "td"
        require 'open-uri'
        require "tmpdir"
        require "zip/zip"

        latest_version = fetch(version_endpoint)

        if compare_versions(latest_version, latest_local_version) > 0
          Dir.mktmpdir do |download_dir|
            print "Downloading updated toolbelt package..."
            File.open("#{download_dir}/td-update.zip", "wb") do |file|
              stream_fetch(update_package_endpoint, file)
            end
            print "done\n"

            print "Unpacking updated toolbelt package..."
            Zip::ZipFile.open("#{download_dir}/td-update.zip") do |zip|
              zip.each do |entry|
                target = File.join(download_dir, entry.to_s)
                FileUtils.mkdir_p(File.dirname(target))
                zip.extract(entry, target) { true }
              end
            end
            print "done\n"

            FileUtils.rm "#{download_dir}/td-update.zip"

            old_version = latest_local_version
            new_version = client_version_from_path(download_dir)

            if compare_versions(new_version, old_version) < 0 && !autoupdate
              raise_error "Installed version (#{old_version}) is newer than the latest available update (#{new_version})"
            end

            FileUtils.rm_rf updated_client_path
            FileUtils.mkdir_p File.dirname(updated_client_path)
            FileUtils.cp_r(download_dir, updated_client_path)

            new_version
          end
        else
          false # already up to date
        end
      end
    ensure
      FileUtils.rm_f(updating_lock_path)
    end

    def self.compare_versions(first_version, second_version)
      first_version.split('.').map { |part| Integer(part) rescue part } <=> second_version.split('.').map { |part| Integer(part) rescue part }
    end

    def self.inject_libpath
      old_version = client_version_from_path(installed_client_path)
      new_version = client_version_from_path(updated_client_path)

      if compare_versions(new_version, old_version) > 0
        vendored_gems = Dir[File.join(updated_client_path, "vendor", "gems", "*")]
        vendored_gems.each do |vendored_gem|
          $:.unshift File.join(vendored_gem, "lib")
        end
        load('td/updater.rb') # reload updated updater
      end

      # check every hour if the toolbelt can be updated.
      # => If so, update in the background
      if File.exists?(last_toolbelt_autoupdate_timestamp)
        return if (Time.now.to_i - File.mtime(last_toolbelt_autoupdate_timestamp).to_i) < 60 * 60 * 1 # every 1 hours
      end
      log_path = File.join(home_directory, '.td', 'autoupdate.log')
      FileUtils.mkdir_p File.dirname(log_path)
      td_binary = File.expand_path($0)
      pid = if defined?(RUBY_VERSION) and RUBY_VERSION =~ /^1\.8\.\d+/
        fork do
          exec("#{Shellwords.escape(td_binary)} update &> #{Shellwords.escape(log_path)} 2>&1")
        end
      else
        log_file = File.open(log_path, "w")
        spawn(td_binary, 'update', :err => log_file, :out => log_file)
      end
      Process.detach(pid)
      FileUtils.mkdir_p File.dirname(last_toolbelt_autoupdate_timestamp)
      FileUtils.touch last_toolbelt_autoupdate_timestamp
    end

    def self.last_toolbelt_autoupdate_timestamp
      File.join(home_directory, ".td", "autoupdate.last")
    end

    #
    # td-import.jar upgrade
    #

    # locate the root of the td package which is 3 folders up from the location of this file
    INSTALLED_PATH = File.join(File.expand_path('../..', File.dirname(__FILE__)), 'java')
    UPDATED_PATH = File.join(Updater.home_directory, ".td", "java")

    MAVEN_REPO = "http://maven.treasure-data.com/com/treasure_data/td-import"

    private
    def stream_fetch(url, binfile)
      require 'net/http'

      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      if uri.scheme == 'https'
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      http.start
      request = Net::HTTP::Get.new(uri.to_s)
      http.request request do |response|
        if response.class == Net::HTTPOK
          # print a . every tick_period seconds
          tick_period = 2 # seconds
          last_tick_time = Time.new.to_i + tick_period
          response.read_body do |chunk|
            binfile.write chunk
            if Time.new.to_i > last_tick_time
              print "."
              last_tick_time += tick_period
            end
          end
          return true
        elsif response.class == Net::HTTPFound || \
              response.class == Net::HTTPRedirection
          #puts "redirect " + url + " " + response['Location']
          return stream_fetch(response['Location'], binfile)
        else
          raise "An error occurred when fetching from '#{uri}'."
          return false
        end
      end
    end

    private
    def jar_update(hourly = false)
      require 'rexml/document'
      require 'open-uri'
      require 'fileutils'

      doc = REXML::Document.new(open("#{MAVEN_REPO}/maven-metadata.xml") { |f| f.read })
      updated = Time.strptime(REXML::XPath.match(doc, '/metadata/versioning/lastUpdated').first.text, "%Y%m%d%H%M%S")
      version = REXML::XPath.match(doc, '/metadata/versioning/release').first.text

      # Convert into UTF to compare time correctly
      updated = (updated + updated.gmt_offset).utc unless updated.gmt?
      last_updated = existent_jar_updated_time

      if updated > last_updated
        FileUtils.mkdir_p(UPDATED_PATH) unless File.exists?(UPDATED_PATH)
        Dir.chdir UPDATED_PATH

        File.open('VERSION', 'w') { |f| f.print "#{version} via import:jar_update" }
        File.open('td-import-java.version', 'w') { |f| f.print "#{version} #{updated}" }

        print "Updating td-import.jar..."
        binfile = File.open 'td-import.jar.new', 'wb'
        status = stream_fetch "#{MAVEN_REPO}/#{version}/td-import-#{version}-jar-with-dependencies.jar", binfile
        print "done\n"
        binfile.close

        if status
          puts "Installed td-import.jar v#{version} in '#{UPDATED_PATH}'.\n"
          File.rename 'td-import.jar.new', 'td-import.jar'
        else
          #puts "Update of td-import.jar failed."
          File.delete 'td-import.jar.new' if File.exists? 'td-import.jar.new'
        end
      else
        puts 'Installed td-import.jar is already at the latest version.' unless hourly
      end
    end

    def check_n_update_jar(hourly = false)
      if hourly && \
         File.exists?(last_jar_autoupdate_timestamp) && \
         (Time.now - File.mtime(last_jar_autoupdate_timestamp)).to_i < (60 * 60 * 1) # every hour
        return
      end
      jar_update(hourly)
      FileUtils.touch File.join(UPDATED_PATH, "td-import-java.version")
    end

    private
    def last_jar_autoupdate_timestamp
      File.join(UPDATED_PATH, "td-import-java.version")
    end

    private
    def existent_jar_updated_time
      files = find_files("td-import-java.version", [UPDATED_PATH])
      if files.empty?
        return Time.at(0)
      end
      content = File.open(files.first).read
      index = content.index(' ')
      time = nil
      if index.nil?
        time = Time.at(0).utc
      else
        time = Time.parse(content[index+1..-1].strip).utc
      end
      time
    end

    #
    # Helpers
    #
    def find_files(glob, locations)
      files = []
      locations.each {|loc|
        files = Dir.glob("#{loc}/#{glob}")
        break unless files.empty?
      }
      files
    end

    def find_version_file
      version = find_files('VERSION', [UPDATED_PATH])
      if version.empty?
        $stderr.puts "Cannot find VERSION file in '#{UPDATED_PATH}'."
        exit 10
      end
      version.first
    end

    def find_td_import_jar
      jar = find_files('td-import.jar', [UPDATED_PATH])
      if jar.empty?
        $stderr.puts "Cannot find td-import.jar in '#{UPDATED_PATH}'."
        exit 10
      end
      jar.first
    end

    def find_logging_property
      config = find_files("logging.properties", [INSTALLED_PATH])
      if config.empty?
        unless ENV['TD_TOOLBELT_DEBUG'].nil?
          puts "Cannot find 'logging.properties' file in '#{UPDATED_PATH}'."
        end
        []
      else
        config.first
      end
    end

  end # end of module Updater
end # end of module TreasureData