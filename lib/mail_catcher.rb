#!/usr/bin/env -S falcon serve --bind http://127.0.0.1:7070 --count 1 -c
gem "mail", "~> 2.3"
gem "rack", "~> 2.2.3"
gem "sinatra", "~> 2.1.0"
gem "sqlite3", "~> 1.3"
gem "falcon", "~> 0.39.1"
gem "skinny", "~> 0.2.3"
gem "async", "~> 1.25"
gem "async-http", "~> 0.56.3"
gem "async-io", "~> 1.32.1"
gem "async-websocket", "~> 0.19.0"

require "optparse"
require "rbconfig"
require "socket"
require "async/io/address_endpoint"
require "async/http/endpoint"
require "async/websocket/adapters/rack"
require "mail"
require "falcon"
require "/Users/ahmedgagan/Rails Gem/mailcatcher/lib/mail_catcher/version.rb"

module MailCatcher extend self
  autoload :Mail, "/Users/ahmedgagan/Rails Gem/mailcatcher/lib/mail_catcher/mail.rb"
  autoload :SMTP, "/Users/ahmedgagan/Rails Gem/mailcatcher/lib/mail_catcher/smtp.rb"
  autoload :Web, "/Users/ahmedgagan/Rails Gem/mailcatcher/lib/mail_catcher/web.rb"

  def which?(command)
    ENV["PATH"].split(File::PATH_SEPARATOR).any? do |directory|
      File.executable?(File.join(directory, command.to_s))
    end
  end

  def windows?
    RbConfig::CONFIG["host_os"] =~ /mswin|mingw/
  end

  def browseable?
    windows? or which? "open"
  end

  def browse url
    if windows?
      system "start", "/b", url
    elsif which? "open"
      system "open", url
    end
  end

  def log_exception(message, context, exception)
    gems_paths = (Gem.path | [Gem.default_dir]).map { |path| Regexp.escape(path) }
    gems_regexp = %r{(?:#{gems_paths.join("|")})/gems/([^/]+)-([\w.]+)/(.*)}
    gems_replace = '\1 (\2) \3'

    puts "*** #{message}: #{context.inspect}"
    puts "    Exception: #{exception}"
    puts "    Backtrace:", *exception.backtrace.map { |line| "       #{line.sub(gems_regexp, gems_replace)}" }
    puts "    Please submit this as an issue at http://github.com/sj26/mailcatcher/issues"
  end

  @@defaults = {
    :smtp_ip => "127.0.0.1",
    :smtp_port => "1025",
    :http_ip => "127.0.0.1",
    :http_port => "1080",
    :http_path => "/",
    :verbose => false,
    :daemon => !windows?,
    :browse => false,
    :quit => true,
  }

  def options
    @@options
  end

  def quittable?
    options[:quit]
  end

  def parse! arguments=ARGV, defaults=@defaults
    @@defaults.dup.tap do |options|
      OptionParser.new do |parser|
        parser.banner = "Usage: mailcatcher [options]"
        parser.version = VERSION

        parser.on("--ip IP", "Set the ip address of both servers") do |ip|
          options[:smtp_ip] = options[:http_ip] = ip
        end

        parser.on("--smtp-ip IP", "Set the ip address of the smtp server") do |ip|
          options[:smtp_ip] = ip
        end

        parser.on("--smtp-port PORT", Integer, "Set the port of the smtp server") do |port|
          options[:smtp_port] = port
        end

        parser.on("--http-ip IP", "Set the ip address of the http server") do |ip|
          options[:http_ip] = ip
        end

        parser.on("--http-port PORT", Integer, "Set the port address of the http server") do |port|
          options[:http_port] = port
        end

        parser.on("--http-path PATH", String, "Add a prefix to all HTTP paths") do |path|
          clean_path = Rack::Utils.clean_path_info("/#{path}")

          options[:http_path] = clean_path
        end

        parser.on("--no-quit", "Don't allow quitting the process") do
          options[:quit] = false
        end

        unless windows?
          parser.on("-f", "--foreground", "Run in the foreground") do
            options[:daemon] = false
          end
        end

        if browseable?
          parser.on("-b", "--browse", "Open web browser") do
            options[:browse] = true
          end
        end

        parser.on("-v", "--verbose", "Be more verbose") do
          options[:verbose] = true
        end

        parser.on("-h", "--help", "Display this help information") do
          puts parser
          exit
        end
      end.parse!
    end
  end

  def run! options=nil
    # If we are passed options, fill in the blanks
    options &&= @@defaults.merge options
    # Otherwise, parse them from ARGV
    options ||= parse!

    # Stash them away for later
    @@options = options

    # If we're running in the foreground sync the output.
    unless options[:daemon]
      $stdout.sync = $stderr.sync = true
    end

    puts "Starting MailCatcher"

    if options[:verbose]
      Async.logger.level = Logger::DEBUG
    end
    puts "==> #{http_url}"

    Async::Reactor.run do |task|
      smtp_address = Async::IO::Address.tcp(options[:smtp_ip], options[:smtp_port])
      smtp_endpoint = Async::IO::AddressEndpoint.new(smtp_address)
      smtp_socket = rescue_port(options[:smtp_port]) { smtp_endpoint.bind }
      puts "==> #{smtp_url}"

      smtp_endpoint = MailCatcher::SMTP::URLEndpoint.new(URI.parse(smtp_url), smtp_endpoint)
      smtp_server = MailCatcher::SMTP::Server.new(smtp_endpoint) do |envelope|
        MailCatcher::Mail.add_message(sender: envelope.sender, recipients: envelope.recipients, source: envelope.content)
      end

      smtp_task = task.async do |task|
        task.annotate "binding to #{smtp_socket.local_address.inspect}"

        begin
          smtp_socket.listen(Socket::SOMAXCONN)
          smtp_socket.accept_each(task: task, &smtp_server.method(:accept))
        ensure
          smtp_socket.close
        end
      end

      # Puma::CLI.new(['-C', '/Users/ahmedgagan/Rails Gem/mailcatcher/lib/config/http_config.rb']).run
      http_address = Async::IO::Address.tcp(options[:http_ip], options[:http_port])
      http_endpoint = Async::IO::AddressEndpoint.new(http_address)
      # http_socket = rescue_port(options[:http_port]) { http_endpoint.bind }

      # web = MailCatcher::Web.new(mail: mail)

      http_endpoint = Async::HTTP::Endpoint.parse(http_url)

      http_app = Falcon::Server.middleware(WebSocketApp)
      http_server = Falcon::Server.new(http_app, http_endpoint)

      http_server.run.each(&:wait)
      # http_task = task.async do |task|
      #   task.annotate "binding to #{http_socket.local_address.inspect}"

      #   begin
      #     p http_socket.listen(Socket::SOMAXCONN)
      #     http_socket.accept_each(task: task, &http_server.method(:accept))
      #   ensure
      #     http_socket.close
      #   end
      # end

      if options[:browse]
        browse(http_url)
      end

      # Daemonize, if we should, but only after the servers have started.
      if options[:daemon]
        if quittable?
          puts "*** MailCatcher runs as a daemon by default. Go to the web interface to quit."
        else
          puts "*** MailCatcher is now running as a daemon that cannot be quit."
        end
        Process.daemon
      end
    end
  rescue Interrupt
    # Cool story
  end

  def quit!
    Async::Task.current.reactor.stop
  end

protected

  def smtp_url
    "smtp://#{@@options[:smtp_ip]}:#{@@options[:smtp_port]}"
  end

  def http_url
    "http://#{@@options[:http_ip]}:#{@@options[:http_port]}#{@@options[:http_path]}"
  end

  def rescue_port port
    begin
      return yield
    rescue Errno::EADDRINUSE
      puts "~~> ERROR: Something's using port #{port}. Are you already running MailCatcher?"
      puts "==> #{smtp_url}"
      puts "==> #{http_url}"
      exit -1
    end
  end
end

class WebSocketApp
  def self.call(env)
    web = MailCatcher::Web.new
    rack_app = Rack::Builder.app do
      map('/') { run web }
      run ->(_env) { [302, { 'Location' => MailCatcher.options[:http_path] }, []] }
    end

    Async::WebSocket::Adapters::Rack.open(env, protocols: %w[ws]) do |connection|
      # message = connection.read
      # p "<<<<<<  #{message}"
      # if message
      hash = {"id"=>1, "sender"=>"<me@fromdomain.com>", "recipients"=>["<test@todomain.com>"], "subject"=>"SMTP e-mail test", "size"=>"140", "type"=>"text/plain", "created_at"=>"2021-06-22T11:24:53+00:00"}
        connection.write hash
      # end

      # connection.close
    end or rack_app.call(env)
  end
end
