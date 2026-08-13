#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require 'pathname'
require 'tmpdir'

module HelixCocoaPods
  PRODUCTS = {
    'HelixAppRuntime' => %w[
      HelixCore
      HelixBytecode
      HelixInterface
      HelixVerifier
      HelixVM
      HelixRuntime
      HelixPatch
    ],
    'HelixDevAppRuntime' => %w[
      HelixCore
      HelixBytecode
      HelixInterface
      HelixVerifier
      HelixVM
      HelixRuntime
      HelixPatch
      HelixLiveReloadAPI
      HelixDevProtocol
      HelixDevRuntime
    ]
  }.freeze

  INTERNAL_MODULES = (
    PRODUCTS.values.flatten + ['HelixRuntimeSupport']
  ).uniq.freeze
  INTERNAL_IMPORT = /\Aimport (#{INTERNAL_MODULES.join('|')})\s*\z/

  class Error < StandardError; end

  class Generator
    def initialize(repository_root:, output_root:)
      @repository_root = Pathname.new(repository_root).expand_path
      @output_root = Pathname.new(output_root).expand_path
    end

    def generate(product)
      modules = PRODUCTS.fetch(product) do
        raise Error, "unknown CocoaPods product: #{product}"
      end
      FileUtils.mkdir_p(@output_root)
      staging = Pathname.new(
        Dir.mktmpdir(".#{product}.", @output_root.to_s)
      )
      entries = {}
      begin
        modules.each do |module_name|
          source_directory = @repository_root.join('Sources', module_name)
          source_files(source_directory).each do |source|
            relative = source.relative_path_from(@repository_root)
            destination = staging.join(module_name, source.basename)
            transformed = transform(source)
            write(destination, transformed)
            entries[relative.to_s] = {
              'sourceSHA256' => Digest::SHA256.hexdigest(source.binread),
              'generatedSHA256' => Digest::SHA256.hexdigest(transformed)
            }
          end
        end
        copy_runtime_support(staging, entries)
        manifest = {
          'schemaVersion' => 1,
          'product' => product,
          'modules' => modules,
          'files' => entries.sort.to_h
        }
        write(
          staging.join('CocoaPodsSourceManifest.json'),
          JSON.generate(manifest) + "\n"
        )
        replace(product, staging)
        staging = nil
        manifest
      ensure
        FileUtils.rm_rf(staging.to_s) if staging&.exist?
      end
    end

    private

    def source_files(directory)
      unless directory.directory? && !directory.symlink?
        raise Error, "runtime source directory is missing or symbolic: #{directory}"
      end
      files = directory.children.select { |path| path.extname == '.swift' }.sort
      if files.empty?
        raise Error, "runtime module has no Swift sources: #{directory.basename}"
      end
      files.each { |path| require_regular_file(path) }
      files
    end

    def transform(source)
      text = source.read(encoding: 'UTF-8')
      text.each_line.map do |line|
        match = INTERNAL_IMPORT.match(line.strip)
        if match
          line.end_with?("\r\n") ? "// CocoaPods aggregate includes #{match[1]}.\r\n" :
            "// CocoaPods aggregate includes #{match[1]}.\n"
        else
          line
        end
      end.join
    rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
      raise Error, "runtime Swift source is not valid UTF-8: #{source}"
    end

    def copy_runtime_support(staging, entries)
      support = @repository_root.join('Sources', 'HelixRuntimeSupport')
      sources = [
        support.join('RuntimeAtomic.c'),
        support.join('include', 'RuntimeAtomic.h')
      ]
      sources.each do |source|
        require_regular_file(source)
        relative = source.relative_path_from(@repository_root)
        bytes = source.binread
        write(staging.join('HelixRuntimeSupport', source.basename), bytes)
        digest = Digest::SHA256.hexdigest(bytes)
        entries[relative.to_s] = {
          'sourceSHA256' => digest,
          'generatedSHA256' => digest
        }
      end
    end

    def require_regular_file(path)
      stat = path.lstat
      raise Error, "runtime source is not a regular file: #{path}" unless stat.file?
    rescue Errno::ENOENT
      raise Error, "runtime source is missing: #{path}"
    end

    def write(path, contents)
      FileUtils.mkdir_p(path.dirname)
      path.binwrite(contents)
      File.chmod(0o644, path)
    end

    def replace(product, staging)
      destination = @output_root.join(product)
      expected = @output_root.join(product).cleanpath
      unless destination.cleanpath == expected && PRODUCTS.key?(destination.basename.to_s)
        raise Error, 'refusing to replace an unexpected generated-source path'
      end
      backup = @output_root.join(".#{product}.previous.#{Process.pid}")
      FileUtils.rm_rf(backup.to_s)
      FileUtils.mv(destination.to_s, backup.to_s) if destination.exist?
      begin
        FileUtils.mv(staging.to_s, destination.to_s)
        FileUtils.rm_rf(backup.to_s)
      rescue StandardError
        FileUtils.mv(backup.to_s, destination.to_s) if backup.exist? && !destination.exist?
        raise
      end
    end
  end
end

options = {
  output_root: File.expand_path('../Generated', __dir__)
}
parser = OptionParser.new do |value|
  value.banner = 'Usage: prepare_runtime_sources.rb PRODUCT [--output-root PATH]'
  value.on('--output-root PATH', 'Override the generated-source root for tests') do |path|
    options[:output_root] = path
  end
end
parser.parse!
product = ARGV.shift
abort(parser.to_s) unless product && ARGV.empty?

repository_root = File.expand_path('../..', __dir__)
begin
  manifest = HelixCocoaPods::Generator.new(
    repository_root: repository_root,
    output_root: options.fetch(:output_root)
  ).generate(product)
  warn "Prepared #{manifest.fetch('files').count} files for #{product}."
rescue HelixCocoaPods::Error => error
  warn "error: #{error.message}"
  exit 1
end
