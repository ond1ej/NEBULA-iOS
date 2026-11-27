#!/usr/bin/env python3
"""Generate NEBULA.xcodeproj (Xcode 16+ format with synchronized folders) and its shared schemes.

Synchronized root groups mean every file added to iOS/, macOS/, UITests-*/ is part of the target automatically; the
shared code lives in the local Swift package NEBULAKit. Deterministic object ids keep diffs stable.

Signing and bundle ids are NOT baked into the project. Every target reads Config/Signing.xcconfig (committed defaults:
no team, bundle-id prefix com.example), which optionally includes Config/Local.xcconfig (yours, git-ignored; template:
Config/Local.xcconfig.example) with DEVELOPMENT_TEAM and NEBULA_BUNDLE_ID_PREFIX. So the committed project is the same
for everybody and regenerating it can never leak a Team ID. This script only reads Local.xcconfig to tell you what
Xcode will use.

Run from the repository root: python3 scripts/gen_xcodeproj.py
"""
from __future__ import annotations

import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]  # the repository root (this file is scripts/gen_xcodeproj.py)
PROJ = ROOT / "NEBULA.xcodeproj"
VERSION = "1.0.0"
BUILD = "1"


def read_xcconfig(path: Path) -> dict[str, str]:
    """`KEY = value` pairs of an .xcconfig (comments and conditional keys are ignored); {} if the file is absent."""
    out: dict[str, str] = {}
    if path.exists():
        for line in path.read_text().splitlines():
            m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*(//.*)?$", line)
            if m:
                out[m.group(1)] = m.group(2)
    return out


def oid(*parts: str) -> str:
    return hashlib.sha256("/".join(parts).encode()).hexdigest()[:24].upper()  # stable ids, not security


def q(v) -> str:
    s = str(v)
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s  # already a quoted literal
    if len(s) > 24 and all(c in "0123456789ABCDEF" for c in s[:24]) and s[24:].startswith(" /*"):
        return s  # an object reference with its comment
    if s and all(c.isalnum() or c in "._/$" for c in s) and not s[0].isdigit():
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def dict_block(d: dict, indent: int) -> str:
    pad = "\t" * indent
    out = ["{"]
    for k, v in d.items():
        if isinstance(v, dict):
            out.append(f"{pad}\t{q(k)} = {dict_block(v, indent + 1)};")
        elif isinstance(v, list):
            items = "".join(f"\n{pad}\t\t{x}," for x in v)
            out.append(f"{pad}\t{q(k)} = ({items}\n{pad}\t);")
        else:
            out.append(f"{pad}\t{q(k)} = {v if isinstance(v, str) and v.startswith(('{', '(')) else q(v)};")
    out.append(f"{pad}}}")
    return "\n".join(out)


COMMON = {
    "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
    "COPY_PHASE_STRIP": "NO", "ENABLE_STRICT_OBJC_MSGSEND": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17", "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "SWIFT_VERSION": "6.0", "MARKETING_VERSION": VERSION,
    "CURRENT_PROJECT_VERSION": BUILD, "SWIFT_EMIT_LOC_STRINGS": "YES", "DEAD_CODE_STRIPPING": "YES",
}
DEBUG = {**COMMON, "DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES", "GCC_OPTIMIZATION_LEVEL": "0",
         "ONLY_ACTIVE_ARCH": "YES", "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
         "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)", "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE"}
RELEASE = {**COMMON, "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "SWIFT_COMPILATION_MODE": "wholemodule",
           "SWIFT_OPTIMIZATION_LEVEL": "-O", "VALIDATE_PRODUCT": "YES", "MTL_ENABLE_DEBUG_INFO": "NO"}

# English base values; the Czech translations live in Localization/InfoPlist.xcstrings
USAGE = {
    "INFOPLIST_KEY_NSFaceIDUsageDescription": "NEBULA uses Face ID to confirm it is you and to unlock the vault.",
    "INFOPLIST_KEY_NSMicrophoneUsageDescription": "The microphone is used only to record voice messages for your agents.",
    "INFOPLIST_KEY_NSCameraUsageDescription": "The camera is used only to scan the pairing QR code from your Mac.",
}
COPYRIGHT = "NEBULA – your own installation"

# Signing settings come from Config/Signing.xcconfig (+ Config/Local.xcconfig), never from the project itself.
IOS_ENTITLEMENTS = "$(NEBULA_IOS_ENTITLEMENTS)"
MAC_ENTITLEMENTS = "$(NEBULA_MAC_ENTITLEMENTS)"

TARGETS = [
    {"name": "NEBULA", "folder": "iOS", "type": "com.apple.product-type.application", "product": "NEBULA.app",
     "exclude": ["Info.plist", "Info-Debug.plist", "NEBULA-push.entitlements"], "package": True, "resources": True, "settings": {
        "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "18.0", "TARGETED_DEVICE_FAMILY": "1,2",
        "PRODUCT_NAME": "NEBULA", "PRODUCT_BUNDLE_IDENTIFIER": "$(NEBULA_BUNDLE_ID_PREFIX).nebula",
        "CODE_SIGN_ENTITLEMENTS": IOS_ENTITLEMENTS, "GENERATE_INFOPLIST_FILE": "YES", "INFOPLIST_FILE": "iOS/Info.plist",
        "INFOPLIST_KEY_CFBundleDisplayName": "NEBULA", "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
        "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone":
            "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": "UIInterfaceOrientationPortrait "
            "UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
        "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.productivity",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "ENABLE_PREVIEWS": "YES", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
        "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO", **USAGE}},
    {"name": "NEBULA Mac", "folder": "macOS", "type": "com.apple.product-type.application", "product": "NEBULA.app",
     "exclude": ["Info.plist", "Info-Debug.plist", "NEBULA.entitlements", "NEBULA-provisioned.entitlements"],
     "package": True, "resources": True, "settings": {
        "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "15.0", "PRODUCT_NAME": "NEBULA",
        "PRODUCT_BUNDLE_IDENTIFIER": "$(NEBULA_BUNDLE_ID_PREFIX).nebula.mac",
        "CODE_SIGN_ENTITLEMENTS": MAC_ENTITLEMENTS, "ENABLE_HARDENED_RUNTIME": "YES",
        "GENERATE_INFOPLIST_FILE": "YES", "INFOPLIST_FILE": "macOS/Info.plist",
        "INFOPLIST_KEY_CFBundleDisplayName": "NEBULA", "INFOPLIST_KEY_LSApplicationCategoryType":
            "public.app-category.productivity", "INFOPLIST_KEY_NSHumanReadableCopyright": COPYRIGHT,
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "ENABLE_PREVIEWS": "YES", "COMBINE_HIDPI_IMAGES": "YES",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
        "INFOPLIST_KEY_NSMicrophoneUsageDescription": USAGE["INFOPLIST_KEY_NSMicrophoneUsageDescription"]}},
    {"name": "NEBULAUITests", "folder": "UITests-iOS", "type": "com.apple.product-type.bundle.ui-testing",
     "product": "NEBULAUITests.xctest", "test_of": "NEBULA", "settings": {
        "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "18.0", "TARGETED_DEVICE_FAMILY": "1,2",
        "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "$(NEBULA_BUNDLE_ID_PREFIX).nebula.uitests",
        "GENERATE_INFOPLIST_FILE": "YES", "TEST_TARGET_NAME": "NEBULA"}},
    {"name": "NEBULAMacUITests", "folder": "UITests-macOS", "type": "com.apple.product-type.bundle.ui-testing",
     "product": "NEBULAMacUITests.xctest", "test_of": "NEBULA Mac", "settings": {
        "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "15.0", "PRODUCT_NAME": "$(TARGET_NAME)",
        "PRODUCT_BUNDLE_IDENTIFIER": "$(NEBULA_BUNDLE_ID_PREFIX).nebula.mac.uitests",
        "GENERATE_INFOPLIST_FILE": "YES", "TEST_TARGET_NAME": "NEBULA Mac"}},
]


def generate() -> None:
    project = oid("project")
    main_group = oid("group", "main")
    products_group = oid("group", "products")
    package_ref = oid("package", "NEBULAKit")
    proj_cfgs = {c: oid("projcfg", c) for c in ("Debug", "Release")}
    proj_cfglist = oid("projcfglist")
    objs: dict[str, dict[str, str]] = {}

    def add(section: str, key: str, comment: str, body: str) -> None:
        objs.setdefault(section, {})[f"{key} /* {comment} */"] = body

    # Config/ (the xcconfig every configuration is based on) and Localization/ (string catalogs shared by both apps)
    config_group, loc_group = oid("group", "config"), oid("group", "localization")
    signing_ref = oid("file", "Signing.xcconfig")
    add("PBXFileReference", signing_ref, "Signing.xcconfig", dict_block({
        "isa": "PBXFileReference", "lastKnownFileType": "text.xcconfig", "path": "Signing.xcconfig",
        "sourceTree": '"<group>"'}, 2))
    add("PBXGroup", config_group, "Config", dict_block({
        "isa": "PBXGroup", "children": [f"{signing_ref} /* Signing.xcconfig */"], "path": "Config",
        "sourceTree": '"<group>"'}, 2))
    catalogs = {}
    for name in ("Localizable.xcstrings", "InfoPlist.xcstrings"):
        catalogs[name] = oid("file", name)
        add("PBXFileReference", catalogs[name], name, dict_block({
            "isa": "PBXFileReference", "lastKnownFileType": "text.json.xcstrings", "path": name,
            "sourceTree": '"<group>"'}, 2))
    add("PBXGroup", loc_group, "Localization", dict_block({
        "isa": "PBXGroup", "children": [f"{catalogs[n]} /* {n} */" for n in catalogs], "path": "Localization",
        "sourceTree": '"<group>"'}, 2))
    base_cfg = f"{signing_ref} /* Signing.xcconfig */"

    target_ids = {t["name"]: oid("target", t["name"]) for t in TARGETS}
    product_ids = {t["name"]: oid("product", t["name"]) for t in TARGETS}
    for t in TARGETS:
        n = t["name"]
        tid = target_ids[n]
        group = oid("syncgroup", t["folder"])
        exc = oid("syncexc", t["folder"])
        if t.get("exclude"):
            add("PBXFileSystemSynchronizedBuildFileExceptionSet", exc, "PBXFileSystemSynchronizedBuildFileExceptionSet",
                dict_block({"isa": "PBXFileSystemSynchronizedBuildFileExceptionSet",
                            "membershipExceptions": t["exclude"], "target": f"{tid} /* {n} */"}, 2))
        body = {"isa": "PBXFileSystemSynchronizedRootGroup"}
        if t.get("exclude"):
            body["exceptions"] = [f"{exc} /* PBXFileSystemSynchronizedBuildFileExceptionSet */"]
        body.update({"path": t["folder"], "sourceTree": '"<group>"'})
        add("PBXFileSystemSynchronizedRootGroup", group, t["folder"], dict_block(body, 2))
        add("PBXFileReference", product_ids[n], t["product"], dict_block({
            "isa": "PBXFileReference", "explicitFileType": "wrapper.application" if t["product"].endswith(".app")
            else "wrapper.cfbundle", "includeInIndex": "0", "path": t["product"], "sourceTree": "BUILT_PRODUCTS_DIR"}, 2))
        phases = []
        for ph in ("Sources", "Frameworks", "Resources"):
            pid = oid("phase", n, ph)
            files = []
            if ph == "Resources" and t.get("resources"):
                for cname, cref in catalogs.items():
                    bf = oid("buildfile", n, cname)
                    add("PBXBuildFile", bf, f"{cname} in Resources",
                        "{isa = PBXBuildFile; fileRef = " + cref + " /* " + cname + " */; }")
                    files.append(f"{bf} /* {cname} in Resources */")
            if ph == "Frameworks" and t.get("package"):
                bf = oid("buildfile", n, "NEBULAAppUI")
                dep = oid("pkgdep", n, "NEBULAAppUI")
                add("PBXBuildFile", bf, "NEBULAAppUI in Frameworks",
                    "{isa = PBXBuildFile; productRef = " + dep + " /* NEBULAAppUI */; }")
                add("XCSwiftPackageProductDependency", dep, "NEBULAAppUI", dict_block({
                    "isa": "XCSwiftPackageProductDependency", "package": f"{package_ref} /* XCLocalSwiftPackageReference \"NEBULAKit\" */",
                    "productName": "NEBULAAppUI"}, 2))
                files.append(f"{bf} /* NEBULAAppUI in Frameworks */")
            add(f"PBX{ph}BuildPhase", pid, ph, dict_block({
                "isa": f"PBX{ph}BuildPhase", "buildActionMask": "2147483647", "files": files,
                "runOnlyForDeploymentPostprocessing": "0"}, 2))
            phases.append(f"{pid} /* {ph} */")
        cfgs = {}
        for c in ("Debug", "Release"):
            cid = oid("cfg", n, c)
            cfgs[c] = cid
            settings = dict(t["settings"])
            if c == "Debug" and "INFOPLIST_FILE" in settings:
                # DEBUG builds may talk plain http to a loopback test server (NSAllowsLocalNetworking only)
                settings["INFOPLIST_FILE"] = settings["INFOPLIST_FILE"].replace("Info.plist", "Info-Debug.plist")
            add("XCBuildConfiguration", cid, c, dict_block({
                "isa": "XCBuildConfiguration", "baseConfigurationReference": base_cfg, "buildSettings": settings,
                "name": c}, 2))
        cl = oid("cfglist", n)
        add("XCConfigurationList", cl, f'Build configuration list for PBXNativeTarget "{n}"', dict_block({
            "isa": "XCConfigurationList", "buildConfigurations": [f"{cfgs[c]} /* {c} */" for c in cfgs],
            "defaultConfigurationIsVisible": "0", "defaultConfigurationName": "Release"}, 2))
        deps = []
        if t.get("test_of"):
            host = t["test_of"]
            proxy = oid("proxy", n)
            tdep = oid("tdep", n)
            add("PBXContainerItemProxy", proxy, "PBXContainerItemProxy", dict_block({
                "isa": "PBXContainerItemProxy", "containerPortal": f"{project} /* Project object */",
                "proxyType": "1", "remoteGlobalIDString": target_ids[host], "remoteInfo": host}, 2))
            add("PBXTargetDependency", tdep, "PBXTargetDependency", dict_block({
                "isa": "PBXTargetDependency", "target": f"{target_ids[host]} /* {host} */",
                "targetProxy": f"{proxy} /* PBXContainerItemProxy */"}, 2))
            deps.append(f"{tdep} /* PBXTargetDependency */")
        tbody = {"isa": "PBXNativeTarget", "buildConfigurationList": f'{cl} /* Build configuration list for PBXNativeTarget "{n}" */',
                 "buildPhases": phases, "buildRules": [], "dependencies": deps,
                 "fileSystemSynchronizedGroups": [f"{group} /* {t['folder']} */"], "name": n}
        if t.get("package"):
            tbody["packageProductDependencies"] = [f"{oid('pkgdep', n, 'NEBULAAppUI')} /* NEBULAAppUI */"]
        tbody.update({"productName": n, "productReference": f"{product_ids[n]} /* {t['product']} */",
                      "productType": f'"{t["type"]}"'})
        add("PBXNativeTarget", tid, n, dict_block(tbody, 2))

    add("PBXGroup", main_group, "main", dict_block({
        "isa": "PBXGroup", "children": [f"{oid('syncgroup', t['folder'])} /* {t['folder']} */" for t in TARGETS] +
        [f"{config_group} /* Config */", f"{loc_group} /* Localization */", f"{products_group} /* Products */"],
        "sourceTree": '"<group>"'}, 2))
    add("PBXGroup", products_group, "Products", dict_block({
        "isa": "PBXGroup", "children": [f"{product_ids[t['name']]} /* {t['product']} */" for t in TARGETS],
        "name": "Products", "sourceTree": '"<group>"'}, 2))
    for c, s in (("Debug", DEBUG), ("Release", RELEASE)):
        add("XCBuildConfiguration", proj_cfgs[c], c, dict_block({
            "isa": "XCBuildConfiguration", "baseConfigurationReference": base_cfg, "buildSettings": s, "name": c}, 2))
    add("XCConfigurationList", proj_cfglist, 'Build configuration list for PBXProject "NEBULA"', dict_block({
        "isa": "XCConfigurationList", "buildConfigurations": [f"{proj_cfgs[c]} /* {c} */" for c in proj_cfgs],
        "defaultConfigurationIsVisible": "0", "defaultConfigurationName": "Release"}, 2))
    add("XCLocalSwiftPackageReference", package_ref, 'XCLocalSwiftPackageReference "NEBULAKit"', dict_block({
        "isa": "XCLocalSwiftPackageReference", "relativePath": "NEBULAKit"}, 2))
    attrs = "{BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 2720; LastUpgradeCheck = 2720; TargetAttributes = {" + \
        " ".join(f"{target_ids[t['name']]} = {{CreatedOnToolsVersion = 27.2;" +
                 (f" TestTargetID = {target_ids[t['test_of']]};" if t.get("test_of") else "") + "};" for t in TARGETS) + "}; }"
    add("PBXProject", project, "Project object", dict_block({
        "isa": "PBXProject", "attributes": attrs,
        "buildConfigurationList": f'{proj_cfglist} /* Build configuration list for PBXProject "NEBULA" */',
        "developmentRegion": "en", "hasScannedForEncodings": "0", "knownRegions": ["en", "cs", "Base"],
        "mainGroup": f"{main_group}", "minimizedProjectReferenceProxies": "1", "preferredProjectObjectVersion": "77",
        "productRefGroup": f"{products_group} /* Products */", "projectDirPath": '""',
        "packageReferences": [f'{package_ref} /* XCLocalSwiftPackageReference "NEBULAKit" */'],
        "projectRoot": '""', "targets": [f"{target_ids[t['name']]} /* {t['name']} */" for t in TARGETS]}, 2))

    out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 77;", "\tobjects = {"]
    for section in sorted(objs):
        out.append(f"\n/* Begin {section} section */")
        for k in sorted(objs[section]):
            out.append(f"\t\t{k} = {objs[section][k]};")
        out.append(f"/* End {section} section */")
    out += ["\t};", f"\trootObject = {project} /* Project object */;", "}", ""]
    PROJ.mkdir(parents=True, exist_ok=True)
    (PROJ / "project.pbxproj").write_text("\n".join(out))
    write_schemes(target_ids)


def scheme(name: str, app_id: str, app_name: str, test: tuple[str, str] | None) -> str:
    ref = (f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_id}" '
           f'BuildableName = "NEBULA.app" BlueprintName = "{app_name}" ReferencedContainer = "container:NEBULA.xcodeproj"></BuildableReference>')
    tests = ""
    if test:
        tests = (f'<TestableReference skipped = "NO"><BuildableReference BuildableIdentifier = "primary" '
                 f'BlueprintIdentifier = "{test[0]}" BuildableName = "{test[1]}.xctest" BlueprintName = "{test[1]}" '
                 f'ReferencedContainer = "container:NEBULA.xcodeproj"></BuildableReference></TestableReference>')
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2720" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>{tests}</Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">{ref}</BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">{ref}</BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
'''


def write_schemes(ids: dict[str, str]) -> None:
    d = PROJ / "xcshareddata/xcschemes"
    d.mkdir(parents=True, exist_ok=True)
    (d / "NEBULA iOS.xcscheme").write_text(scheme("NEBULA iOS", ids["NEBULA"], "NEBULA", (ids["NEBULAUITests"], "NEBULAUITests")))
    (d / "NEBULA Mac.xcscheme").write_text(scheme("NEBULA Mac", ids["NEBULA Mac"], "NEBULA Mac",
                                                  (ids["NEBULAMacUITests"], "NEBULAMacUITests")))


if __name__ == "__main__":
    generate()
    local = read_xcconfig(ROOT / "Config/Local.xcconfig")
    print("wrote", PROJ)
    if local:
        print("Config/Local.xcconfig:", ", ".join(f"{k} = {v}" for k, v in local.items() if k != "CODE_SIGN_IDENTITY"))
    else:
        print("No Config/Local.xcconfig: Xcode uses the defaults of Config/Signing.xcconfig (no team, prefix com.example).")
