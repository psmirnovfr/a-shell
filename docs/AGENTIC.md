# a-Shell → Agentic iPad experience

Turns a-Shell (a full-screen bash/Python terminal for iOS) into a three-panel
agentic workspace for iPad:

```
┌──────────────┬───────────────────────────────┐
│              │          Terminal              │
│   Chat       │   (existing hterm WKWebView)   │
│  (Gemini)    ├───────────────────────────────┤
│              │       Browser / Preview        │
│              │      (WKWebView, HTML artefacts)│
└──────────────┴───────────────────────────────┘
```

- **Chat** — powered by the Google **Gemini API** (user brings their own API key).
- The model can **run bash commands** and **write files** inside a-Shell's existing
  sandbox (all the Unix tools + Python are already there) via tool/function calling.
- Built HTML artefacts can be **previewed in-app** in the browser panel.

This is an additive layer. The classic full-screen terminal still works; the agent
UI is switched on by a feature flag / setting (see *Feature flag*). Nothing in the
original command-execution engine is removed.

---

## Status / progress checklist

Legend: `[x]` done · `[~]` partial · `[ ]` todo

- [x] Branch `agentic-ipad` created & pushed to origin
- [x] Architecture doc (this file)
- [x] `GeminiService.swift` — API client (function calling) — *typechecks vs iOS 16 SDK*
- [x] `AgentModels.swift` — chat/tool models + `AgentViewModel` tool loop — *typechecks*
- [x] `AgentSettings.swift` — Keychain key + model + flag — *typechecks*
- [x] `CommandRunner` — headless bash execution capturing stdout as `String`
      *(mirrors executeCommand; can't be isolated-typechecked — needs the real
      ios_system module, so verify in a full build)*
- [x] `AgentView.swift` / `ChatPanel.swift` / `BrowserPanel.swift` — 3-panel UI — *typecheck*
- [x] Xcode project integration (files added to the 3 app targets in `project.pbxproj`,
      `plutil -lint` OK, `xcodebuild -list` OK)
- [x] Feature flag wired in `SceneDelegate.scene(willConnectTo:)` (gated `#available(iOS 16)`)
- [ ] `BuildProject` passes — **BLOCKED in this environment** (see *Build environment*)
- [ ] On-device smoke test (iPad) — needs a real device + API key

Keep this list current — it is the single source of truth for "where are we".

## Build environment (why `BuildProject` can't pass here)

`BuildProject` fails in ~2.7s **before any Swift is compiled**, for two reasons that
are pre-existing and unrelated to the agent code:

1. **Missing prebuilt XCFrameworks.** a-Shell links ~80 binary xcframeworks
   (`ios_system.xcframework`, `clang`, `python`/`cpython` aux frameworks, TeX, etc.)
   that live under `xcfs/.build/artifacts/…` and `cpython/…`. They are produced by a
   separate build step and are **not present in this checkout**, so linking cannot
   start. Upstream `master` fails here too.
2. **No signing.** No Apple account for Team `VG8Z23C8YL` and no provisioning profiles
   for `AsheKube.app.a-Shell*`.

To actually build/run, on a machine set up for a-Shell development:
- fetch/build the xcframeworks per the upstream a-Shell build instructions
  (the `xcfs` Swift package + the cpython aux frameworks), then
- set a valid signing team, then `BuildProject` / run on an iPad.

Because the frameworks are absent, the agent Swift was validated with
`swiftc -typecheck` against the iOS 16 simulator SDK instead (6/7 files, all clean;
`CommandRunner` reviewed against the existing `executeCommand`). Command to re-run:

```
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun -sdk iphonesimulator swiftc -typecheck -target arm64-apple-ios16.0-simulator \
  -sdk "$SDK" a-Shell/Agent/GeminiService.swift a-Shell/Agent/AgentSettings.swift \
  a-Shell/Agent/AgentModels.swift a-Shell/Agent/ChatPanel.swift \
  a-Shell/Agent/BrowserPanel.swift
```
(For `AgentView.swift` add a small `Webview` stub — see git history of this doc.)

---

## How to continue (read this first if you're a fresh session)

1. `git checkout agentic-ipad` and read this file top-to-bottom.
2. Look at the checklist above; pick the first unchecked item.
3. All new agent code lives in `a-Shell/Agent/`. Each file is written to compile
   independently where possible so partial progress still builds.
4. **The riskiest step is Xcode project integration** — see *Project integration*
   below. Do it with the provided Python script, then `plutil -lint` the pbxproj
   before building.
5. Commit + push after each meaningful step (the whole point is surviving session
   limits). Commit messages are prefixed `agent:`.

---

## Architecture

### The existing engine (do not break)

- `SceneDelegate.swift` (~300 KB) is the `UIWindowSceneDelegate` **and** the
  `WKScriptMessageHandler`. It owns:
  - `webView: KBWebViewBase` — the hterm.html terminal (JS ⟷ Swift bridge).
  - `contentView: ContentView` — SwiftUI wrapper hosted in a `UIHostingController`
    that is the window's `rootViewController` (`scene(_:willConnectTo:)`, ~line 3435).
