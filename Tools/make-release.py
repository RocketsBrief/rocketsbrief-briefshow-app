#!/usr/bin/env python3
"""Builds and packages a C4S Suite release — both packages — and checks them.

    python3 Tools/make-release.py 11.7 [--skip-build]

Two packages, and that is the answer to the client's own note rather than a
preference (KORAK 116). Everyone who already has C4S installed gets an update
that does not make them re-download 2 GB of weights they already have; a new
client gets one file with everything in it:

    C4S-Suite-<v>.zip             ~115 MB   existing installs
    C4S-Suite-<v>-AI-Models.zip   ~2.09 GB  new clients, all in one

⚠️ THE MODEL NEVER GOES THROUGH XCODE. BriefShow/BriefShow/ is a synchronized
group: anything dropped there enters the bundle AND git, and GitHub refuses a
file over 100 MB — the UNet alone is 1,641 MB. So the big package is made by
copying SD15-Inpainting into Contents/Resources of a COPY of the built app and
re-signing it, which is why SDModelStore looks at Bundle.main.resourceURL at run
time instead of Bundle.main.url(forResource:).

⚠️ -destination "generic/platform=macOS" is load-bearing. Without it xcodebuild
quietly narrows to the building machine's own architecture and the "universal"
package ships arm64 only (the trap of KORAK 108).

⚠️ GitHub's asset limit is 2 GiB and the big package is within ~60 MB of it. The
script fails rather than uploading something that will be rejected.

Every check in KORAK 116's table runs here, on the PACKAGES, not on the project.
"""
import argparse
import pathlib
import plistlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP_NAME = "C4S Suite.app"
BINARY_NAME = "C4S Suite"
BUNDLE_ID = "com.rocketsbrief.BriefShow"
MIN_OS = "13.0"
GITHUB_ASSET_LIMIT = 2 * 1024 ** 3
# Weights live beside the checkout and are not in git — see Tools/README.txt.
MODELS = ROOT.parent / "CoreMLModels" / "SD15-Inpainting"
SD_PARTS = ["TextEncoder.mlmodelc", "Unet.mlmodelc", "VAEDecoder.mlmodelc", "VAEEncoder.mlmodelc"]
PHOTO_SUFFIXES = {".jpg", ".jpeg", ".nef", ".cr2", ".cr3", ".arw", ".heic", ".dng"}


def run(args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, **kwargs)


def fail(message):
    print(f"\n✗ {message}")
    sys.exit(1)


def build(derived: pathlib.Path) -> pathlib.Path:
    print("building (universal, generic/platform=macOS)…")
    result = run(["xcodebuild", "-project", str(ROOT / "BriefShow.xcodeproj"),
                  "-scheme", "BriefShow", "-configuration", "Release",
                  "-destination", "generic/platform=macOS",
                  "-derivedDataPath", str(derived), "build"])
    if "** BUILD SUCCEEDED **" not in result.stdout:
        print(result.stdout[-3000:] + result.stderr[-2000:])
        fail("build failed")
    app = derived / "Build" / "Products" / "Release" / APP_NAME
    if not app.exists():
        fail(f"built, but {app} is not there")
    return app


def checks(app: pathlib.Path, version: str, expect_sd: bool) -> dict:
    out = {}
    archs = run(["lipo", "-archs", str(app / "Contents" / "MacOS" / BINARY_NAME)]).stdout.split()
    out["lipo -archs"] = " ".join(sorted(archs))

    plist = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
    out["LSMinimumSystemVersion"] = plist.get("LSMinimumSystemVersion", "—")
    out["version / build"] = f'{plist.get("CFBundleShortVersionString")} / {plist.get("CFBundleVersion")}'
    out["CFBundleIdentifier"] = plist.get("CFBundleIdentifier", "—")

    resources = app / "Contents" / "Resources"
    out["LaMa.mlmodelc"] = "yes" if (resources / "LaMa.mlmodelc").exists() else "NO"

    # The same test SDModelStore.isComplete makes, run on the package rather
    # than assumed from the fact that a copy was issued.
    sd = resources / "SD15-Inpainting"
    complete = sd.is_dir() and all((sd / part).exists() for part in SD_PARTS)
    out["SD15-Inpainting (isComplete)"] = "YES" if complete else "no"

    # ⚠️ Nothing personal ships. Checked every release, never assumed — the
    # rule and the reason are in the locked section of the notes.
    photos = [p for p in app.rglob("*") if p.suffix.lower() in PHOTO_SUFFIXES]
    out["personal photographs"] = str(len(photos))

    signed = run(["codesign", "-v", "--strict", str(app)])
    out["codesign -v"] = "ok" if signed.returncode == 0 else f"FAILED: {signed.stderr.strip()[:80]}"

    problems = []
    if out["lipo -archs"] != "arm64 x86_64":
        problems.append(f'not universal: {out["lipo -archs"]}')
    if str(out["LSMinimumSystemVersion"]) != MIN_OS:
        problems.append(f'minimum macOS is {out["LSMinimumSystemVersion"]}, not {MIN_OS}')
    if not out["version / build"].startswith(version + " /"):
        problems.append(f'bundle says {out["version / build"]}, not {version}')
    if out["CFBundleIdentifier"] != BUNDLE_ID:
        problems.append(f'bundle id is {out["CFBundleIdentifier"]}')
    if out["LaMa.mlmodelc"] != "yes":
        problems.append("LaMa is missing")
    if expect_sd and not complete:
        problems.append("SD15-Inpainting is missing or incomplete in the package")
    if not expect_sd and complete:
        problems.append("the update package carries SD — that is the 2 GB nobody asked to re-download")
    if photos:
        problems.append(f"personal photographs in the bundle: {photos[:3]}")
    if out["codesign -v"] != "ok":
        problems.append(out["codesign -v"])
    return out, problems


