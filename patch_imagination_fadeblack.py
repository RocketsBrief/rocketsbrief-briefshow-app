import re
from pathlib import Path

path = Path("BriefShow/ContentView.swift")
lines = path.read_text().splitlines(keepends=True)

def find_struct_span(struct_name):
    start = None
    for i, line in enumerate(lines):
        if re.match(rf"^struct {struct_name}\b", line):
            start = i
            break
    if start is None:
        return None, None
    depth = 0
    started = False
    for i in range(start, len(lines)):
        for ch in lines[i]:
            if ch == '{':
                depth += 1
                started = True
            elif ch == '}':
                depth -= 1
        if started and depth == 0:
            return start, i
    return start, None

start, end = find_struct_span("ImaginationCardPage")
if start is None or end is None:
    print("FAIL: could not locate ImaginationCardPage struct bounds")
else:
    print(f"Found ImaginationCardPage: lines {start+1}-{end+1}")

    new_struct = '''struct ImaginationCardPage: View {
    let activeImage: NSImage?
    let activePhotoIndex: Int
    let transitionProgress: Double

    @State private var revealScale: CGFloat = 1.35
    @State private var revealBlur: CGFloat = 26
    @State private var revealOffsetX: CGFloat = 0
    @State private var sideIsRight: Bool = false
    @State private var lastSeenIndex: Int = -1

    private var blackOverlayOpacity: Double {
        let p = min(1, max(0, transitionProgress))
        return 1 - abs(1 - 2 * p)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                if let activeImage {
                    Image(nsImage: activeImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .blur(radius: revealBlur)
                        .scaleEffect(revealScale)
                        .offset(x: revealOffsetX)
                }

                ImaginationDustOverlay()
                    .zIndex(50)

                Color.black
                    .opacity(blackOverlayOpacity)
                    .allowsHitTesting(false)
                    .zIndex(100)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onAppear {
                lastSeenIndex = activePhotoIndex
                triggerReveal()
            }
            .onChange(of: activePhotoIndex) { _, newValue in
                guard newValue != lastSeenIndex else { return }
                lastSeenIndex = newValue
                triggerReveal()
            }
        }
    }

    private func triggerReveal() {
        sideIsRight.toggle()

        var resetTransaction = Transaction()
        resetTransaction.animation = nil
        withTransaction(resetTransaction) {
            revealScale = 1.35
            revealBlur = 26
            revealOffsetX = sideIsRight ? 70 : -70
        }

        withAnimation(.easeOut(duration: 6)) {
            revealScale = 1.0
            revealBlur = 0
            revealOffsetX = 0
        }
    }
}
'''

    lines[start:end+1] = [new_struct]
    path.write_text("".join(lines))
    print("=== STRUCT REPLACED SUCCESSFULLY ===")
