#!/usr/bin/env python3
"""
Generate a minimal Xcode project (project.pbxproj) for TmpspaceApp.

This creates a macOS app target that uses a Run Script build phase to call
swift build, so the SPM Package.swift remains the sole source of truth.
Xcode handles signing, provisioning profile management, and archiving.
"""

import os, uuid, hashlib, sys
from pathlib import Path

PROJECT_DIR = Path("/Users/admin/Desktop/tmpspace/TmpspaceApp")
PROJECT_NAME = "TmpspaceApp"
TARGET_NAME = "Tmpspace"
BUNDLE_ID = "com.tmpspace.app"
TEAM_ID = "S8FBPXF9AA"
SDKROOT = "macosx"

# ── UUID helpers ──────────────────────────────────────────────
def make_id(prefix: str = "") -> str:
    """Generate a 24-hex-char Xcode-style UUID."""
    return (prefix + uuid.uuid4().hex)[:24].upper()

# Generate all IDs deterministically (based on the key so edits don't reshuffle)
def stable_id(key: str) -> str:
    h = hashlib.sha256(key.encode()).hexdigest().upper()[:24]
    return h

# ── File references ───────────────────────────────────────────
# We include a minimal stub main.swift so Xcode has something to compile.
# The real app is built by SPM in a Run Script phase and replaces the output.

STUB_MAIN = """import AppKit

// When built by SPM (swift build), TmpspaceSettings is available as a linked
// module. When built by Xcode (which only compiles the stub for code signing),
// the module is absent — fall back to plain NSApplicationMain.
#if canImport(TmpspaceSettings)
import TmpspaceSettings

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
#else
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
#endif
"""

# ── IDs ────────────────────────────────────────────────────────
pid  = stable_id("project")
mgrp = stable_id("main-group")
sgrp = stable_id("sources-group")
rgrp = stable_id("resources-group")
pgrp = stable_id("products-group")
tgt  = stable_id("target")
pbl  = stable_id("project-build-list")
pbc0 = stable_id("project-build-config-debug")
pbc1 = stable_id("project-build-config-release")
tbl  = stable_id("target-build-list")
tbc0 = stable_id("target-build-config-debug")
tbc1 = stable_id("target-build-config-release")
sph  = stable_id("sources-build-phase")
fph  = stable_id("frameworks-build-phase")
rph  = stable_id("resources-build-phase")
shph = stable_id("shell-build-phase")
infr = stable_id("info-plist-ref")
entr = stable_id("entitlements-ref")
stubr = stable_id("main-stub-ref")
stubb = stable_id("main-stub-build")
prodref = stable_id("product-ref")

# ── Write stub main.swift ─────────────────────────────────────
sources_dir = PROJECT_DIR / "Sources"
sources_dir.mkdir(parents=True, exist_ok=True)
stub_path = sources_dir / "main.swift"
stub_path.write_text(STUB_MAIN)

# ── PBXBuildFile ──────────────────────────────────────────────
def pbx_build_file(file_ref_id: str) -> str:
    fid = stable_id(f"build-file-{file_ref_id}")
    return f'\t\t{fid} /* {file_ref_id} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id}; }};'

# ── PBXFileReference ──────────────────────────────────────────
def pbx_file_ref(fid: str, name: str, path: str, ftype: str, explicit_type: str = None, src_tree: str = None) -> str:
    base = f'\t\t{fid} /* {name} */ = {{isa = PBXFileReference; '
    if explicit_type:
        base += f'explicitFileType = {explicit_type}; '
        base += f'includeInIndex = 0; '
    else:
        base += f'lastKnownFileType = {ftype}; '
    tree = src_tree if src_tree else '"<group>"'
    base += f'path = "{path}"; sourceTree = {tree}; }};'
    return base

