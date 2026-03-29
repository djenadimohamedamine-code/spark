require 'xcodeproj'

project_path = 'Runner.xcodeproj'
begin
  project = Xcodeproj::Project.open(project_path)
  target = project.targets.find { |t| t.name == 'Runner' }

  target.build_configurations.each do |config|
    config.build_settings['ENABLE_BITCODE'] = 'NO'
    config.build_settings['SWIFT_TREAT_WARNINGS_AS_ERRORS'] = 'NO'
    config.build_settings['GCC_TREAT_WARNINGS_AS_ERRORS'] = 'NO'
    config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
  end

  project.save
  puts "✅ Xcode project configured for iOS 13.0+ and Bitcode NO."
rescue => e
  puts "❌ ERROR: Failed to configure Xcode project: #{e.message}"
  exit 1
end
