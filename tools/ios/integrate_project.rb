# Idempotent project integration; requires xcodeproj 1.25+.
require 'xcodeproj'
root = File.expand_path('../..', __dir__)
project = Xcodeproj::Project.open(File.join(root, 'app/ios/Runner.xcodeproj'))
runner = project.targets.find { |t| t.name == 'Runner' }
extension = project.targets.find { |t| t.name == 'FipsPacketTunnel' } || project.new_target(:app_extension, 'FipsPacketTunnel', :ios, '13.0')
group = project.main_group.find_subpath('FipsPacketTunnel', true)
group.set_source_tree('<group>'); group.path = 'FipsPacketTunnel'
['FipsPacketLifecycle.swift', 'PacketTunnelProvider.swift', 'FipsTunnelSettings.swift', 'FipsCore.h', 'Info.plist', 'FipsPacketTunnel.entitlements'].each do |name|
  ref = group.files.find { |f| f.path == name } || group.new_file(name)
  extension.add_file_references([ref]) if name.end_with?('.swift') && !extension.source_build_phase.files_references.include?(ref)
end
rg = project.main_group.find_subpath('Runner', false)
ref = rg.files.find { |f| f.path == 'FipsRuntimeController.swift' } || rg.new_file('FipsRuntimeController.swift')
runner.add_file_references([ref]) unless runner.source_build_phase.files_references.include?(ref)
runner.add_dependency(extension) unless runner.dependencies.any? { |d| d.target == extension }
phase = runner.copy_files_build_phases.find { |p| p.name == 'Embed App Extensions' } || runner.new_copy_files_build_phase('Embed App Extensions')
phase.dst_subfolder_spec = '13'
phase.add_file_reference(extension.product_reference, true) unless phase.files_references.include?(extension.product_reference)
# Embed before Flutter's Thin Binary phase to avoid dependency cycles.
runner.build_phases.delete(phase); runner.build_phases.insert(0, phase)
core = project.main_group.files.find { |f| f.path == 'FipsCore/WmFips.xcframework' } || project.main_group.new_file('FipsCore/WmFips.xcframework')
extension.frameworks_build_phase.add_file_reference(core, true) unless extension.frameworks_build_phase.files_references.include?(core)
# SDK-relative references work for both device and simulator SDKs.
project.files.select { |f| f.name == 'Foundation.framework' }.each do |f|
  f.path = 'System/Library/Frameworks/Foundation.framework'; f.source_tree = 'SDKROOT'
end
project.files.select { |f| f.path.to_s.end_with?('.framework.framework', 'libresolv.tbd.framework') }.each(&:remove_from_project)
['NetworkExtension', 'Security', 'SystemConfiguration'].each do |name|
  path = "System/Library/Frameworks/#{name}.framework"
  ref = project.files.find { |f| f.path == path } || project.frameworks_group.new_file(path, :sdk_root)
  extension.frameworks_build_phase.add_file_reference(ref, true) unless extension.frameworks_build_phase.files_references.include?(ref)
  runner.frameworks_build_phase.add_file_reference(ref, true) if name == 'NetworkExtension' && !runner.frameworks_build_phase.files_references.include?(ref)
end
extension.build_configurations.each do |c|
  parent = runner.build_configurations.find { |p| p.name == c.name } || runner.build_configurations.first
  c.base_configuration_reference = project.main_group.find_subpath('Flutter', false).files.find { |f| f.path.end_with?('Generated.xcconfig') }
  c.build_settings.merge!({
    'PRODUCT_NAME' => 'FipsPacketTunnel', 'SUPPORTED_PLATFORMS' => 'iphoneos iphonesimulator',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.wingmanbefree.wingmanApp.FipsPacketTunnel',
    'DEVELOPMENT_TEAM' => parent.build_settings['DEVELOPMENT_TEAM'],
    'CODE_SIGN_STYLE' => 'Automatic', 'CODE_SIGN_ENTITLEMENTS' => 'FipsPacketTunnel/FipsPacketTunnel.entitlements',
    'INFOPLIST_FILE' => 'FipsPacketTunnel/Info.plist', 'GENERATE_INFOPLIST_FILE' => 'NO',
    'SWIFT_VERSION' => '5.0', 'SWIFT_OBJC_BRIDGING_HEADER' => 'FipsPacketTunnel/FipsCore.h',
    'APPLICATION_EXTENSION_API_ONLY' => 'YES', 'SKIP_INSTALL' => 'YES',
    'IPHONEOS_DEPLOYMENT_TARGET' => '13.0', 'TARGETED_DEVICE_FAMILY' => '1,2',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)','@executable_path/Frameworks','@executable_path/../../Frameworks'],
    'OTHER_LDFLAGS' => ['$(inherited)', '-lc++', '-lresolv'],
  })
end
runner.build_configurations.each { |c| c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements' }
project.save
