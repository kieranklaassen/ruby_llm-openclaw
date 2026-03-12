# frozen_string_literal: true

require "uri"

module RubyLLM
  module Providers
    class OpenClaw < Provider
      class Client
        DEFAULT_KEY_PATH = File.join(Dir.home, ".ruby_llm", "openclaw", "device.key").freeze
        DEFAULT_TIMEOUT = 120

        def initialize(config, key_path: DEFAULT_KEY_PATH)
          @url = config.openclaw_url
          @token = config.openclaw_token
          @timeout = config.respond_to?(:request_timeout) ? (config.request_timeout || DEFAULT_TIMEOUT) : DEFAULT_TIMEOUT
          @key_path = key_path

          warn_insecure_transport!
          validate_token!(@token)
          load_or_generate_keypair!
        end

        def chat_send(messages, agent:, &block)
          validate_agent_name!(agent)

          Sync do |task|
            endpoint = Async::HTTP::Endpoint.parse(
              @url,
              alpn_protocols: Async::HTTP::Protocol::HTTP11.names
            )

            task.with_timeout(@timeout) do
              Async::WebSocket::Client.connect(endpoint) do |connection|
                authenticate(connection)
                send_chat(connection, messages, agent: agent, &block)
              end
            end
          end
        rescue Async::TimeoutError => e
          raise OpenClaw::TimeoutError, "Gateway timeout: #{e.message}"
        rescue Errno::ECONNREFUSED => e
          raise OpenClaw::ConnectionError, "Cannot connect to Gateway: #{e.message}"
        end

        private

        # -- Device identity --

        def load_or_generate_keypair!
          if File.exist?(@key_path)
            validate_key_permissions!
            seed = File.binread(@key_path)
            @signing_key = Ed25519::SigningKey.new(seed)
          else
            @signing_key = Ed25519::SigningKey.generate
            persist_key!
          end
        end

        def persist_key!
          dir = File.dirname(@key_path)
          FileUtils.mkdir_p(dir, mode: 0o700)
          # Set directory permissions explicitly (mkdir_p may not respect mode on existing dirs)
          File.chmod(0o700, dir)
          File.open(@key_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
            f.write(@signing_key.seed)
          end
        end

        def validate_key_permissions!
          stat = File.stat(@key_path)
          return if stat.mode & 0o077 == 0

          raise SecurityError, "#{@key_path} has insecure permissions #{format('%04o', stat.mode & 0o777)}. " \
                               "Expected 0600. Fix with: chmod 600 #{@key_path}"
        end

        def public_key_hex
          @signing_key.verify_key.to_bytes.unpack1("H*")
        end

        def device_id
          Digest::SHA256.hexdigest(@signing_key.verify_key.to_bytes)
        end

        def sign(payload)
          @signing_key.sign(payload).unpack1("H*")
        end

        def build_signature_payload(nonce:, token:, signed_at_ms:)
          [
            "v2",
            device_id,
            "ruby_llm",
            "provider",
            "operator",
            "operator.read,operator.write",
            signed_at_ms.to_s,
            token,
            nonce
          ].join("|")
        end

        # -- Authentication --

        def authenticate(connection)
          # Read challenge
          challenge = read_message(connection)
          raise OpenClaw::AuthenticationError, "Expected connect.challenge" unless challenge&.dig("method") == "connect.challenge"

          nonce = challenge.dig("params", "nonce")
          raise OpenClaw::AuthenticationError, "No nonce in challenge" unless nonce

          # Build and send connect message
          signed_at_ms = (Time.now.to_f * 1000).to_i
          payload = build_signature_payload(nonce: nonce, token: @token, signed_at_ms: signed_at_ms)
          signature = sign(payload)

          connect_msg = {
            type: "req",
            id: SecureRandom.uuid,
            method: "connect",
            params: {
              device: {
                id: device_id,
                publicKey: public_key_hex,
                signature: signature,
                signedAt: signed_at_ms,
                nonce: nonce
              },
              auth: { token: @token },
              role: "operator",
              scopes: ["operator.read", "operator.write"]
            }
          }

          write_message(connection, connect_msg)

          # Read hello-ok
          hello = read_message(connection)
          raise OpenClaw::AuthenticationError, "Authentication failed: #{hello}" unless hello&.dig("method") == "hello-ok"
        end

        # -- Chat --

        def send_chat(connection, messages, agent:, &block)
          request = {
            type: "req",
            id: SecureRandom.uuid,
            method: "chat.send",
            params: {
              agent: agent,
              messages: messages
            }
          }

          write_message(connection, request)

          # Read streaming events
          loop do
            msg = read_message(connection)
            break unless msg

            case msg["type"]
            when "event"
              event = msg["event"]
              data = msg["payload"] || msg["data"] || {}

              case event
              when "chat.token", "chat.chunk"
                block&.call(data)
              when "chat.done", "chat.complete"
                block&.call(data) if data["content"] || data["text"]
                break
              when "chat.error"
                raise OpenClaw::Error, data["message"] || "Chat error"
              end
            when "error"
              raise OpenClaw::Error, msg["message"] || "Gateway error"
            end
          end
        end

        # -- WebSocket I/O --

        def write_message(connection, data)
          connection.write(Protocol::WebSocket::TextMessage.generate(data))
          connection.flush
        end

        def read_message(connection)
          message = connection.read
          return nil unless message

          JSON.parse(message.to_str)
        end

        # -- Validation --

        def validate_agent_name!(name)
          raise ArgumentError, "Invalid agent name: #{name.inspect}" unless name.match?(/\A[a-zA-Z0-9_-]+\z/)
        end

        def validate_token!(token)
          raise ArgumentError, "Token must not contain pipe character" if token&.include?("|")
        end

        def warn_insecure_transport!
          return unless @url&.start_with?("ws://")

          host = URI.parse(@url).host
          return if %w[localhost 127.0.0.1 ::1].include?(host)

          warn "[ruby_llm-openclaw] WARNING: Using unencrypted WebSocket to non-loopback address #{host}. Use wss:// for production."
        end
      end
    end
  end
end