# ── Generate pbxproj ──────────────────────────────────────────
def generate_pbxproj() -> str:
    lines = []
    lines.append("// !$*UTF8*$!")
    lines.append("{")

    # archiveVersion
    lines.append('\tarchiveVersion = 1;')
    # classes
    lines.append('\tclasses = {};')

    # objectVersion = 56 (Xcode 14+)
    lines.append('\tobjectVersion = 56;')

    # objects
    lines.append('\tobjects = {')

    # ── PBXBuildFile section ──
    lines.append('\n/* Begin PBXBuildFile section */')
    lines.append(pbx_build_file(stubr))
    lines.append('/* End PBXBuildFile section */')

    # ── PBXFileReference section ──
    lines.append('\n/* Begin PBXFileReference section */')
    lines.append(pbx_file_ref(stubr, "main.swift", "main.swift", "sourcecode.swift"))
    lines.append(pbx_file_ref(infr, "Info.plist", "Info.plist", "text.plist.xml"))
    lines.append(pbx_file_ref(entr, "TmpspaceApp.entitlements", "TmpspaceApp.entitlements", "text.plist.entitlements"))
    lines.append(pbx_file_ref(prodref, f"{TARGET_NAME}.app", f"{TARGET_NAME}.app", 'wrapper.application', 'wrapper.application', 'BUILT_PRODUCTS_DIR'))
    lines.append('/* End PBXFileReference section */')

    # ── PBXGroup section ──
    lines.append('\n/* Begin PBXGroup section */')
    # Main group
    lines.append(f'\t\t{mgrp} = {{')
    lines.append(f'\t\t\tisa = PBXGroup;')
    lines.append(f'\t\t\tchildren = (')
    lines.append(f'\t\t\t\t{sgrp} /* Sources */,')
    lines.append(f'\t\t\t\t{infr} /* Info.plist */,')
    lines.append(f'\t\t\t\t{entr} /* Entitlements */,')
    lines.append(f'\t\t\t\t{pgrp} /* Products */,')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t\tsourceTree = "<group>";')
    lines.append(f'\t\t}};')
    # Sources group
    lines.append(f'\t\t{sgrp} = {{')
    lines.append(f'\t\t\tisa = PBXGroup;')
    lines.append(f'\t\t\tchildren = (')
    lines.append(f'\t\t\t\t{stubr} /* main.swift */,')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t\tpath = Sources;')
    lines.append(f'\t\t\tsourceTree = "<group>";')
    lines.append(f'\t\t}};')
    # Products group
    lines.append(f'\t\t{pgrp} = {{')
    lines.append(f'\t\t\tisa = PBXGroup;')
    lines.append(f'\t\t\tchildren = (')
    lines.append(f'\t\t\t\t{prodref} /* {TARGET_NAME}.app */,')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t\tname = Products;')
    lines.append(f'\t\t\tsourceTree = "<group>";')
    lines.append(f'\t\t}};')
    lines.append('/* End PBXGroup section */')

    # ── PBXNativeTarget section ──
    lines.append('\n/* Begin PBXNativeTarget section */')
    lines.append(f'\t\t{tgt} /* {TARGET_NAME} */ = {{')
    lines.append(f'\t\t\tisa = PBXNativeTarget;')
    lines.append(f'\t\t\tbuildConfigurationList = {tbl} /* Build configuration list for PBXNativeTarget "{TARGET_NAME}" */;')
    lines.append(f'\t\t\tbuildPhases = (')
    lines.append(f'\t\t\t\t{sph} /* Sources */,')
    lines.append(f'\t\t\t\t{fph} /* Frameworks */,')
    lines.append(f'\t\t\t\t{shph} /* Run Script (SPM Build) */,')
    lines.append(f'\t\t\t\t{rph} /* Copy Resources */,')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t\tbuildRules = (')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t\tdependencies = (')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t\tname = {TARGET_NAME};')
    lines.append(f'\t\t\tproductName = {TARGET_NAME};')
    lines.append(f'\t\t\tproductReference = {prodref} /* {TARGET_NAME}.app */;')
    lines.append(f'\t\t\tproductType = "com.apple.product-type.application";')
    lines.append(f'\t\t}};')
    lines.append('/* End PBXNativeTarget section */')

    # ── PBXProject section ──
    lines.append('\n/* Begin PBXProject section */')
    lines.append(f'\t\t{pid} /* Project object */ = {{')
    lines.append(f'\t\t\tisa = PBXProject;')
    lines.append(f'\t\t\tattributes = {{')
    lines.append(f'\t\t\t\tBuildIndependentTargetsInParallel = 1;')
    lines.append(f'\t\t\t\tLastSwiftUpdateCheck = 1620;')
    lines.append(f'\t\t\t\tLastUpgradeCheck = 1620;')
    lines.append(f'\t\t\t}};')
    lines.append(f'\t\t\tbuildConfigurationList = {pbl} /* Build configuration list for PBXProject "{PROJECT_NAME}" */;')
    lines.append(f'\t\t\tcompatibilityVersion = "Xcode 14.0";')
    lines.append(f'\t\t\tdevelopmentRegion = "zh-Hans";')
    lines.append(f'\t\t\thasScannedForEncodings = 0;')
    lines.append(f'\t\t\tknownRegions = (')
    lines.append(f'\t\t\t\ten,')
    lines.append(f'\t\t\t\t"zh-Hans",')
    lines.append(f'\t\t\t\tBase,')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t\tmainGroup = {mgrp};')
    lines.append(f'\t\t\tproductRefGroup = {pgrp} /* Products */;')
    lines.append(f'\t\t\tprojectDirPath = "";')
    lines.append(f'\t\t\tprojectRoot = "";')
    lines.append(f'\t\t\ttargets = (')
    lines.append(f'\t\t\t\t{tgt} /* {TARGET_NAME} */,')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t}};')
    lines.append('/* End PBXProject section */')

    # ── PBXShellScriptBuildPhase section ──
    lines.append('\n/* Begin PBXShellScriptBuildPhase section */')
    lines.append(f'\t\t{shph} /* Run Script (SPM Build) */ = {{')
    lines.append(f'\t\t\tisa = PBXShellScriptBuildPhase;')
    lines.append(f'\t\t\tbuildActionMask = 2147483647;')
    lines.append(f'\t\t\tfiles = (')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t\tinputPaths = (')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t\tname = "SPM Build";')
    lines.append(f'\t\t\toutputPaths = (')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    lines.append(f'\t\t\tshellPath = /bin/bash;')
    shell_script = (
        'set -e\\n'
        'cd $SRCROOT\\n'
        'echo Building SPM...\\n'
        'swift build -c release\\n'
        'echo Copying binary and resources...\\n'
        'APP=$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME\\n'
        'mkdir -p $APP/Contents/MacOS $APP/Contents/Resources/icon $APP/Contents/Resources/dist/chunks\\n'
        'cp .build/arm64-apple-macosx/release/Tmpspace $APP/Contents/MacOS/Tmpspace\\n'
        'cp -R Resources/icon/ $APP/Contents/Resources/icon/\\n'
        'cp Resources/AppIcon.icns $APP/Contents/Resources/\\n'
        'DIST_SRC=/Users/admin/Desktop/tmpspace/MarkEdit-main/CoreEditor/dist\\n'
        'cp $DIST_SRC/index.html $APP/Contents/Resources/dist/\\n'
        'cp $DIST_SRC/chunks/* $APP/Contents/Resources/dist/chunks/\\n'
        'echo Done'
    )
    lines.append(f'\t\t\tshellScript = "{shell_script}";')
    lines.append(f'\t\t}};')
    lines.append('/* End PBXShellScriptBuildPhase section */')

    # ── PBXSourcesBuildPhase section ──
    lines.append('\n/* Begin PBXSourcesBuildPhase section */')
    lines.append(f'\t\t{sph} /* Sources */ = {{')
    lines.append(f'\t\t\tisa = PBXSourcesBuildPhase;')
    lines.append(f'\t\t\tbuildActionMask = 2147483647;')
    lines.append(f'\t\t\tfiles = (')
    lines.append(f'\t\t\t\t{stubb} /* main.swift in Sources */,')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    lines.append(f'\t\t}};')
    lines.append('/* End PBXSourcesBuildPhase section */')

    # ── PBXFrameworksBuildPhase section ──
    lines.append('\n/* Begin PBXFrameworksBuildPhase section */')
    lines.append(f'\t\t{fph} /* Frameworks */ = {{')
    lines.append(f'\t\t\tisa = PBXFrameworksBuildPhase;')
    lines.append(f'\t\t\tbuildActionMask = 2147483647;')
    lines.append(f'\t\t\tfiles = (')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    lines.append(f'\t\t}};')
    lines.append('/* End PBXFrameworksBuildPhase section */')

    # ── PBXResourcesBuildPhase section ──
    lines.append('\n/* Begin PBXResourcesBuildPhase section */')
    lines.append(f'\t\t{rph} /* Copy Resources */ = {{')
    lines.append(f'\t\t\tisa = PBXResourcesBuildPhase;')
    lines.append(f'\t\t\tbuildActionMask = 2147483647;')
    lines.append(f'\t\t\tfiles = (')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    lines.append(f'\t\t}};')
    lines.append('/* End PBXResourcesBuildPhase section */')

    # ── XCBuildConfiguration section ──
    lines.append('\n/* Begin XCBuildConfiguration section */')

    # Common build settings
    base_settings = [
        ('ASSETCATALOG_COMPILER_APPICON_NAME', 'AppIcon'),
        ('CODE_SIGN_ENTITLEMENTS', 'TmpspaceApp.entitlements'),
        ('CODE_SIGN_STYLE', 'Automatic'),
        ('COMBINE_HIDPI_IMAGES', 'YES'),
        ('DEVELOPMENT_TEAM', TEAM_ID),
        ('ENABLE_HARDENED_RUNTIME', 'YES'),
        ('GENERATE_INFOPLIST_FILE', 'NO'),
        ('INFOPLIST_FILE', 'Info.plist'),
        ('MACOSX_DEPLOYMENT_TARGET', '15.0'),
        ('PRODUCT_BUNDLE_IDENTIFIER', BUNDLE_ID),
        ('PRODUCT_NAME', TARGET_NAME),
        ('SDKROOT', SDKROOT),
        ('SWIFT_VERSION', '6.0'),
    ]

    def build_config(cid: str, name: str, level: str, extra: list = None) -> str:
        settings = list(base_settings)
        if extra:
            settings.extend(extra)
        lines = []
        lines.append(f'\t\t{cid} /* {name} */ = {{')
        lines.append(f'\t\t\tisa = XCBuildConfiguration;')
        lines.append(f'\t\t\tbuildSettings = {{')
        for k, v in settings:
            lines.append(f'\t\t\t\t{k} = "{v}";')
        lines.append(f'\t\t\t}};')
        lines.append(f'\t\t\tname = {name};')
        lines.append(f'\t\t}};')
        return '\n'.join(lines)

    lines.append(build_config(pbc0, 'Debug', 'project', [
        ('SWIFT_ACTIVE_COMPILATION_CONDITIONS', 'DEBUG'),
    ]))
    lines.append(build_config(pbc1, 'Release', 'project'))
    lines.append(build_config(tbc0, 'Debug', 'target', [
        ('SWIFT_ACTIVE_COMPILATION_CONDITIONS', 'DEBUG'),
    ]))
    lines.append(build_config(tbc1, 'Release', 'target'))

    lines.append('/* End XCBuildConfiguration section */')

    # ── XCConfigurationList section ──
    lines.append('\n/* Begin XCConfigurationList section */')
    lines.append(f'\t\t{pbl} /* Build configuration list for PBXProject "{PROJECT_NAME}" */ = {{')
    lines.append(f'\t\t\tisa = XCConfigurationList;')
    lines.append(f'\t\t\tbuildConfigurations = (')
    lines.append(f'\t\t\t\t{pbc0} /* Debug */,')
    lines.append(f'\t\t\t\t{pbc1} /* Release */,')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t\tdefaultConfigurationIsVisible = 0;')
    lines.append(f'\t\t\tdefaultConfigurationName = Release;')
    lines.append(f'\t\t}};')

    lines.append(f'\t\t{tbl} /* Build configuration list for PBXNativeTarget "{TARGET_NAME}" */ = {{')
    lines.append(f'\t\t\tisa = XCConfigurationList;')
    lines.append(f'\t\t\tbuildConfigurations = (')
    lines.append(f'\t\t\t\t{tbc0} /* Debug */,')
    lines.append(f'\t\t\t\t{tbc1} /* Release */,')
    lines.append(f'\t\t\t);')
    lines.append(f'\t\t\tdefaultConfigurationIsVisible = 0;')
    lines.append(f'\t\t\tdefaultConfigurationName = Release;')
    lines.append(f'\t\t}};')
    lines.append('/* End XCConfigurationList section */')

    # ── rootObject ──
    lines.append(f'\t}};')
    lines.append(f'\trootObject = {pid} /* Project object */;')
    lines.append(f'}}')

    return '\n'.join(lines)


# ── Write pbxproj ─────────────────────────────────────────────
xcodeproj_dir = PROJECT_DIR / f"{PROJECT_NAME}.xcodeproj"
xcodeproj_dir.mkdir(parents=True, exist_ok=True)

pbxproj_content = generate_pbxproj()
(xcodeproj_dir / "project.pbxproj").write_text(pbxproj_content)

print(f"✅ Xcode project created at: {xcodeproj_dir}")
print(f"   Bundle ID: {BUNDLE_ID}")
print(f"   Team: {TEAM_ID}")
print(f"   Signing: Automatic (Apple Distribution)")
print(f"")
print(f"Next: open {xcodeproj_dir} in Xcode → it will auto-fetch provisioning profiles")
