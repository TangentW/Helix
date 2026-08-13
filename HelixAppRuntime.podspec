Pod::Spec.new do |spec|
  spec.name = 'HelixAppRuntime'
  spec.version = '1.0.0'
  spec.summary = 'Production HLBC hot-patch runtime for Helix-enabled iOS apps.'
  spec.description = <<-DESC
    The production-only Helix runtime verifies, installs, executes, rolls back,
    and crash-guards signed HLBC patches. It intentionally excludes every
    development transport and Live Reload UI component.
  DESC
  spec.homepage = 'https://github.com/TangentW/Helix'
  spec.license = { :type => 'Apache-2.0', :file => 'LICENSE' }
  spec.author = { 'TangentW' => 'TangentW' }
  spec.source = {
    :git => 'https://github.com/TangentW/Helix.git',
    :tag => "v#{spec.version}"
  }

  spec.ios.deployment_target = '15.0'
  spec.swift_versions = ['6.0']
  spec.cocoapods_version = '>= 1.12'
  spec.module_name = 'HelixAppRuntime'
  spec.static_framework = true
  spec.source_files = [
    'Sources/HelixCore/**/*.swift',
    'Sources/HelixBytecode/**/*.swift',
    'Sources/HelixInterface/**/*.swift',
    'Sources/HelixVerifier/**/*.swift',
    'Sources/HelixVM/**/*.swift',
    'Sources/HelixRuntime/**/*.swift',
    'Sources/HelixPatch/**/*.swift',
    'Sources/HelixRuntimeSupport/RuntimeAtomic.c',
    'Sources/HelixRuntimeSupport/include/RuntimeAtomic.h'
  ]
  spec.public_header_files = 'Sources/HelixRuntimeSupport/include/*.h'
  spec.header_mappings_dir = 'Sources/HelixRuntimeSupport/include'
  spec.frameworks = 'Foundation', 'CryptoKit'
  spec.pod_target_xcconfig = {
    'OTHER_SWIFT_FLAGS' => '$(inherited) -package-name Helix',
    'SWIFT_STRICT_CONCURRENCY' => 'complete',
    'SWIFT_TREAT_WARNINGS_AS_ERRORS' => 'YES'
  }

  spec.test_spec 'ConsumerTests' do |tests|
    tests.source_files = 'CocoaPods/Tests/HelixAppRuntimeConsumerTests.swift'
    tests.requires_app_host = false
  end
end
