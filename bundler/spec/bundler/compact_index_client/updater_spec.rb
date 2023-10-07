# frozen_string_literal: true

require "net/http"
require "bundler/compact_index_client"
require "bundler/compact_index_client/updater"
require "tmpdir"

RSpec.describe Bundler::CompactIndexClient::Updater do
  subject(:updater) { described_class.new(fetcher) }

  let(:fetcher) { double(:fetcher) }
  let(:local_path) { Pathname.new(Dir.mktmpdir("localpath")).join("versions") }
  let(:etag_path) { Pathname.new(Dir.mktmpdir("localpath-etags")).join("versions.etag") }
  let(:remote_path) { double(:remote_path) }

  let(:response_body) { "abc123" }
  let(:response) { double(:response, :body => response_body, :is_a? => false) }

  context "when the local path does not exist" do
    let(:digest) { Digest::SHA256.base64digest("abc123") }

    before do
      allow(response).to receive(:[]).with("Repr-Digest") { nil }
      allow(response).to receive(:[]).with("Digest") { nil }
      allow(response).to receive(:[]).with("ETag") { "thisisanetag" }
    end

    it "downloads the file without attempting append" do
      expect(fetcher).to receive(:call).once.with(remote_path, {}) { response }

      updater.update(remote_path, local_path, etag_path)

      expect(local_path.read).to eq("abc123")
      expect(etag_path.read).to eq("thisisanetag")
    end

    it "fails immediately on bad checksum" do
      expect(fetcher).to receive(:call).once.with(remote_path, {}) { response }
      allow(response).to receive(:[]).with("Repr-Digest") { "sha-256=:baddigest:" }

      expect do
        updater.update(remote_path, local_path, etag_path)
      end.to raise_error(Bundler::CompactIndexClient::Updater::MismatchedChecksumError)
    end
  end

  context "when the local path exists" do
    let(:response) { double(:response, :body => "abc123") }
    let(:digest) { Digest::SHA256.base64digest("abc123") }
    let(:headers) { { "Range" => "bytes=2-" } }

    before do
      local_path.open("w") {|f| f.write("abc") }
    end

    it "appends the file" do
      expect(fetcher).to receive(:call).once.with(remote_path, headers).and_return(response)
      allow(response).to receive(:[]).with("Repr-Digest") { "sha-256=:#{digest}:" }
      allow(response).to receive(:[]).with("ETag") { "thisisanetag" }
      allow(response).to receive(:is_a?).with(Net::HTTPPartialContent) { true }
      allow(response).to receive(:is_a?).with(Net::HTTPNotModified) { false }
      allow(response).to receive(:body) { "c123" }

      updater.update(remote_path, local_path, etag_path)

      expect(local_path.read).to eq("abc123")
      expect(etag_path.read).to eq("thisisanetag")
    end

    context "with an etag" do
      before do
        etag_path.open("w") {|f| f.write("thisisanetag") }
      end

      let(:headers) do
        {
          "If-None-Match" => "thisisanetag",
          "Range" => "bytes=2-",
        }
      end

      it "does nothing if etags match" do
        expect(fetcher).to receive(:call).once.with(remote_path, headers).and_return(response)
        allow(response).to receive(:is_a?).with(Net::HTTPPartialContent) { false }
        allow(response).to receive(:is_a?).with(Net::HTTPNotModified) { true }

        updater.update(remote_path, local_path, etag_path)

        expect(local_path.read).to eq("abc")
        expect(etag_path.read).to eq("thisisanetag")
      end

      it "appends the file if etags do not match" do
        expect(fetcher).to receive(:call).once.with(remote_path, headers).and_return(response)
        allow(response).to receive(:[]).with("Repr-Digest") { "sha-256=:#{digest}:" }
        allow(response).to receive(:[]).with("ETag") { "ThisIsNOTtheRightEtag" }
        allow(response).to receive(:is_a?).with(Net::HTTPPartialContent) { true }
        allow(response).to receive(:is_a?).with(Net::HTTPNotModified) { false }
        allow(response).to receive(:body) { "c123" }

        updater.update(remote_path, local_path, etag_path)

        expect(local_path.read).to eq("abc123")
        expect(etag_path.read).to eq("ThisIsNOTtheRightEtag")
      end

      it "replaces the file if response ignores range" do
        expect(fetcher).to receive(:call).once.with(remote_path, headers).and_return(response)
        allow(response).to receive(:[]).with("Repr-Digest") { "sha-256=:#{digest}:" }
        allow(response).to receive(:[]).with("ETag") { "ThisIsNOTtheRightEtag" }
        allow(response).to receive(:is_a?).with(Net::HTTPPartialContent) { false }
        allow(response).to receive(:is_a?).with(Net::HTTPNotModified) { false }
        allow(response).to receive(:body) { "abc123" }

        updater.update(remote_path, local_path, etag_path)

        expect(local_path.read).to eq("abc123")
        expect(etag_path.read).to eq("ThisIsNOTtheRightEtag")
      end
    end
  end

  context "when the ETag header is missing" do
    # Regression test for https://github.com/rubygems/bundler/issues/5463
    let(:response) { double(:response, :body => "abc123") }

    it "treats the response as an update" do
      allow(response).to receive(:[]).with("Repr-Digest") { nil }
      allow(response).to receive(:[]).with("Digest") { nil }
      allow(response).to receive(:[]).with("ETag") { nil }
      expect(fetcher).to receive(:call) { response }

      updater.update(remote_path, local_path, etag_path)
    end
  end

  context "when the download is corrupt" do
    let(:response) { double(:response, :body => "") }

    it "raises HTTPError" do
      expect(fetcher).to receive(:call).and_raise(Zlib::GzipFile::Error)

      expect do
        updater.update(remote_path, local_path, etag_path)
      end.to raise_error(Bundler::HTTPError)
    end
  end

  context "when receiving non UTF-8 data and default internal encoding set to ASCII" do
    let(:response) { double(:response, :body => "\x8B".b) }

    it "works just fine" do
      old_verbose = $VERBOSE
      previous_internal_encoding = Encoding.default_internal

      begin
        $VERBOSE = false
        Encoding.default_internal = "ASCII"
        allow(response).to receive(:[]).with("Repr-Digest") { nil }
        allow(response).to receive(:[]).with("Digest") { nil }
        allow(response).to receive(:[]).with("ETag") { nil }
        expect(fetcher).to receive(:call) { response }

        updater.update(remote_path, local_path, etag_path)
      ensure
        Encoding.default_internal = previous_internal_encoding
        $VERBOSE = old_verbose
      end
    end
  end
end
