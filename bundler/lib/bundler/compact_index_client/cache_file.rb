# frozen_string_literal: true

require_relative "../vendored_fileutils"
require "rubygems/package"

module Bundler
  class CompactIndexClient
    # write cache files in a way that is robust to concurrent modifications
    # if digests are given, the checksums will be verified
    class CacheFile
      class DigestMismatchError < RuntimeError
        def initialize(digests, expected_digests)
          super "Local checksums #{digests.inspect} did not match #{expected_digests.inspect}."
        end
      end

      def self.copy(path, &block)
        new(path) do |file|
          file.initialize_digests
          file.copy
          yield file
        end
      end

      def self.write(path, data, digests = nil)
        return unless data
        new(path) do |file|
          file.digests = digests
          file.write(data)
        end
      end

      attr_reader :original_path, :path

      def initialize(original_path, &block)
        @original_path = original_path
        @path = original_path.sub(/$/, ".#{$$}.tmp")
        return unless block_given?
        begin
          yield self
        ensure
          close
        end
      end

      def size
        path.size
      end

      def initialize_digests(keys = nil)
        @digests = keys ? SUPPORTED_DIGESTS.slice(*keys) : SUPPORTED_DIGESTS.dup
        @digests.transform_values! {|algo_class| SharedHelpers.digest(algo_class).new }
      end

      # set the digests that will be verified at the end
      def digests=(expected_digests)
        @expected_digests = expected_digests

        if @expected_digests.nil?
          @digests = nil
        elsif @digests
          @digests = @digests.slice(*@expected_digests.keys)
        else
          initialize_digests(@expected_digests.keys)
        end
      end

      def digests?
        @digests&.any?
      end

      def open(*args)
        raise "Cannot reopen closed file" if @closed
        SharedHelpers.filesystem_access(path, :write) do
          path.open(*args) do |f|
            yield digests? ? Gem::Package::DigestIO.new(f, @digests) : f
          end
        end
      end

      def copy
        SharedHelpers.filesystem_access(@original_path, :read) do
          @original_path.open("rb") do |s|
            open("wb", s.stat.mode) {|f| IO.copy_stream(s, f) }
          end
        end
      end

      # Returns false without appending when no digests since appending is error prone
      def append(data)
        return false unless digests?
        open("a") {|f| f.write data }
        verify && commit
      end

      def write(data)
        @digests&.each_value(&:reset)
        open("wb") {|f| f.write data }
        commit!
      end

      def commit!
        verify || raise(DigestMismatchError.new(@expected_digests, @base64digests))
        commit
      end

      def verify
        return true unless @expected_digests && digests?
        @base64digests = @digests.transform_values!(&:base64digest)
        @digests = nil
        @base64digests.all? {|algo, digest| @expected_digests[algo] == digest }
      end

      def commit
        raise "Cannot commit closed file" if @closed
        SharedHelpers.filesystem_access(original_path, :write) do
          FileUtils.mv(path, original_path)
        end
        @closed = true
      end

      def close
        return if @closed
        FileUtils.remove_file(path) if @path&.file?
        @closed = true
      end
    end
  end
end
