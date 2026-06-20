# File structure

Top-level layout and subtree guide for Swift USB Imager.

---

## Top-level layout

```
swift-usb-imager/
+- Package.swift          SwiftPM manifest (products, targets, deps)
+- Package.resolved       Pinned dependency versions
+- VERSION                CalVer version string (single source of truth)
+- README.md              Project overview and quick-start links
+- AGENTS.md              Agent and coding-style instructions
+- CLAUDE.md              Claude-specific task instructions (@includes)
+- REPO_TYPE              Repo type marker ("other")
+- build_debug.sh         Assemble USBImagerApp.app bundle (debug build)
+- build_release.sh       Assemble USBImagerApp.app bundle (release build)
+- capture_screenshot.sh  Launch the app and capture a screenshot
+- source_me.sh           Bootstrap Python path for meta/tooling scripts
+- Brewfile               Homebrew dependencies
+- pip_requirements-dev.txt  Python dev dependencies (pytest, pyflakes, ...)
+- pip_requirements-meta.txt Python meta/propagation tools
+- Sources/               All Swift source targets (see subtree below)
+- Tests/                 SwiftPM test targets (swift test)
+- tests/                 Python/pytest repo-hygiene tests
+- docs/                  Documentation (see subtree below)
+- screenshots/           Offscreen-rendered PNG screenshots (generated)
+- devel/                 Developer tools and scripts
+- tools/                 Helper scripts + authopen_fd_probe/ (spike, see below)
+- USBImagerApp.app/      Built app bundle (generated, not committed)
+- OTHER_REPOS/           Local sibling repo checkouts (not committed)
```

---

## Key subtrees

### Sources/

One directory per SwiftPM target. Each directory maps to a single module.

```
Sources/
+- DiskModel/             DiskArbitration/IOKit disk enumeration + safety rules
+- HelperProtocol/        Shared XPC @objc protocol and Codable control-plane types
+- Verifier/              CryptoKit SHA-512 streaming; SHA512SUMS parser
+- KeychainStore/         Trusted-checksum Keychain cache
+- FlashEngine/           FlashEngine actor; XPC helper connection; progress relay
+- USBImagerCore/         GUI-independent workflow seam (service protocols + impls)
|  +- Services.swift          ChecksumService, ImageSourceService, DiskTargetService,
|  |                          FlashOrchestrationService protocol declarations
|  +- ChecksumService.swift   Default ChecksumService implementation
|  +- ImageSourceService.swift Default ImageSourceService implementation
|  +- DiskTargetService.swift  Default DiskTargetService implementation
|  +- FlashOrchestrationService.swift  Default FlashOrchestrationService implementation
|  +- XPCFlashEngineFactory.swift  Real XPC-backed FlashEngineFactory; helper identity
|  |                               constants (Mach service + requirement string)
|  +- HelperUnavailableEngineFactory.swift  No-op factory for tests and no-helper path
|  +- CoreError.swift         CoreError enum + CoreExitCode + FlashEngineError message map
|  `- FlashProgressData.swift FlashProgressData struct (front-end-neutral progress type)
+- AppUI/                 SwiftUI views; AppViewModel; StyleHelpers; FlashState
+- USBImagerApp/          @main GUI executable; URL-scheme handoff; AutoExitCoordinator
|  +- USBImagerApp.swift
|  `- Info.plist              CFBundleURLTypes for usbimager:// scheme (bundle-assembled)
+- USBImagerCLI/          "usbimager" terminal CLI; ArgumentParser root + subcommands
|  +- Usbimager.swift         Root command; CoreServices seam; shared exit path
|  `- Subcommands/
|     +- ListCommand.swift
|     +- VerifyCommand.swift
|     +- FlashCommand.swift
|     `- OpenCommand.swift
+- USBImagerShots/        Offscreen ImageRenderer screenshot harness
|  `- USBImagerShots.swift
+- PrivilegedHelper/      Root LaunchDaemon: write, verify, unmount, auth stub
+- AuthopenProbeCore/     SPIKE (non-production): pure preflight decision logic for
|                         the authopen raw-disk-write research; fixture-tested, not
|                         wired into the flash path
`- README.md              Per-target module summary
```

