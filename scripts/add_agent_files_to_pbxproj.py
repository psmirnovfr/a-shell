#!/usr/bin/env python3
"""
Idempotently add the a-Shell/Agent/*.swift files to the three a-Shell app
targets in a-Shell.xcodeproj/project.pbxproj.

See docs/AGENTIC.md > "Project integration". Safe to run multiple times: files
already referenced are skipped. Validate afterwards with:

    plutil -lint a-Shell.xcodeproj/project.pbxproj
"""
import os
import re
import secrets
import sys

PROJECT = os.path.join(os.path.dirname(__file__), "..",
                       "a-Shell.xcodeproj", "project.pbxproj")

# Files (relative to the a-Shell group, whose path is "a-Shell").
AGENT_FILES = [
    "Agent/GeminiService.swift",
    "Agent/AgentSettings.swift",
    "Agent/AgentModels.swift",
    "Agent/CommandRunner.swift",
    "Agent/BrowserPanel.swift",
    "Agent/ChatPanel.swift",
    "Agent/AgentView.swift",
]

# The three app-target PBXSourcesBuildPhase IDs that build the UI (they all
# currently build ContentView.swift).
SOURCES_PHASE_IDS = [
    "224A903A2ADD0999006DB9CC",
    "22984EE622C93DBC00069497",
    "229D2476257931E4004A78AC",
]

# The a-Shell PBXGroup (children include ContentView.swift). Anchor on this ref.
GROUP_ANCHOR = "22984EF122C93DBC00069497 /* ContentView.swift */,"


def gen_id(existing):
    while True:
        i = secrets.token_hex(12).upper()
        if i not in existing:
            existing.add(i)
            return i


def main():
    with open(PROJECT, "r") as f:
        text = f.read()

    existing_ids = set(re.findall(r"\b([0-9A-F]{24})\b", text))

    build_file_lines = []   # PBXBuildFile section entries
    file_ref_lines = []     # PBXFileReference section entries
    group_lines = []        # children entries for the a-Shell group
    # phase_id -> list of "  <buildid> /* name in Sources */," lines
    phase_lines = {pid: [] for pid in SOURCES_PHASE_IDS}

    added_any = False
    for path in AGENT_FILES:
        name = os.path.basename(path)
        if re.search(r"/\*\s*" + re.escape(name) + r"\s*\*/", text):
            print(f"skip (already present): {name}")
            continue
        added_any = True
        file_ref_id = gen_id(existing_ids)
        file_ref_lines.append(
            f'\t\t{file_ref_id} /* {name} */ = {{isa = PBXFileReference; '
            f'lastKnownFileType = sourcecode.swift; path = "{path}"; '
            f'sourceTree = "<group>"; }};'
        )
        group_lines.append(f"\t\t\t\t{file_ref_id} /* {name} */,")
        for pid in SOURCES_PHASE_IDS:
            build_id = gen_id(existing_ids)
            build_file_lines.append(
                f'\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; '
                f'fileRef = {file_ref_id} /* {name} */; }};'
            )
            phase_lines[pid].append(
                f"\t\t\t\t{build_id} /* {name} in Sources */,")
        print(f"add: {name}")

    if not added_any:
        print("Nothing to do; all Agent files already referenced.")
        return 0

    # 1. Insert PBXBuildFile entries after the section marker.
    text = text.replace(
        "/* Begin PBXBuildFile section */\n",
        "/* Begin PBXBuildFile section */\n" + "\n".join(build_file_lines) + "\n",
        1,
    )
    # 2. Insert PBXFileReference entries after the section marker.
    text = text.replace(
        "/* Begin PBXFileReference section */\n",
        "/* Begin PBXFileReference section */\n" + "\n".join(file_ref_lines) + "\n",
        1,
    )
    # 3. Insert into the a-Shell group children.
    if GROUP_ANCHOR not in text:
        print("ERROR: group anchor not found", file=sys.stderr)
        return 1
    text = text.replace(
        GROUP_ANCHOR,
        GROUP_ANCHOR + "\n" + "\n".join(group_lines),
        1,
    )
    # 4. Insert into each Sources build phase (after its `files = (`).
    for pid, lines in phase_lines.items():
        pattern = re.compile(
            r"(" + re.escape(pid) + r" /\* Sources \*/ = \{.*?files = \(\n)",
            re.DOTALL,
        )
        m = pattern.search(text)
        if not m:
            print(f"ERROR: sources phase {pid} not found", file=sys.stderr)
            return 1
        text = text[:m.end()] + "\n".join(lines) + "\n" + text[m.end():]

    with open(PROJECT, "w") as f:
        f.write(text)
    print("Done. Now run: plutil -lint a-Shell.xcodeproj/project.pbxproj")
    return 0


if __name__ == "__main__":
    sys.exit(main())
