// Harness for the lock that keeps the client on ONE photograph while a model
// works on it.
//
// ⚠️ `isAIWorkingOnOpenPhoto` is EXTRACTED FROM Develop.swift at build time by
// run-ai-photo-lock-test.py, rewritten from a View property into a function of
// the four flags it reads. Only the flags are declared here, and if the
// property starts reading a fifth the extraction will not compile — which is
// the point: a new busy state that nobody wired into the lock is exactly the
// hole this test exists to find.
//
// What it has to prove:
//   1. every single-photo AI job locks, and each one on its own,
//   2. a BULK bake does NOT lock — switching photos there is deliberate,
//   3. nothing locks when nothing is running.

import Foundation

var isRemoving = false
var isFindingPeople = false
var isFlatteningOpenPhoto = false
var runningRecipe: String?

// __EXTRACTED__

var failures = 0

func check(_ label: String, _ condition: Bool) {
    if condition { print("  ok    \(label)") }
    else { failures += 1; print("  FAIL  \(label)") }
}

func reset() {
    isRemoving = false
    isFindingPeople = false
    isFlatteningOpenPhoto = false
    runningRecipe = nil
}

print("the lock, one flag at a time")

reset()
check("nothing running → the strip is live", isAIWorkingOnOpenPhoto == false)

reset(); isRemoving = true
check("AI Clean Up (Quick and Generative) locks", isAIWorkingOnOpenPhoto)

reset(); isFindingPeople = true
check("Select People locks", isAIWorkingOnOpenPhoto)

reset(); isFlatteningOpenPhoto = true
check("the open photo's own Flatten locks", isAIWorkingOnOpenPhoto)

for recipe in ["Youthify", "Subject Mono", "Mono Background"] {
    reset(); runningRecipe = recipe
    check("\(recipe) locks", isAIWorkingOnOpenPhoto)
}

print("\nthe bulk bakes, which must NOT lock")

// runBake and runPortraitRecipes raise `isFlattening` and nothing else. The
// harness cannot see that flag at all — that is the proof: if the lock ever
// starts reading it, this file stops compiling and the failure is loud.
reset()
check("a selection baking in the background leaves the strip live",
      isAIWorkingOnOpenPhoto == false)

print("\nthe whole chain a recipe runs, step by step")

// Youthify = Select People → the numbers → Flatten, all under one runningRecipe.
// The lock must hold across every step, including the handover between them,
// where the inner flags go up and down.
reset(); runningRecipe = "Youthify"; isFindingPeople = true
check("step 1, looking for people", isAIWorkingOnOpenPhoto)
isFindingPeople = false
check("between steps, only runningRecipe left up", isAIWorkingOnOpenPhoto)
isFlatteningOpenPhoto = true
check("step 3, flattening", isAIWorkingOnOpenPhoto)
isFlatteningOpenPhoto = false; runningRecipe = nil
check("done → the strip comes back", isAIWorkingOnOpenPhoto == false)

print(failures == 0 ? "\nall good" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
