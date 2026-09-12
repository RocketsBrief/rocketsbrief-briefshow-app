#!/usr/bin/env python3
"""Undoing a portrait recipe: one step back, and the earlier work left alone.

    python3 Tools/run-recipe-undo-test.py

Asked for on 12.09: *„When i want to undo enhanced backround i need to be able to
do so. No to be forces to restart all settings from the image!"*

Unflatten was the only way back and it is the wrong tool — it returns to before
the FIRST bake and discards everything since. This checks the thing that
replaced it (PortraitRecipeUndoStore) on real files: the settings record, the
flattened pixels and Unflatten's own snapshot all go back together, a recipe run
on an already-baked photo gives back the EARLIER bake rather than the original,
and running a recipe twice steps back once rather than to the beginning.

Needs no photograph and no models: it writes its own throwaway file and clears
itself out of the stores afterwards.
"""
import importlib.util
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("lrcal", ROOT / "Tools" / "run-lightroom-calibration.py")
lrcal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lrcal)

with tempfile.TemporaryDirectory() as tmp:
    binary = lrcal.build(pathlib.Path(tmp), main="test-recipe-undo.swift")
    sys.exit(subprocess.call([str(binary)]))
