#!/usr/bin/env python3
"""Folders in the grid: renaming them, and dropping photographs onto them.

    python3 Tools/run-folder-rename-test.py

Two reports from the client, 20.09:

    *„Right click on the folder should show rename button. Or click once and
    wait for a bit click another one to enable renaming, like usually"*

    *„I kada napravim folder i pored njega su slike i ja selektiram sve slike i
    hocu da ih privucem u folder ne radi, samo bi mogao da privucem u listu
    foldera sa desne strane! Mora da radi i kada provucem u gridu na folder"*

Two halves, because the two reports are different kinds of thing:

  1. COMPILED — the real briefShowFolderClickAction and briefShowRenameDestination
     are pulled out of ContentView.swift by text and run (same extractor as
     Tools/run-double-click-test.py, so the test compiles what ships and cannot
     drift). That is the slow-click rule and the naming rule.

  2. READ — the wiring around them: that the grid's folder cell takes a drop at
     all, that it lands in the SAME handleDropOnFolder the sidebar row uses, that
     both read a drop through one reader, and that the colour label is carried to
     the new name. A drag cannot be scripted against this window (osascript has
     already failed on it once — see BRIEFSHOW_DEVELOP_NOTES.md), so this half
     says what is CONNECTED, never that a drag was seen to work. That is left
     for the eyes, and it is written down as such.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "BriefShow" / "ContentView.swift"
source = SOURCE.read_text(encoding="utf-8")


def extract(signature: str, returns: str) -> str:
    start = source.find(signature)
    if start == -1:
        sys.exit(f"{signature!r} not found in ContentView.swift — was it renamed or moved?")
    depth, i = 0, source.index("{", source.index(returns, start))
    while i < len(source):
        if source[i] == "{":
            depth += 1
        elif source[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    return source[start:i + 1]


# The enum the click function answers with travels with it.
enum_start = source.find("enum BriefShowFolderClick: String {")
if enum_start == -1:
    sys.exit("enum BriefShowFolderClick not found in ContentView.swift")
enum_src = source[enum_start:source.index("}", enum_start) + 1]

click_fn = extract("func briefShowFolderClickAction(", ") -> BriefShowFolderClick")
double_fn = extract("func briefShowIsDoubleClick(", ") -> Bool")
name_fn = extract("func briefShowRenameDestination(", ") -> URL?")

test = (ROOT / "Tools" / "test-folder-rename.swift").read_text(encoding="utf-8")
bundle = ("import Foundation\n\n" + enum_src + "\n\n" + double_fn + "\n\n" + click_fn +
          "\n\n" + name_fn + "\n\n" + test.replace("import Foundation\n", "", 1))

print(f"extracted from ContentView.swift: BriefShowFolderClick, briefShowIsDoubleClick, "
      f"briefShowFolderClickAction, briefShowRenameDestination")
compiled = subprocess.run(["swift", "-"], input=bundle, text=True)

# ---- 2. the wiring, read out of the source --------------------------------

failures = 0


def check(label: str, passed: bool, detail: str = "") -> None:
    global failures
    print(f"  {'PASS' if passed else 'FAIL'}  {label}" + (f" — {detail}" if detail and not passed else ""))
    if not passed:
        failures += 1


print("\nwhat is wired to what")

cell_start = source.find("private func folderCell(for url: URL) -> some View {")
cell = source[cell_start:source.find("private func videoCell(", cell_start)] if cell_start != -1 else ""
check("folderCell is still there to read", bool(cell))

# The report: a selection could only be dragged onto the LIST on the left.
check("a folder drawn in the grid takes a file drop",
      ".onDrop(" in cell and "UTType.fileURL" in cell,
      "the grid's folder is not a drop target — the 20.09 report")

check("that drop lands in the same handler the sidebar row uses",
      "handleDropOnFolder(urls, destination: url)" in cell,
      "a second copy of the move would drift from the sidebar's")

# handleDropOnFolder is what turns one dragged photo into the whole selection,
# which is the client's case: 53 selected, one picked up.
handler_start = source.find("private func handleDropOnFolder(")
handler = source[handler_start:source.find("private func transferItems(", handler_start)] if handler_start != -1 else ""
check("one dragged photo still carries the whole selection",
      "selectedURLs.contains(dragged)" in handler and "selectedURLs.count > 1" in handler,
      "dropping a selection would move only the photo under the pointer")

check("both drops read the providers through one reader",
      source.count("func briefShowLoadDroppedURLs(") == 1
      and "briefShowLoadDroppedURLs(from: providers)" in cell
      and "briefShowLoadDroppedURLs(from: providers, completion: completion)" in source,
      "two copies of the provider reader can drift apart")

check("the folder under the pointer is drawn as the target",
      "gridDropTargetFolderURL == url" in cell,
      "nothing on screen says where the photos would land")

print("\nthe two ways into a rename")

check("right-click on a folder in the grid offers it",
      'Button("Rename…")' in cell,
      "the first half of the 20.09 report")

check("right-click on a folder in the sidebar offers it too",
      'Button("Rename…")' in source[source.find("private func folderContextMenuItems("):],
      "the client right-clicks in both places")

check("the grid cell renames in place, the way Finder does",
      "gridRenamingFolderURL == url" in cell and "TextField(" in cell)

check("ONE tap gesture decides open / rename / remember",
      cell.count(".onTapGesture") == 1 and "handleFolderCellTap(url)" in cell,
      "a count-2 gesture over a count-1 gesture is the lag the client reported on photos")

check("the system's own double-click setting is what it measures against",
      "NSEvent.doubleClickInterval" in source[source.find("private func handleFolderCellTap("):][:900],
      "a number chosen here would feel wrong on a Mac set up differently")

# FolderColorStore is keyed by path and says so itself: a colour does not follow
# a folder that is renamed. The grid now DRAWS the folder in that colour, so
# losing it on rename would be visible immediately.
rename_start = source.find("private func renameFolder(at url: URL, to rawName: String)")
rename = source[rename_start:source.find("// MARK: Paste", rename_start)] if rename_start != -1 else ""
check("the colour label follows the folder to its new name",
      "FolderColorStore.color(for: url)" in rename and "FolderColorStore.setColor(label, for: destination)" in rename,
      "a labelled folder would come back grey after a rename")

check("the open folder follows its own new name",
      "selectedFolderURL = destination" in rename and "refreshFolderTree()" in rename,
      "the grid would keep showing a path that no longer exists")

print()
if failures or compiled.returncode != 0:
    print(f"{failures} wiring check(s) failed" if failures else "the compiled half failed")
    sys.exit(1)
print("all good")
