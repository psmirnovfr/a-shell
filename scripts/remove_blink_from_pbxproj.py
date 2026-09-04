#!/usr/bin/env python3
"""
Remove all references to blink.xcframework from project.pbxproj.

blink.xcframework was added by this fork but has no public prebuilt source and is
not imported by any Swift/ObjC code (embed-only). Removing its references lets the
project resolve its framework set. Idempotent; validate with `plutil -lint`.
"""
import os, sys

PROJECT = os.path.join(os.path.dirname(__file__), "..",
                       "a-Shell.xcodeproj", "project.pbxproj")

def main():
    with open(PROJECT) as f:
        lines = f.readlines()
    kept = [ln for ln in lines if "blink.xcframework" not in ln]
    removed = len(lines) - len(kept)
    if removed == 0:
        print("No blink.xcframework references found (already clean).")
        return 0
    with open(PROJECT, "w") as f:
        f.writelines(kept)
    print(f"Removed {removed} line(s) referencing blink.xcframework.")
    print("Now run: plutil -lint a-Shell.xcodeproj/project.pbxproj")
    return 0

if __name__ == "__main__":
    sys.exit(main())
