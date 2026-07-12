import re
from pathlib import Path

path = Path("BriefShow/ContentView.swift")
src = path.read_text()

def replace_call(text, marker_context_before):
    # find all occurrences of ImaginationCardPage( ... ) call and replace args
    pattern = re.compile(r"ImaginationCardPage\(\s*activeImage:\s*activePreviewImage,\s*previousImage:\s*previousPreviewImage,\s*transitionProgress:\s*transitionProgress\s*\)")
    matches = list(pattern.finditer(text))
    return matches

matches = replace_call(src, None)
print(f"Found {len(matches)} ImaginationCardPage call site(s) to update")

new_call = "ImaginationCardPage(\n                        activeImage: activePreviewImage,\n                        activePhotoIndex: activePhotoIndex,\n                        transitionProgress: transitionProgress\n                    )"

if len(matches) == 0:
    print("FAIL: no call sites matched expected pattern. No changes written.")
else:
    pattern = re.compile(r"ImaginationCardPage\(\s*activeImage:\s*activePreviewImage,\s*previousImage:\s*previousPreviewImage,\s*transitionProgress:\s*transitionProgress\s*\)")
    new_src = pattern.sub(new_call, src)
    path.write_text(new_src)
    print(f"=== REPLACED {len(matches)} CALL SITE(S) SUCCESSFULLY ===")
