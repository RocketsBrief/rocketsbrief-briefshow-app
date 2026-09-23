// Runs BriefContact's own models on a still frame, outside the browser, and
// prints what each search tile sees — so "why didn't it catch the phone?" can
// be answered from the frame itself. See BRIEFCONTACT_NOTES.md for setup.
//
//     node model-test.mjs frame.png [frame2.png ...]
//
// `isRealFace` is read out of index.html every run (BC_PAGE overrides where),
// so this measures the rule the page actually ships, not a copy of it.
import * as tf from "@tensorflow/tfjs";
import * as coco from "@tensorflow-models/coco-ssd";
import * as fd from "@tensorflow-models/face-detection";
import * as pd from "@tensorflow-models/pose-detection";
import { PNG } from "pngjs";
import fs from "fs";
import os from "os";

const page = process.env.BC_PAGE || os.homedir() + "/Desktop/BriefShow/BriefShow/BriefContact/index.html";
const html = fs.readFileSync(page, "utf8");
const start = html.indexOf("function isRealFace(f) {");
const isRealFace = new Function(html.slice(start, html.indexOf("\n}\n", start) + 2) + "\nreturn isRealFace;")();

await tf.setBackend("cpu");
await tf.ready();

function load(file) {
  const png = PNG.sync.read(fs.readFileSync(file));
  return tf.tensor3d(png.data, [png.height, png.width, 4], "int32").slice([0, 0, 0], [-1, -1, 3]);
}

const phones = await coco.load({ base: "mobilenet_v2" });
const faces = await fd.createDetector(fd.SupportedModels.MediaPipeFaceDetector,
  { runtime: "tfjs", modelType: "short", maxFaces: 3 });
const poser = await pd.createDetector(pd.SupportedModels.MoveNet,
  { modelType: pd.movenet.modelType.SINGLEPOSE_LIGHTNING });

for (const file of process.argv.slice(2)) {
  const img = load(file);
  const [H, W] = img.shape;
  const cw = Math.round(W * 0.6), ch = Math.round(H * 0.6), hw = Math.round(W * 0.5), bt = Math.round(H * 0.45);
  // The same tiles, in the same order, as the page's worker.
  const tiles = {
    whole: [0, 0, W, H],
    "bottom-left": [0, H - ch, cw, ch], "bottom-right": [W - cw, H - ch, cw, ch],
    "top-left": [0, 0, cw, ch], "top-right": [W - cw, 0, cw, ch],
    "left half": [0, 0, hw, H], "right half": [W - hw, 0, hw, H],
    "bottom half": [0, bt, W, H - bt],
  };
  console.log(`\n== ${file}  ${W}x${H}`);
  for (const [name, [x, y, w, h]] of Object.entries(tiles)) {
    const found = await phones.detect(tf.slice(img, [y, x, 0], [h, w, 3]), 20, 0.02);
    const phone = found.filter((p) => p.class === "cell phone" || p.class === "remote");
    console.log(`  ${name.padEnd(13)} phone ${phone.length ? phone.map((p) => p.class + " " + p.score.toFixed(2)).join(", ") : "—"}`
      + `   (top: ${found.slice(0, 3).map((p) => p.class + " " + p.score.toFixed(2)).join(", ")})`);
  }
  const seen = await faces.estimateFaces(img);
  console.log(`  faces found ${seen.length}, real ${seen.filter(isRealFace).length}`);
  const pose = await poser.estimatePoses(img);
  if (pose[0]) {
    console.log("  pose " + pose[0].keypoints.filter((p) => p.score >= 0.3)
      .map((p) => `${p.name} ${p.score.toFixed(2)}@${Math.round(p.y / H * 100)}%`).join("  "));
  }
}
