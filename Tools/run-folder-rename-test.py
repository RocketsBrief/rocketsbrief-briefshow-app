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

# What a folder is said to hold before it is trashed: the struct and the counter
# that takes its listing as an argument (the FileManager overload stays behind —
# a test has no disk to read).
contents_start = source.find("struct BriefShowFolderContents: Equatable {")
if contents_start == -1:
    sys.exit("struct BriefShowFolderContents not found in ContentView.swift")
depth, i = 0, source.index("{", contents_start)
while i < len(source):
    if source[i] == "{":
        depth += 1
    elif source[i] == "}":
        depth -= 1
        if depth == 0:
            break
    i += 1
contents_src = source[contents_start:i + 1]
count_fn = extract("func briefShowFolderContentsSummary(\n    of url: URL,\n    listing:",
                   ") -> BriefShowFolderContents")

test = (ROOT / "Tools" / "test-folder-rename.swift").read_text(encoding="utf-8")
bundle = ("import Foundation\n\n" + enum_src + "\n\n" + double_fn + "\n\n" + click_fn +
          "\n\n" + name_fn + "\n\n" + contents_src + "\n\n" + count_fn +
          "\n\n" + test.replace("import Foundation\n", "", 1))

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

cell_start = source.find("private func folderCell(for url: URL)")
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

print("\nthe name is part of the thing, and a picked folder looks picked")

# *„kad se klikne na ime da odreaguje ne samo na fajl kao fajl vec da odreaguje
# isto kad se klikne na ime fajla da gleda kao da si kliknuo na taj fajl"* — the
# gestures used to sit on the icon alone, leaving the name under it dead.
icon_block = cell[cell.find("ZStack {"):cell.find("if isRenaming {")] if "ZStack {" in cell else ""
check("the folder's click, menu and drop sit on the whole cell, not on the icon",
      ".onTapGesture" not in icon_block and ".contextMenu" not in icon_block and ".onDrop(" not in icon_block,
      "clicking the folder's name would do nothing")

check("and they are attached after the name is in the cell",
      cell.find("Text(url.lastPathComponent)") < cell.find(".onTapGesture"),
      "the name is outside whatever the gestures cover")

video_start = source.find("private func videoCell(for url: URL)")
video = source[video_start:source.find("private func loadGridVideoThumbnails(", video_start)] if video_start != -1 else ""
check("a video's name plays it too",
      video.find("Text(url.lastPathComponent)") < video.find(".onTapGesture"),
      "the same dead name, on the video cell")

# *„kada je folder u gridu i kada kliknem na njega da se vidi da je selektovan"*
check("a folder picked in the grid is drawn as picked",
      "selectedGridFolderURL == url" in cell and "isSelected ? accentColor" in cell,
      "a click that changes nothing visible reads as a click that did not register")

# ⚠️ Folders are deliberately kept out of photoURLs and of the photo selection —
# every label, export, delete and preview path reads those as "photographs".
check("the folder's highlight has its own var, and never enters the photo selection",
      "@State private var selectedGridFolderURL: URL?" in source
      and "selectedURLs.insert(url)" not in cell and "selectedGridFolderURL" not in handler,
      "a folder in selectedURLs would reach export, delete and the loupe at once")

tap_start = source.find("private func handleFolderCellTap(")
tap = source[tap_start:source.find("private func openGridFolder(", tap_start)] if tap_start != -1 else ""
check("the folder is picked whatever the click turns out to mean",
      "selectedGridFolderURL = url" in tap,
      "a click that only armed a rename would leave nothing on screen")

select_tap = source[source.find("private func handleSelectTap("):][:1200]
check("picking a photograph puts the folder's highlight out",
      "selectedGridFolderURL = nil" in select_tap,
      "two things drawn as picked at once")

print("\nand a click anywhere else ends the typing")

# *„kada je ovako selektirano da se renamuje ne mora da ceka moj esc key da
# prekine renameing, ako ja kliknem negde sastrane da gasi renaming"* — four
# places a click can land, and all four end it. What was typed is KEPT: Esc is
# what throws a name away, which is why it stays.
check("losing the focus ends it and keeps the name, in both places",
      ".onChange(of: gridRenameFieldFocused) { focused in" in source
      and ".onChange(of: renameFieldFocused) { focused in" in source
      and source.count("if !focused { commitGridRename() }") == 1
      and source.count("if !focused { commitRename(node) }") == 1,
      "the field would sit there until Esc")

check("a click on another folder ends it first, then means what it means",
      "if let renaming = gridRenamingFolderURL {" in tap and "commitGridRename()" in tap,
      "clicking a second folder while typing would do nothing at all")

check("a click on another row in the list does the same",
      "if let renaming = renamingURL {" in row_tap and "commitRenameInProgress()" in row_tap)

check("a click on a photograph ends it",
      "commitGridRename()" in select_tap,
      "typing would survive a click onto a photo")

grid_start = source.find("private var thumbnailGrid: some View {")
grid = source[grid_start:source.find("private func folderCell(", grid_start)] if grid_start != -1 else ""
check("a click on empty space in the grid ends it",
      ".onTapGesture {" in grid and "commitGridRename()" in grid,
      "the one place left where a click did nothing")

