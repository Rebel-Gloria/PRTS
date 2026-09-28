#!/usr/bin/env python3
"""Deterministic, dependency-free project generation; no signing identity is embedded."""
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
project = ROOT / 'PRTSSpatialProbe.xcodeproj'
project.mkdir(exist_ok=True)
content = '''// !$*UTF8*$!
{
 archiveVersion = 1;
 classes = {};
 objectVersion = 77;
 objects = {
  A00000000000000000000001 = {isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2660; TargetAttributes = {A00000000000000000000002 = {CreatedOnToolsVersion = 26.6;};};}; buildConfigurationList = A00000000000000000000010; compatibilityVersion = "Xcode 16.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,"zh-Hans"); mainGroup = A00000000000000000000003; minimizedProjectReferenceProxies = 1; packageReferences = (A00000000000000000000030); preferredProjectObjectVersion = 77; productRefGroup = A00000000000000000000005; projectDirPath = ""; projectRoot = ""; targets = (A00000000000000000000002);};
  A00000000000000000000002 = {isa = PBXNativeTarget; buildConfigurationList = A00000000000000000000011; buildPhases = (A00000000000000000000007,A00000000000000000000008,A00000000000000000000009); buildRules = (); dependencies = (); fileSystemSynchronizedGroups = (A00000000000000000000004); name = PRTSSpatialProbe; packageProductDependencies = (A00000000000000000000031); productName = PRTSSpatialProbe; productReference = A00000000000000000000006; productType = "com.apple.product-type.application";};
  A00000000000000000000003 = {isa = PBXGroup; children = (A00000000000000000000004,A00000000000000000000005); sourceTree = "<group>";};
  A00000000000000000000004 = {isa = PBXFileSystemSynchronizedRootGroup; path = App; sourceTree = "<group>";};
  A00000000000000000000005 = {isa = PBXGroup; children = (A00000000000000000000006); name = Products; sourceTree = "<group>";};
  A00000000000000000000006 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = PRTSSpatialProbe.app; sourceTree = BUILT_PRODUCTS_DIR;};
  A00000000000000000000007 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;};
  A00000000000000000000008 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000032); runOnlyForDeploymentPostprocessing = 0;};
  A00000000000000000000009 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;};
  A00000000000000000000010 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000012,A00000000000000000000013); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;};
  A00000000000000000000011 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000014,A00000000000000000000015); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;};
  A00000000000000000000012 = {isa = XCBuildConfiguration; name = Debug; buildSettings = {ALWAYS_SEARCH_USER_PATHS = NO; CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; DEBUG_INFORMATION_FORMAT = dwarf; ENABLE_TESTABILITY = YES; GCC_OPTIMIZATION_LEVEL = 0; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 6.0; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)"; MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE; };};
  A00000000000000000000013 = {isa = XCBuildConfiguration; name = Release; buildSettings = {ALWAYS_SEARCH_USER_PATHS = NO; CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 6.0; SWIFT_OPTIMIZATION_LEVEL = "-O"; SWIFT_COMPILATION_MODE = wholemodule; MTL_ENABLE_DEBUG_INFO = NO; };};
  A00000000000000000000014 = {isa = XCBuildConfiguration; name = Debug; buildSettings = {__TARGET_SETTINGS__};};
  A00000000000000000000015 = {isa = XCBuildConfiguration; name = Release; buildSettings = {__TARGET_SETTINGS__};};
  A00000000000000000000030 = {isa = XCLocalSwiftPackageReference; relativePath = Core;};
  A00000000000000000000031 = {isa = XCSwiftPackageProductDependency; package = A00000000000000000000030; productName = SpatialCore;};
  A00000000000000000000032 = {isa = PBXBuildFile; productRef = A00000000000000000000031;};
 };
 rootObject = A00000000000000000000001;
}
'''
settings = '''CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 1; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_CFBundleDisplayName = "空间感知验证"; INFOPLIST_KEY_NSCameraUsageDescription = "使用相机和 ARKit 深度验证空间感知；仅在手动采样时保存现场图像，不自动上传。"; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_UISupportedInterfaceOrientations = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"; INFOPLIST_KEY_UIFileSharingEnabled = YES; INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; LD_RUNPATH_SEARCH_PATHS = ("$(inherited)","@executable_path/Frameworks"); MARKETING_VERSION = 0.1.0; PRODUCT_BUNDLE_IDENTIFIER = org.prts.SpatialProbe; PRODUCT_NAME = "$(TARGET_NAME)"; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; SUPPORTS_MACCATALYST = NO; SWIFT_EMIT_LOC_STRINGS = YES; SWIFT_VERSION = 6.0; TARGETED_DEVICE_FAMILY = 1; ENABLE_USER_SCRIPT_SANDBOXING = YES;'''
(project / 'project.pbxproj').write_text(content.replace('__TARGET_SETTINGS__', settings))
scheme = project / 'xcshareddata/xcschemes/PRTSSpatialProbe.xcscheme'
scheme.parent.mkdir(parents=True,exist_ok=True)
scheme.write_text('''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000002" BuildableName="PRTSSpatialProbe.app" BlueprintName="PRTSSpatialProbe" ReferencedContainer="container:PRTSSpatialProbe.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000002" BuildableName="PRTSSpatialProbe.app" BlueprintName="PRTSSpatialProbe" ReferencedContainer="container:PRTSSpatialProbe.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000002" BuildableName="PRTSSpatialProbe.app" BlueprintName="PRTSSpatialProbe" ReferencedContainer="container:PRTSSpatialProbe.xcodeproj"/></BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(project)
