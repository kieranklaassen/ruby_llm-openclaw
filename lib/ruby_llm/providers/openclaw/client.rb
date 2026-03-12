# frozen_string_literal: true

require "uri"

module RubyLLM
  module Providers
    class OpenClaw < Provider
      class Client
        DEFAULT_KEY_PATH = File.join(Dir.home, ".ruby_llm", "openclaw", "device.key").freeze
        DEFAULT_TIMEOUT = 120
        PROTOCOL_VERSION = 3
        CLIENT_ID = "gateway-client"
        CLIENT_MODE = "backend"
        CLIENT_PLATFORM = RUBY_PLATFORM.downcase.freeze
        CLIENT_DEVICE_FAMILY = "server"

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
                send_chat(connection, messages, session_key: build_session_key(agent), &block)
              end
            end
          end
        rescue Async::TimeoutError => e
          raise OpenClaw::TimeoutError, "Gateway timeout: #{e.message}"
        rescue Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError => e
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

        def public_key_base64url
          Base64.urlsafe_encode64(@signing_key.verify_key.to_bytes, padding: false)
        end

        def device_id
          Digest::SHA256.hexdigest(@signing_key.verify_key.to_bytes)
        end

        def sign(payload)
          Base64.urlsafe_encode64(@signing_key.sign(payload), padding: false)
        end

        def build_signature_payload(nonce:, token:, signed_at_ms:)
          [
            "v3",
            device_id,
            CLIENT_ID,
            CLIENT_MODE,
            "operator",
            "operator.read,operator.write",
            signed_at_ms.to_s,
            token,
            nonce,
            CLIENT_PLATFORM,
            CLIENT_DEVICE_FAMILY
          ].join("|")
        end

        # -- Authentication --

        def authenticate(connection)
          # Server sends: {"type":"event","event":"connect.challenge","payload":{"nonce":"...","ts":...}}
          challenge = read_message(connection)
          unless challenge&.dig("type") == "event" && challenge&.dig("event") == "connect.challenge"
            raise OpenClaw::AuthenticationError, "Expected connect.challenge, got: #{challenge}"
          end

          nonce = challenge.dig("payload", "nonce")
          raise OpenClaw::AuthenticationError, "No nonce in challenge" unless nonce

          signed_at_ms = (Time.now.to_f * 1000).to_i
          payload = build_signature_payload(nonce: nonce, token: @token, signed_at_ms: signed_at_ms)
          signature = sign(payload)

          connect_msg = {
            type: "req",
            id: SecureRandom.uuid,
            method: "connect",
            params: {
              minProtocol: PROTOCOL_VERSION,
              maxProtocol: PROTOCOL_VERSION,
              client: {
                id: CLIENT_ID,
                version: VERSION,
                platform: CLIENT_PLATFORM,
                mode: CLIENT_MODE,
                deviceFamily: CLIENT_DEVICE_FAMILY
              },
              role: "operator",
              scopes: ["operator.read", "operator.write"],
              caps: [],
              auth: { token: @token },
              device: {
                id: device_id,
                publicKey: public_key_base64url,
                signature: signature,
                signedAt: signed_at_ms,
                nonce: nonce
              }
            }
          }

          write_message(connection, connect_msg)

          # Server sends: {"type":"res","id":"...","ok":true,"payload":{"type":"hello-ok",...}}
          hello = read_message(connection)
          unless hello&.dig("type") == "res" && hello&.dig("ok") == true
            error_msg = hello&.dig("error", "message") || hello.to_s
            raise OpenClaw::AuthenticationError, "Authentication failed: #{error_msg}"
          end
        end

        # -- Sessions --

        def build_session_key(agent)
          "agent:#{agent}:main"
        end

        # -- Chat --

        def send_chat(connection, messages, session_key:, &block)
          # Format messages into a single string for chat.send
          # The Gateway expects `message` as a string, not an array
          message_text = messages.last&.dig(:content) || messages.last&.dig("content") || ""

          request = {
            type: "req",
            id: SecureRandom.uuid,
            method: "chat.send",
            params: {
              sessionKey: session_key,
              message: message_text,
              idempotencyKey: SecureRandom.uuid
            }
          }

          write_message(connection, request)

          # Read streaming events
          # Chat events: {"type":"event","event":"chat","payload":{"state":"delta"|"final"|"error",...}}
          loop do
            msg = read_message(connection)
            break unless msg

            case msg["type"]
            when "event"
              next unless msg["event"] == "chat"

              data = msg["payload"] || {}
              state = data["state"]

              case state
              when "delta"
                # Extract text content from the message field
                content = extract_content(data)
                block&.call(data.merge("content" => content)) if content
              when "final"
                content = extract_content(data)
                if content
                  block&.call(data.merge("content" => content, "usage" => data["usage"]))
                end
                break
              when "error"
                raise OpenClaw::Error, data["errorMessage"] || "Chat error"
              when "aborted"
                break
              end
            when "res"
              # Response to chat.send request (ack) — continue reading events
              unless msg["ok"]
                error_msg = msg.dig("error", "message") || "chat.send failed"
                raise OpenClaw::Error, error_msg
              end
            end
          end
        end

        def extract_content(data)
          msg = data["message"]
          case msg
          when String
            msg
          when Hash
            msg["content"] || msg["text"]
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
