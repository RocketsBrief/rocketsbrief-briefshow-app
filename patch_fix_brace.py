from pathlib import Path

path = Path("BriefShow/ContentView.swift")
src = path.read_text()

old = """                }
            }
                ImaginationDustOverlay()
                    .zIndex(50)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)"""
new = """                }

                ImaginationDustOverlay()
                    .zIndex(50)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)"""

count = src.count(old)
if count != 1:
    print(f"FAIL: found {count} occurrences, expected 1. No changes written.")
else:
    path.write_text(src.replace(old, new, 1))
    print("=== PATCH APPLIED SUCCESSFULLY ===")