The `authopen_fd_probe` executable lives under `tools/authopen_fd_probe/`
(not `Sources/`); both it and `AuthopenProbeCore` are NON-PRODUCTION research
spikes for the authopen raw-disk-write investigation. See the `tools/` subtree
below.

### Tests/

SwiftPM test targets, run with `swift test`.

```
Tests/
+- DiskModelTests/
+- HelperProtocolTests/
+- VerifierTests/
+- KeychainStoreTests/
+- FlashEngineTests/
+- PrivilegedHelperTests/
+- AppUITests/
+- USBImagerCoreTests/
+- USBImagerCLITests/
`- AuthopenProbeCoreTests/    SPIKE (non-production): fixture tests for the
                             authopen preflight decision logic
```

### tests/

Python/pytest repo-hygiene checks. Run with `pytest tests/`.

```
tests/
+- conftest.py                pytest configuration
+- file_utils.py              shared get_repo_root() helper
+- test_ascii_compliance.py   ASCII-only source check
+- test_markdown_links.py     local Markdown link existence check
+- test_pyflakes_code_lint.py pyflakes gate over Python files
+- test_shebangs.py           shebang + executable-bit enforcement
+- TESTS_README.md            test suite overview
`- ... (other hygiene tests)
```

### tools/

Helper scripts plus one NON-PRODUCTION research spike. The spike is kept out of
the shipping flash path and out of the main `swift test` lane.

```
tools/
+- build_bundle.sh        App-bundle assembly helper
+- sign_app.sh            Code-signing helper
+- notarize.sh            Notarization helper
`- authopen_fd_probe/     SPIKE (non-production): standalone authopen / SCM_RIGHTS
   +- main.swift          fd-passing probe harness; depends on AuthopenProbeCore
   `- README.md           Probe build/run notes (selftest mode)
```

### docs/

```
docs/
+- CODE_ARCHITECTURE.md   System design, module table, dependency graph
+- FILE_STRUCTURE.md      This file
+- CHANGELOG.md           Reverse-chronological change log
+- INSTALL.md             Setup steps and dependencies
+- USAGE.md               How to run the app, CLI flags, and examples
+- SIGNING.md             Code-signing and notarization steps
+- AUTHORS.md             Maintainers and contributors
+- REPO_STYLE.md          Repo-wide conventions (canonical)
+- PYTHON_STYLE.md        Python coding conventions
+- PYTEST_STYLE.md        pytest test-writing rules
+- MARKDOWN_STYLE.md      Markdown formatting rules
+- E2E_TESTS.md           End-to-end test conventions
+- CLAUDE_HOOK_USAGE_GUIDE.md  Claude Code hook behavior reference
`- active_plans/          In-flight planning artifacts (subdirs by kind)
```

---

## Generated artifacts

| Artifact | Location | How generated |
| --- | --- | --- |
| App bundle | `USBImagerApp.app/` | `bash build_debug.sh` or `bash build_release.sh` |
| Screenshots | `screenshots/*.png` | `swift run USBImagerShots` (offscreen render) |
| SwiftPM build products | `.build/` | `swift build` / `swift test` |
| Python bytecode | `__pycache__/`, `*.pyc` | pytest runs |

All generated artifacts are `.gitignore`d except the committed screenshots under
`screenshots/` (small PNGs checked in for documentation).

---

## Documentation map

Primary docs are under `docs/`. Root-level docs:

- `README.md` - project overview, quick start
- `AGENTS.md` - agent and style instructions
- `VERSION` - CalVer version string

---

## Where to add new work

| Work type | Location |
| --- | --- |
| New Swift library module | `Sources/<ModuleName>/` + entry in `Package.swift` |
| New CLI subcommand | `Sources/USBImagerCLI/Subcommands/<Name>Command.swift` |
| New core service protocol | `Sources/USBImagerCore/Services.swift` (protocol) + `Sources/USBImagerCore/<Name>Service.swift` (impl) |
| New SwiftUI panel or view | `Sources/AppUI/` |
| SwiftPM tests | `Tests/<TargetName>Tests/` + test target in `Package.swift` |
| Python hygiene tests | `tests/test_<topic>.py` |
| Documentation | `docs/<NAME>.md` (SCREAMING_SNAKE_CASE) |
| Developer scripts | `devel/` or `tools/` |
| Build scripts | Repo root (`build_*.sh`) |
