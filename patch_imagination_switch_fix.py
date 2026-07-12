from pathlib import Path

path = Path("BriefShow/ContentView.swift")
src = path.read_text()

old = """        case .origamiToon:
            return "Origami Toon will require sign in and credits once AI styles are connected."
        }
    }"""
new = """        case .origamiToon:
            return "Origami Toon will require sign in and credits once AI styles are connected."
        case .imagination:
            return "Imagination brings photos to life as 3D cards emerging from deep space."
        }
    }"""

count = src.count(old)
if count != 1:
    print(f"FAIL: found {count} occurrences, expected 1. No changes written.")
else:
    path.write_text(src.replace(old, new, 1))
    print("=== PATCH APPLIED SUCCESSFULLY ===")