def with_models(app: pathlib.Path, work: pathlib.Path) -> pathlib.Path:
    """A copy of the app with SD inside it, re-signed so it still launches."""
    if not MODELS.is_dir():
        fail(f"weights not found at {MODELS} — see Tools/README.txt")

    big = work / APP_NAME
    if big.exists():
        shutil.rmtree(big)
    print("copying the app…")
    shutil.copytree(app, big, symlinks=True)

    print(f"copying SD15-Inpainting ({sum(f.stat().st_size for f in MODELS.rglob('*') if f.is_file()) / 1e9:.2f} GB)…")
    shutil.copytree(MODELS, big / "Contents" / "Resources" / "SD15-Inpainting", symlinks=True)

    # The entitlements come OUT of the built app rather than being retyped:
    # signing with a guess at them is how a package launches here and refuses
    # to launch on the client's machine.
    entitlements = run(["codesign", "-d", "--entitlements", ":-", "--xml", str(app)])
    plist = work / "entitlements.plist"
    if entitlements.returncode == 0 and entitlements.stdout.strip():
        plist.write_text(entitlements.stdout)
        sign = ["codesign", "--force", "--deep", "--sign", "-",
                "--entitlements", str(plist), str(big)]
    else:
        print("  (the built app carries no entitlements — signing without)")
        sign = ["codesign", "--force", "--deep", "--sign", "-", str(big)]

    print("re-signing…")
    result = run(sign)
    if result.returncode != 0:
        fail(f"re-signing failed: {result.stderr[-500:]}")
    return big


def zip_app(app: pathlib.Path, destination: pathlib.Path) -> int:
    if destination.exists():
        destination.unlink()
    print(f"zipping {destination.name}…")
    result = run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                  str(app), str(destination)])
    if result.returncode != 0:
        fail(f"zip failed: {result.stderr[-400:]}")
    return destination.stat().st_size


def table(title: str, rows: dict, size: int):
    print(f"\n  {title}")
    for key, value in rows.items():
        print(f"    {key:<30} {value}")
    print(f"    {'zip':<30} {size:,} bytes ({size / 1e9:.2f} GB)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("version")
    parser.add_argument("--skip-build", action="store_true",
                        help="reuse build_universal/ instead of building again")
    parser.add_argument("--small-only", action="store_true",
                        help="build ONLY the ~115 MB update package, not the "
                             "2 GB all-in-one. Use when the weights already on "
                             "GitHub are still current and the in-app SD "
                             "download can serve new clients from there.")
    parser.add_argument("--out", default="dist-universal")
    args = parser.parse_args()

    derived = ROOT / "build_universal"
    out = ROOT / args.out
    out.mkdir(exist_ok=True)

    if args.skip_build:
        app = derived / "Build" / "Products" / "Release" / APP_NAME
        if not app.exists():
            fail(f"--skip-build, but {app} is not there")
        print(f"reusing {app}")
    else:
        app = build(derived)

    small_rows, small_problems = checks(app, args.version, expect_sd=False)
    small_zip = out / f"C4S-Suite-{args.version}.zip"
    small_size = zip_app(app, small_zip)

    if args.small_only:
        # ⚠️ Every check still runs — this skips the second PACKAGE, never the
        # checking of the first one.
        table(f"{small_zip.name}  — every install", small_rows, small_size)
        if small_problems:
            print()
            for p in small_problems:
                print(f"  ✗ update package: {p}")
            fail(f"{len(small_problems)} problem(s) — nothing here is ready to publish")
        print("\nRESULT: OK — the update package is built and checked")
        print(f"  {small_zip}")
        print("\n  ⚠️ No all-in-one package was made, so a NEW client installs "
              "this and\n     then presses the app's own SD download button, "
              "which points at the\n     v11.0 asset. That release must not be "
              "deleted.")
        return 0

    work = ROOT / "build_universal" / "with-models"
    work.mkdir(parents=True, exist_ok=True)
    big_app = with_models(app, work)
    big_rows, big_problems = checks(big_app, args.version, expect_sd=True)
    big_zip = out / f"C4S-Suite-{args.version}-AI-Models.zip"
    big_size = zip_app(big_app, big_zip)

    table(f"{small_zip.name}  — existing installs", small_rows, small_size)
    table(f"{big_zip.name}  — new clients", big_rows, big_size)

    headroom = GITHUB_ASSET_LIMIT - big_size
    print(f"\n  GitHub's 2 GiB asset limit: {headroom / 1e6:.0f} MB of headroom left")
    if headroom <= 0:
        big_problems.append("the big package is OVER GitHub's 2 GiB asset limit")

    problems = [f"update package: {p}" for p in small_problems] + \
               [f"all-in-one package: {p}" for p in big_problems]
    if problems:
        print()
        for p in problems:
            print(f"  ✗ {p}")
        fail(f"{len(problems)} problem(s) — nothing here is ready to publish")

    print("\nRESULT: OK — both packages built and checked")
    print(f"  {small_zip}")
    print(f"  {big_zip}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
