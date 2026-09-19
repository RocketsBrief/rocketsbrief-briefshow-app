#!/usr/bin/env python3
"""Folders: renaming them in both places, and dropping photographs onto them.

    python3 Tools/run-folder-rename-test.py

Reports from the client, 20.09:

    *„Right click on the folder should show rename button. Or click once and
    wait for a bit click another one to enable renaming, like usually"*

    *„ali kada kliknem na folder ili na listi ili u gridu jednom i sackam jednu
    sekundu sledeci klik treba da aktivira renameing… a ako kliknem brzo dva
    puta onda otvara folder"*

    *„I kada napravim folder i pored njega su slike i ja selektiram sve slike i
    hocu da ih privucem u folder ne radi, samo bi mogao da privucem u listu
    foldera sa desne strane! Mora da radi i kada provucem u gridu na folder"*

The middle one is the one that decides the shape of this file: the list and the
grid are not two similar behaviours to keep in step, they are ONE, so the checks
below insist on one function and one number rather than on two that match today.

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

# The clarification the same day: *„ali kada kliknem na folder ili na listi ili u
# gridu jednom i sackam jednu sekundu sledeci klik treba da aktivira renameing"* —
# the list is not a second, similar behaviour, it is the same one.
row_start = source.find("private func handleRowTap(")
row_tap = source[row_start:source.find("private func beginRename(", row_start)] if row_start != -1 else ""
check("a row in the list decides a click the same way the grid does",
      "briefShowFolderClickAction(" in row_tap and "NSEvent.doubleClickInterval" in row_tap,
      "the list would feel different from the grid, which is what the client asked against")

check("both wait the same number, defined once",
      source.count("let briefShowFolderRenameClickDelay: TimeInterval") == 1
      and source.count("renameDelay: briefShowFolderRenameClickDelay") == 2,
      "two delays drift into two feels")

# A row is not a grid cell: a plain click there also selects and toggles the
# folder open. A FAST second click has to OPEN, not toggle back shut.
open_branch = row_tap[row_tap.find("case .open:"):row_tap.find("case .remember:")] if "case .open:" in row_tap else ""
check("a fast second click on a row opens it rather than closing it again",
      "expandedURLs.insert(node.url)" in open_branch and "expandedURLs.remove" not in open_branch,
      "double-clicking a folder in the list would shut it")

sidebar_row_start = source.find("private func row(for node: FolderNode, depth: Int)")
sidebar_row = source[sidebar_row_start:source.find("private func handleRowTap(", sidebar_row_start)] if sidebar_row_start != -1 else ""
check("the row renames in place, like the grid cell",
      "renamingURL == node.url" in sidebar_row and "TextField(" in sidebar_row)

# On macOS a drag on the same view takes clicks away from a text field inside it:
# pressing into the name would start dragging the folder.
check("while the name is being typed, the row's drag and tap stand down",
      "if renamingURL == node.url {" in sidebar_row and "return AnyView(base)" in sidebar_row,
      "clicking into the field would pick the folder up instead")

check("the typing field takes focus by itself, in both places",
      source.count(".onAppear { gridRenameFieldFocused = true }") == 1
      and source.count(".onAppear { renameFieldFocused = true }") == 1,
      "the client would have to click into the field before typing")

check("what the row typed is renamed by the one renameFolder on disk",
      "onCommitRename(node, renameText)" in source and "onCommitRename: { node, newName in" in source,
      "a second rename path would drift from the grid's")

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
