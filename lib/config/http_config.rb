mail = MailCatcher::Mail.new

http_address = Async::IO::Address.tcp("127.0.0.1", "1080")
http_endpoint = Async::IO::AddressEndpoint.new(http_address)

web = MailCatcher::Web.new(mail: mail)
app = Rack::Builder.app do
  map('/') { run web }
  run ->(_env) { [302, { 'Location' => MailCatcher.options[:http_path] }, []] }
end

app do |env|
  Async::WebSocket::Adapters::Rack.open(env, protocols: ['tcp', 'ws', 'wss']) do |connection|
    message = connection.read
  end or app.call(env)
end

bind 'tcp://127.0.0.1:1080'
