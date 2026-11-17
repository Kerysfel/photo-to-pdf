from pathlib import Path
import hashlib

root = Path(__file__).resolve().parent
sources = sorted((root / 'PhotoToPDF').glob('*.swift'))
def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

objects = []
def obj(name, value):
    objects.append(f'{ident(name)} = {{ {value} }};')
def refs(names):
    return '(' + ', '.join(ident(n) for n in names) + ',)'

for source in sources:
    obj('file:' + source.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {source.name}; sourceTree = "<group>";')
    obj('build:' + source.name, f'isa = PBXBuildFile; fileRef = {ident("file:" + source.name)};')
obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = PhotoToPDF.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(["build:" + s.name for s in sources])}; runOnlyForDeploymentPostprocessing = 0;')
obj('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
obj('resources', 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
obj('sourceGroup', f'isa = PBXGroup; children = {refs(["file:" + s.name for s in sources])}; path = PhotoToPDF; sourceTree = "<group>";')
obj('productsGroup', f'isa = PBXGroup; children = {refs(["product"])}; name = Products; sourceTree = "<group>";')
obj('mainGroup', f'isa = PBXGroup; children = {refs(["sourceGroup", "productsGroup"])}; sourceTree = "<group>";')
obj('target', f'isa = PBXNativeTarget; buildConfigurationList = {ident("targetConfigs")}; buildPhases = {refs(["sources", "frameworks", "resources"])}; buildRules = (); dependencies = (); name = PhotoToPDF; productName = PhotoToPDF; productReference = {ident("product")}; productType = "com.apple.product-type.application";')
obj('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; TargetAttributes = {{ {ident("target")} = {{ CreatedOnToolsVersion = 16.0; ProvisioningStyle = Automatic; }}; }}; }}; buildConfigurationList = {ident("projectConfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = ru; hasScannedForEncodings = 0; knownRegions = (ru, en, Base); mainGroup = {ident("mainGroup")}; productRefGroup = {ident("productsGroup")}; projectDirPath = ""; projectRoot = ""; targets = {refs(["target"])};')
for config in ['Debug', 'Release']:
    project_settings = 'CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 16.0;'
    if config == 'Debug':
        project_settings += ' DEBUG_INFORMATION_FORMAT = dwarf; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;'
    else:
        project_settings += ' DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"; SWIFT_OPTIMIZATION_LEVEL = "-O"; SWIFT_COMPILATION_MODE = wholemodule;'
    target_settings = '''CODE_SIGN_STYLE = Automatic;
CURRENT_PROJECT_VERSION = 6;
MARKETING_VERSION = 1.4;
GENERATE_INFOPLIST_FILE = YES;
INFOPLIST_KEY_CFBundleDisplayName = "Фото в PDF";
INFOPLIST_KEY_NSCameraUsageDescription = "Камера нужна для съёмки страниц и сканирования QR-кода компьютера.";
INFOPLIST_KEY_NSLocalNetworkUsageDescription = "Локальная сеть нужна для защищённой отправки PDF на ваш компьютер.";
INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
INFOPLIST_KEY_UILaunchScreen_Generation = YES;
INFOPLIST_KEY_UIFileSharingEnabled = YES;
INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace = YES;
INFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait;
PRODUCT_BUNDLE_IDENTIFIER = com.kerysfel.PhotoToPDF;
PRODUCT_NAME = "$(TARGET_NAME)";
SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
SUPPORTS_MACCATALYST = NO;
SWIFT_VERSION = 5.0;
TARGETED_DEVICE_FAMILY = 1;
LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks");'''
    obj('project' + config, f'isa = XCBuildConfiguration; buildSettings = {{ {project_settings} }}; name = {config};')
    obj('target' + config, f'isa = XCBuildConfiguration; buildSettings = {{ {target_settings} }}; name = {config};')
for scope in ['project', 'target']:
    obj(scope + 'Configs', f'isa = XCConfigurationList; buildConfigurations = {refs([scope + "Debug", scope + "Release"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
project = root / 'PhotoToPDF.xcodeproj'
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {ident("project")}; }}\n')
scheme_dir = project / 'xcshareddata' / 'xcschemes'
scheme_dir.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target")}" BuildableName="PhotoToPDF.app" BlueprintName="PhotoToPDF" ReferencedContainer="container:PhotoToPDF.xcodeproj"/>'
(scheme_dir / 'PhotoToPDF.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print('Generated Xcode project and shared scheme with', len(sources), 'Swift files')
