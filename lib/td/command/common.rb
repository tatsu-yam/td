require 'td/version'

module TreasureData

autoload :API, 'td/client/api'
autoload :Client, 'td/client'
autoload :Database, 'td/client'
autoload :Table, 'td/client'
autoload :Schema, 'td/client'
autoload :Job, 'td/client'

module Command

  class ParameterConfigurationError < ArgumentError
  end

  private
  def initialize
    @render_indent = ''
  end

  def get_client(opts={})
    unless opts.has_key?(:ssl)
      opts[:ssl] = Config.secure
    end
    apikey = Config.apikey
    unless apikey
      raise ConfigError, "Account is not configured."
    end
    opts[:user_agent] = "TD: #{TOOLBELT_VERSION}"
    if h = ENV['TD_API_HEADERS']
      pairs = h.split("\n")
      opts[:headers] = Hash[pairs.map {|pair| pair.split('=', 2) }]
    end
    Client.new(apikey, opts)
  end

  def get_ssl_client(opts={})
    opts[:ssl] = true
    get_client(opts)
  end

  def set_render_format_option(op)
    def op.render_format
      @_render_format
    end
    op.on('-f', '--format FORMAT', 'format of the result rendering (tsv, csv, json or table. default is table)') {|s|
      unless ['tsv', 'csv', 'json', 'table'].include?(s)
        raise "Unknown format #{s.dump}. Supported format: tsv, csv, json, table"
      end
      op.instance_variable_set(:@_render_format, s)
    }
  end

  def cmd_render_table(rows, *opts)
    require 'hirb'

    options = opts.first
    format = options.delete(:render_format)

    case format
    when 'csv', 'tsv'
      require 'csv'
      headers = options[:fields]
      csv_opts = {}
      csv_opts[:col_sep] = "\t" if format == 'tsv'
      CSV.generate('', csv_opts) { |csv|
        csv << headers
        rows.each { |row|
          r = []
          headers.each { |field|
            r << row[field]
          }
          csv << r
        }
      }
    when 'json'
      require 'yajl'

      Yajl.dump(rows)
    when 'table'
      Hirb::Helpers::Table.render(rows, *opts)
    else
      Hirb::Helpers::Table.render(rows, *opts)
    end
  end

  def normalized_message
    <<EOS
Your event has large number larger than 2^64.
These numbers are converted into string type.
So you should use cast operator, e.g. cast(v['key'] as decimal), in your query.
EOS
  end

  #def cmd_render_tree(nodes, *opts)
  #  require 'hirb'
  #  Hirb::Helpers::Tree.render(nodes, *opts)
  #end

  def cmd_debug_error(ex)
    if $verbose
      $stderr.puts "error: #{$!.class}: #{$!.to_s}"
      $!.backtrace.each {|b|
        $stderr.puts "  #{b}"
      }
        $stderr.puts ""
    end
  end

  def cmd_format_elapsed(start, finish)
    if start
      if !finish
        finish = Time.now.utc
      end
      e = finish.to_i - start.to_i
      elapsed = ''
      if e >= 3600
        elapsed << "#{e/3600}h "
        e %= 3600
        elapsed << "%2dm " % (e/60)
        e %= 60
        elapsed << "%2dsec" % e
      elsif e >= 60
        elapsed << "%2dm " % (e/60)
        e %= 60
        elapsed << "%2dsec" % e
      else
        elapsed << "%2dsec" % e
      end
    else
      elapsed = ''
    end
    elapsed = "% 13s" % elapsed  # right aligned
  end

  def get_database(client, db_name)
    begin
      return client.database(db_name)
    rescue
      cmd_debug_error $!
      $stderr.puts $!
      $stderr.puts "Use '#{$prog} database:list' to show the list of databases."
      exit 1
    end
    db
  end

  def get_table(client, db_name, table_name)
    db = get_database(client, db_name)
    begin
      table = db.table(table_name)
    rescue
      $stderr.puts $!
      $stderr.puts "Use '#{$prog} table:list #{db_name}' to show the list of tables."
      exit 1
    end
    #if type && table.type != type
    #  $stderr.puts "Table '#{db_name}.#{table_name} is not a #{type} table but a #{table.type} table"
    #end
    table
  end

  def ask_password(max=3, &block)
    3.times do
      begin
        system "stty -echo"  # TODO termios
        print "Password (typing will be hidden): "
        password = STDIN.gets || ""
        password = password[0..-2]  # strip \n
      rescue Interrupt
        $stderr.print "\ncanceled."
        exit 1
      ensure
        system "stty echo"   # TODO termios
        print "\n"
      end

      if password.empty?
        $stderr.puts "canceled."
        exit 0
      end

      yield password
    end
  end

end
end