- Command execution: `executeCommand(command:)` (~line 2353) pushes work onto
  `commandQueue`, sets up `stdin/stdout/tty` pipes, calls `ios_system(command)`
  (the [ios_system](https://github.com/holzschu/ios_system) C library), and streams
  the pipe output back to the terminal via `onStdout` → `outputToWebView` (~line 4686),
  which calls `window.term_.io.print(...)` in the webview.
- `ios_system` is **session/stream stateful**: before each run it calls
  `ios_switchSession`, `ios_setContext`, `ios_setStreams`, `ios_settty`. Any new
  execution path must do the same on the same `commandQueue` to stay consistent.

### What we add (`a-Shell/Agent/`)

| File | Role |
|------|------|
| `GeminiService.swift`   | Stateless Gemini REST client. Builds `generateContent` requests, sends the tool declarations, parses `functionCall` / text parts. Model configurable. |
| `AgentModels.swift`     | `ChatMessage`, `ToolCall`, `AgentTool` value types + `AgentViewModel` (`@MainActor ObservableObject`) that drives the **agent loop**: user msg → Gemini → (tool calls → execute → feed results back)* → final text. |
| `CommandRunner.swift`   | `executeCommandCapturing(_:completion:)` extension on `SceneDelegate`: same pipe/`ios_system` setup as `executeCommand` but collects stdout into a `String` and returns it instead of printing to the terminal. This is what the `run_bash` tool calls. |
| `AgentView.swift`       | Root SwiftUI 3-pane split view. Left = `ChatPanel`; right = terminal (existing `Webview`) over `BrowserPanel`. Uses a resizable `HSplitView`-style layout (custom for iOS). |
| `ChatPanel.swift`       | Message list + input box + streaming indicator, bound to `AgentViewModel`. |
| `BrowserPanel.swift`    | `WKWebView` wrapper with URL bar + "open local file" that the `preview_html` tool drives. |
| `AgentSettings.swift`   | Stores the Gemini API key (Keychain) + model name + feature flag (UserDefaults). |

### The agent tool loop

```
AgentViewModel.send(userText)
  history += user
  loop:
    resp = GeminiService.generate(history, tools)
    if resp has functionCalls:
        for call in functionCalls:
            result = execute(call)   // run_bash / write_file / read_file / preview_html
            history += functionResponse(call.name, call.id, result)
        continue loop
    else:
        history += model text
        break
```

**Tools exposed to Gemini**

| Tool | Args | Effect |
|------|------|--------|
| `run_bash`     | `command: string`, `timeout_s?: int` | Runs in a-Shell via `CommandRunner`, returns stdout+stderr (truncated). |
| `write_file`   | `path: string`, `content: string`    | Writes a file in the sandbox (so the model can author code/HTML). |
| `read_file`    | `path: string`                       | Reads a file back. |
| `preview_html` | `path: string`                       | Loads a local HTML file into the Browser panel. |

> Gemini 3.x note: `FunctionResponse` **must** include `name` and `id` (`call_id`).
> Sampling params (`temperature`/`top_p`/`top_k`) are ignored by 3.x — use
> `thinkingConfig`/`thinking_level` instead. Endpoint:
> `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`
> header `x-goog-api-key: <key>`.

### Gemini model

**Do not hardcode "the newest" model** — version strings change frequently and are
easy to get wrong. The default is `gemini-2.5-flash-lite` (a real, verifiable
flash-lite id). The settings screen has a **Fetch available models** button that calls
the `ListModels` endpoint (`GET /v1beta/models`, `GeminiService.listModels()`) with the
user's key and shows the actually-available ids in a picker — that is the authoritative
source for "what's current". The model field is also free-text for manual override.

---

## Project integration (the fiddly part)

The project has **3 app targets** that build the UI (regular + mini variants). A file
is in the UI build set when it appears in these three `PBXSourcesBuildPhase` blocks:

| Sources phase ID | matches `ContentView.swift` build file |
|------------------|----------------------------------------|
| `224A903A2ADD0999006DB9CC` | `224A9047…` |
| `22984EE622C93DBC00069497` | `22984EF2…` |
| `229D2476257931E4004A78AC` | `229D2481…` |

To add a new Swift file you must add, in `a-Shell.xcodeproj/project.pbxproj`:
1. **one** `PBXFileReference` (in the file-reference section, ~line 2003 style).
2. **one** entry in the `a-Shell` PBXGroup children list (~line 2887).
3. **three** `PBXBuildFile` entries (unique 24-hex IDs), one per phase above.
4. those three build files listed inside the three Sources phases.

Use `scripts/add_agent_files_to_pbxproj.py` (added on this branch) which does all of
the above idempotently, then validate:

```
python3 scripts/add_agent_files_to_pbxproj.py
plutil -lint "a-Shell.xcodeproj/project.pbxproj"   # must say OK
```

Then build with the `BuildProject` Xcode MCP tool (or `xcodebuild`).

### Feature flag

`AgentSettings.agentModeEnabled` (UserDefaults `agentModeEnabled`, default `false`
until the flow is proven). In `scene(_:willConnectTo:)` we choose the root view:

```swift
if AgentSettings.shared.agentModeEnabled {
    let agentRoot = AgentView(scene: self)   // owns the same webView/Webview
    window.rootViewController = UIHostingController(rootView: agentRoot)
} else {
    contentView = ContentView()              // classic full-screen terminal
    window.rootViewController = UIHostingController(rootView: contentView)
}
```

`AgentView` must reuse `contentView.webview` for the terminal pane so the existing
`SceneDelegate.webView` wiring (message handler, output routing) keeps working
unchanged.

---

## Security / keys

- The Gemini API key is stored in the **Keychain** (`AgentSettings`), never in
  UserDefaults or source. It is entered by the user in the chat settings sheet.
- `run_bash` executes with the same privileges as any command the user types — this
  is a local sandbox on-device, consistent with a-Shell's existing model. There is a
  per-call confirmation toggle (`AgentSettings.confirmCommands`) so the user can gate
  execution if desired.
</content>