print("\ndeleting a folder")

# *„na desnom kliku da mogu da brisem folder isto kao fajl ako ima unutra nesto
# (neke fajlove da upozori klijenta) isto na backspace da moze da se izbrise
# folder"* — one question and one trash, reached from three places.
check("the grid's right-click can trash a folder",
      'Button("Move to Trash", role: .destructive)' in cell and "requestTrashFolder(FolderNode(url: url))" in cell,
      "a folder could be deleted only from the list on the left")

check("the list's right-click still can",
      'Button("Delete", role: .destructive)' in source[source.find("private func folderContextMenuItems("):])

key_start = source.find("let deleteKeyCode: UInt16 = 51")
keys = source[key_start:key_start + 3000] if key_start != -1 else ""
check("Backspace on a picked folder asks the same question",
      "selectedGridFolderURL" in keys and "requestTrashFolder(FolderNode(url: folderURL))" in keys,
      "the key would do nothing on a folder")

# A photo selection is what the key has always meant; a leftover folder highlight
# must not take that away.
check("photographs still answer the key first",
      keys.find("pendingTrashPhotoURLs = photoURLs.filter") < keys.find("requestTrashFolder(FolderNode(url: folderURL))"),
      "a folder clicked earlier would swallow Backspace meant for the photos")

check("and never while a name is being typed",
      "gridRenamingFolderURL == nil," in keys,
      "Backspace would delete the folder instead of a letter")

# The count is read when the question is asked, not while the dialog is up.
req = source[source.find("private func requestTrashFolder("):][:1400]
check("what is inside is counted when the question is asked",
      "pendingTrashFolderContents = briefShowFolderContentsSummary(of: node.url)" in req)

check("and the dialog says exactly that",
      "Text(pendingTrashFolderContents.warning)" in source,
      "the client is told 'everything inside it' and no number")

print("\nand it is gone from the grid at once")

# *„ja kad sam obrisao folder on je pokazivao da je jos tu… mora kad se obrise
# folder odma da se ne vidi vise a ne da ja izadjem da bi on refreshovao folder"*
# — refreshFolderTree redraws the LIST; the grid keeps its own gridFolderURLs,
# read when the folder was opened, and nobody was telling it.
trash_start = source.find("private func trashFolder(")
trash = source[trash_start:source.find("private func removeFromGridListings(", trash_start)] if trash_start != -1 else ""
check("trashing a folder takes it out of what the grid is drawing",
      "removeFromGridListings([node.url])" in trash,
      "the tile stays on screen until the folder is left and entered again")

# ⚠️ The LAST refreshFolderTree, not the first: the guard above it redraws the
# tree too, on the path where the Trash refused. Reading the first one compares
# the success path against the failure path and calls the order wrong.
check("and it does that before the tree is redrawn, not instead of it",
      trash.find("removeFromGridListings") < trash.rfind("refreshFolderTree()"),
      "the list on the left would go stale instead")

# A folder that did not actually go to the Trash must not disappear from the
# screen: that would be a grid that disagrees with the disk.
check("nothing is taken off screen unless the Trash took it",
      "guard (try? FileManager.default.trashItem(at: node.url, resultingItemURL: nil)) != nil else {" in trash,
      "a failed trash would still empty the tile")

check("the open folder is cleared when the trashed one HELD it, not only when it was it",
      'openPath?.hasPrefix(trashedPath + "/")' in trash,
      "the grid would keep showing photographs from a path that no longer exists")

helper_start = source.find("private func removeFromGridListings(")
helper = source[helper_start:source.find("// MARK: New Folder", helper_start)] if helper_start != -1 else ""
check("folders and films both leave the grid",
      "gridFolderURLs.removeAll" in helper and "gridVideoURLs.removeAll" in helper)

check("and nothing goes on pointing at what is gone",
      "selectedGridFolderURL = nil" in helper and "gridRenamingFolderURL = nil" in helper
      and "gridRenameArmedURL = nil" in helper,
      "a highlight or a half-typed name would outlive the folder it belonged to")

move_start = source.find("private func transferItems(")
move = source[move_start:source.find("// MARK: Keyboard", move_start)] if move_start != -1 else ""
check("a folder dragged out of the open folder leaves the grid too",
      "removeFromGridListings(movedAwayURLs)" in move,
      "photographs left the grid on a move and folders did not - the same staleness")

# Esc is not a second way of committing: it throws the typed name away, and that
# difference is the whole reason it is still there.
cancel_start = source.find("private func cancelGridRename() {")
cancel = source[cancel_start:source.find("private func commitGridRename(", cancel_start)] if cancel_start != -1 else ""
check("Esc still throws the typed name away rather than keeping it",
      "renameFolder" not in cancel and "gridRenamingFolderURL = nil" in cancel
      and ".onExitCommand { cancelGridRename() }" in source
      and ".onExitCommand { cancelRename() }" in source,
      "Esc and clicking away would do the same thing, and one of them has to undo")

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
