# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class OpenClawClientTest < Minitest::Test
  def setup
    @key_dir = Dir.mktmpdir("openclaw_test")
    @config = RubyLLM.config.dup
    @config.openclaw_url = "ws://localhost:18789"
    @config.openclaw_token = "test-token-abc123"
  end

  def teardown
    FileUtils.rm_rf(@key_dir)
  end

  # -- Device identity --

  def test_generates_ed25519_keypair
    client = build_client

    assert File.exist?(key_path), "Key file should be created"
    assert_equal 32, File.binread(key_path).bytesize, "Ed25519 seed is 32 bytes"
  end

  def test_key_file_permissions
    build_client

    stat = File.stat(key_path)
    mode = stat.mode & 0o777
    assert_equal 0o600, mode, "Key file should have 0600 permissions"
  end

  def test_key_directory_permissions
    build_client

    stat = File.stat(@key_dir)
    mode = stat.mode & 0o777
    assert_equal 0o700, mode, "Key directory should have 0700 permissions"
  end

  def test_reuses_existing_keypair
    client1 = build_client
    pub1 = client1.send(:public_key_base64url)

    client2 = build_client
    pub2 = client2.send(:public_key_base64url)

    assert_equal pub1, pub2, "Should reuse the same keypair"
  end

  def test_public_key_is_base64url_encoded
    client = build_client
    pub = client.send(:public_key_base64url)

    # base64url: no +, /, or = characters
    refute_match(/[+\/=]/, pub)

    # Decodes to 32 bytes (Ed25519 public key)
    raw = Base64.urlsafe_decode64(pub)
    assert_equal 32, raw.bytesize
  end

  def test_device_id_is_sha256_of_raw_public_key
    client = build_client
    pub_b64 = client.send(:public_key_base64url)
    raw_bytes = Base64.urlsafe_decode64(pub_b64)
    expected = Digest::SHA256.hexdigest(raw_bytes)

    assert_equal expected, client.send(:device_id)
  end

  def test_refuses_insecure_key_permissions
    build_client
    File.chmod(0o644, key_path)

    assert_raises(SecurityError) do
      build_client
    end
  end

  # -- Signature --

  def test_sign_payload_format_v3
    client = build_client
    nonce = "test-nonce-uuid"
    token = "my-token"
    signed_at_ms = 1_700_000_000_000

    payload = client.send(:build_signature_payload, nonce: nonce, token: token, signed_at_ms: signed_at_ms)

    parts = payload.split("|")
    client_class = RubyLLM::Providers::OpenClaw::Client

    assert_equal 11, parts.size, "v3 payload has 11 pipe-delimited fields"
    assert_equal "v3", parts[0]
    assert_equal client.send(:device_id), parts[1]
    assert_equal "gateway-client", parts[2]
    assert_equal client_class::CLIENT_MODE, parts[3]
    assert_equal "operator", parts[4]
    assert_equal "operator.read,operator.write", parts[5]
    assert_equal signed_at_ms.to_s, parts[6]
    assert_equal token, parts[7]
    assert_equal nonce, parts[8]
    assert_equal client_class::CLIENT_PLATFORM, parts[9]
    assert_equal client_class::CLIENT_DEVICE_FAMILY, parts[10]
  end

  def test_sign_produces_valid_base64url_ed25519_signature
    client = build_client
    nonce = "test-nonce"
    token = "my-token"
    signed_at_ms = 1_700_000_000_000

    payload = client.send(:build_signature_payload, nonce: nonce, token: token, signed_at_ms: signed_at_ms)
    signature_b64 = client.send(:sign, payload)

    # Signature should be base64url (no +, /, or = characters)
    refute_match(/[+\/=]/, signature_b64)

    # Verify with Ed25519
    pub_b64 = client.send(:public_key_base64url)
    verify_key = Ed25519::VerifyKey.new(Base64.urlsafe_decode64(pub_b64))
    signature_bytes = Base64.urlsafe_decode64(signature_b64)

    # Should not raise
    verify_key.verify(signature_bytes, payload)
  end

  # -- Input validation --

  def test_validates_agent_name
    client = build_client

    assert_raises(ArgumentError) { client.send(:validate_agent_name!, "bad agent name") }
    assert_raises(ArgumentError) { client.send(:validate_agent_name!, "../escape") }
    assert_raises(ArgumentError) { client.send(:validate_agent_name!, "") }

    # Valid names should not raise
    client.send(:validate_agent_name!, "my-agent")
    client.send(:validate_agent_name!, "agent_v2")
    client.send(:validate_agent_name!, "Agent123")
  end

  def test_validates_token_no_pipe
    client = build_client

    assert_raises(ArgumentError) { client.send(:validate_token!, "bad|token") }

    # Valid token should not raise
    client.send(:validate_token!, "valid-token-123")
  end

  # -- Transport security --

  def test_warns_on_ws_to_non_loopback
    @config.openclaw_url = "ws://remote-host.com:18789"
    output = capture_io { build_client }.last

    assert_match(/WARNING.*unencrypted.*non-loopback/i, output)
  end

  def test_no_warning_for_ws_localhost
    @config.openclaw_url = "ws://localhost:18789"
    output = capture_io { build_client }.last

    refute_match(/WARNING/, output)
  end

  def test_no_warning_for_wss
    @config.openclaw_url = "wss://remote-host.com:18789"
    output = capture_io { build_client }.last

    refute_match(/WARNING/, output)
  end

  def test_no_warning_for_ws_127_0_0_1
    @config.openclaw_url = "ws://127.0.0.1:18789"
    output = capture_io { build_client }.last

    refute_match(/WARNING/, output)
  end

  private

  def key_path
    File.join(@key_dir, "device.key")
  end

  def build_client
    RubyLLM::Providers::OpenClaw::Client.new(@config, key_path: key_path)
  end
end
