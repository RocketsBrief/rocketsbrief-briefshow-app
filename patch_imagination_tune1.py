from pathlib import Path

path = Path("BriefShow/ContentView.swift")
src = path.read_text()

patches = []

# 1. Vrati prasinu na manju/suptilniju velicinu (kao pre uvecanja)
old1 = """    private let particles: [(CGFloat, CGFloat, CGFloat, Double)] = (0..<55).map { _ in
        (
            CGFloat.random(in: 0...1),
            CGFloat.random(in: 0...1),
            CGFloat.random(in: 1.5...4.5),
            Double.random(in: 0.35...0.85)
        )
    }"""
new1 = """    private let particles: [(CGFloat, CGFloat, CGFloat, Double)] = (0..<30).map { _ in
        (
            CGFloat.random(in: 0...1),
            CGFloat.random(in: 0...1),
            CGFloat.random(in: 1.0...2.6),
            Double.random(in: 0.18...0.4)
        )
    }"""
patches.append(("Patch 1: revert dust to smaller/subtler size", old1, new1))

# 2. Slika kreje STVARNO van ekrana (veci offset multiplier) i nastavlja sporo da se krece (ne staje)
old2 = """                        .scaleEffect(1.32 - 0.32 * easedIncoming)
                        .scaleEffect(driftPhase ? 1.018 : 1.0)
                        .offset(
                            x: (1 - easedIncoming) * proxy.size.width * 0.4
                        )
                        .opacity(easedIncoming)
                        .position(
                            x: proxy.size.width * 0.5,
                            y: proxy.size.height * 0.5
                        )
                }"""
new2 = """                        .scaleEffect(1.32 - 0.32 * easedIncoming)
                        .scaleEffect(driftPhase ? 1.02 : 1.0)
                        .offset(
                            x: (1 - easedIncoming) * proxy.size.width * 1.15
                                + (driftPhase ? -14 : 14),
                            y: driftPhase ? -8 : 8
                        )
                        .rotationEffect(
                            .degrees((1 - easedIncoming) * -8)
                        )
                        .opacity(easedIncoming)
                        .position(
                            x: proxy.size.width * 0.5,
                            y: proxy.size.height * 0.5
                        )
                }"""
patches.append(("Patch 2: image starts fully off-screen + keeps slowly drifting after arrival", old2, new2))

# 3. Produzi trajanje drift animacije da bude jos sporija/suptilnija posle sletanja
old3 = """            .onAppear {
                withAnimation(
                    .easeInOut(duration: 7)
                        .repeatForever(autoreverses: true)
                ) {
                    driftPhase = true
                }
            }
        }
    }
}"""
new3 = """            .onAppear {
                withAnimation(
                    .easeInOut(duration: 10)
                        .repeatForever(autoreverses: true)
                ) {
                    driftPhase = true
                }
            }
        }
    }
}"""
patches.append(("Patch 3: slower continuous drift", old3, new3))

report = []
for label, old, new in patches:
    c = src.count(old)
    report.append(f"{'OK' if c==1 else 'FAIL'} [{label}]: {c} occurrence(s)")

print("\n".join(report))
fails = [r for r in report if r.startswith("FAIL")]

if fails:
    print(f"\nABORTED - {len(fails)} failed. No changes written.")
else:
    for label, old, new in patches:
        src = src.replace(old, new, 1)
    path.write_text(src)
    print("\n=== ALL APPLIED SUCCESSFULLY ===")
