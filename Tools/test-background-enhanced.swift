// "Background Enhanced": does it put the client's three numbers on the
// BACKGROUND, and does it leave the people alone?
//
// Asked for by name on 12.09: right-click a selection, Select People on every
// one, then *„select layer backround, and edit like this: Shadows -100,
// situration plus 30, Clarity plus 30"*, then Flatten.
//
// Run against the real `PortraitRecipe` out of the app's own sources, not a
// re-reading of it — the numbers are the client's and a test that carries its
// own copy of them would agree with itself while the app drifted.
//
//     background-enhanced
import Foundation
import CoreImage

var failures = 0

func check(_ label: String, _ passed: Bool, _ detail: String = "") {
    if passed {
        print("  ok    \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)\(detail.isEmpty ? "" : "   \(detail)")")
    }
}

func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

// The two layers Select People makes: Background is a matte over the photo,
// People is a cut-out with pixels of its own. Only `maskData` tells them apart,
// and `applied` finds each by id — so both are built the way the factory builds
// them rather than as two interchangeable blanks.
let backgroundLayer = ImageLayer(name: "Background", imageData: Data(),
                                 x: 0, y: 0, width: 1, height: 1,
                                 maskData: Data([0x00]))
let peopleLayer = ImageLayer(name: "People", imageData: Data([0x01]),
                             x: 0.25, y: 0.1, width: 0.5, height: 0.8)

var settings = PhotoEditSettings()
settings.layers = [backgroundLayer, peopleLayer]

func applyRecipe(_ recipe: PortraitRecipe) -> PhotoEditSettings {
    recipe.applied(to: settings, backgroundID: backgroundLayer.id, peopleID: peopleLayer.id)
}

func layer(_ result: PhotoEditSettings, _ id: UUID) -> ImageLayer? {
    result.layers.first { $0.id == id }
}

print("\nthe three numbers, on the layer the client named")
let enhanced = applyRecipe(.backgroundEnhanced)
guard let background = layer(enhanced, backgroundLayer.id),
      let people = layer(enhanced, peopleLayer.id) else {
    print("  FAIL  the recipe lost one of the two layers")
    exit(1)
}

// ⚠️ −100/+30/+30 on the panel, which is −1.0/+0.30/+0.30 stored: every slider
// in this app reads out as value × 100. A test that accepted 30.0 would pass
// while the client's background went thirty times too far.
check("Shadows −100", close(background.adjustments.shadows, -1),
      "got \(background.adjustments.shadows)")
check("Saturation +30", close(background.adjustments.saturation, 0.30),
      "got \(background.adjustments.saturation)")
check("Clarity +30", close(background.adjustments.clarity, 0.30),
      "got \(background.adjustments.clarity)")

// Negative Shadows is the DARKENING direction (see PhotoEditSettings.shadows).
// The sign is the whole difference between what was asked for and its opposite,
// and nothing else in this file would catch it flipping.
check("Shadows darkens rather than lifts", background.adjustments.shadows < 0)

print("\nand nothing else moves")
check("the people are untouched", people.adjustments.isNeutral)
check("nothing landed on the photo itself",
      enhanced.shadows == 0 && enhanced.saturation == 0 && enhanced.clarity == 0)
check("Contrast is not touched", close(background.adjustments.contrast, 0))
check("the background is still a matte, not pixels", background.isDerived)
check("both layers are still there", enhanced.layers.count == 2)

print("\nit says which layer it writes on, and means it")
check("targetLayerName is Background", PortraitRecipe.backgroundEnhanced.targetLayerName == "Background")
check("writesOnBackground", PortraitRecipe.backgroundEnhanced.writesOnBackground)
check("it is offered in the UI", PortraitRecipe.allCases.contains(.backgroundEnhanced))
check("its title is the client's name for it",
      PortraitRecipe.backgroundEnhanced.title == "Background Enhanced")
// The help string is what the Sync dialog and the grid's tooltip show, and it
// is the only place a client is told what the button does before pressing it.
let help = PortraitRecipe.backgroundEnhanced.help
check("the help spells out all three numbers and the flatten",
      help.contains("Shadows") && help.contains("Saturation") && help.contains("Clarity")
        && help.contains("30") && help.contains("Flatten"),
      help)

// ⚠️ REGRESSION GUARD, and it is the reason this file tests the other three at
// all. `applied` used to choose its layer with `self == .monoBackground`;
// adding a second background recipe meant that had to become a property, and
// getting it wrong would have sent Background Enhanced onto the PEOPLE — or,
// worse and more quietly, sent Mono Background there.
print("\nthe three recipes that were already here still land where they did")
let youthify = applyRecipe(.youthify)
check("Youthify → the people, Texture −60",
      close(layer(youthify, peopleLayer.id)?.adjustments.texture ?? 0, -0.60)
        && layer(youthify, backgroundLayer.id)?.adjustments.isNeutral == true)

let subjectMono = applyRecipe(.subjectMono)
check("Subject Mono → the people, B&W and Contrast +30",
      close(layer(subjectMono, peopleLayer.id)?.adjustments.saturation ?? 0, -1)
        && close(layer(subjectMono, peopleLayer.id)?.adjustments.contrast ?? 0, 0.30)
        && layer(subjectMono, backgroundLayer.id)?.adjustments.isNeutral == true)

let monoBackground = applyRecipe(.monoBackground)
check("Mono Background → the background, B&W and Contrast +40",
      close(layer(monoBackground, backgroundLayer.id)?.adjustments.saturation ?? 0, -1)
        && close(layer(monoBackground, backgroundLayer.id)?.adjustments.contrast ?? 0, 0.40)
        && layer(monoBackground, peopleLayer.id)?.adjustments.isNeutral == true)

check("only Mono Background and Background Enhanced write on the background",
      PortraitRecipe.allCases.filter(\.writesOnBackground) == [.monoBackground, .backgroundEnhanced])

// Two recipes ticked together in the Sync dialog fold over one photo in a row,
// which is the only reason `applied` takes and returns the whole record.
print("\ntwo at once still stack, one on each layer")
let both = PortraitRecipe.backgroundEnhanced.applied(
    to: PortraitRecipe.youthify.applied(to: settings,
                                        backgroundID: backgroundLayer.id,
                                        peopleID: peopleLayer.id),
    backgroundID: backgroundLayer.id, peopleID: peopleLayer.id)
check("Youthify kept on the people",
      close(layer(both, peopleLayer.id)?.adjustments.texture ?? 0, -0.60))
check("Background Enhanced kept on the background",
      close(layer(both, backgroundLayer.id)?.adjustments.shadows ?? 0, -1)
        && close(layer(both, backgroundLayer.id)?.adjustments.clarity ?? 0, 0.30))

print()
if failures == 0 {
    print("all good")
    exit(0)
}
print("\(failures) checks failed")
exit(1)
