# BriefShow Develop — status i plan

Beleška za nastavak rada. Poslednja izmena: 9. avgust 2026.

## Šta je Develop

Nov, potpuno odvojen ekran unutar **istog** BriefShow.app-a (nije poseban Xcode
projekat, nije poseban proizvod — samo "Develop" unutar BriefShow-a) —
Lightroom-style non-destructive editor za pojedinačne fotografije. Ne dira
ShowGrid (grid/loupe/rating) niti Kousei/Kirigami/Origami slideshow — edit koji
napraviš ovde nikad ne menja originalni fajl na disku i nikad ne utiče na
slideshow/export koji BriefShow već pravi.

- Otvara se preko dugmeta **"Develop"** u ShowGrid header-u (pored "Slideshow").
- Sav kod je u novom fajlu **`BriefShow/Develop.swift`** (glavni tipovi:
  `DevelopView`, `DevelopWindowController`) — Xcode projekat koristi "file
  system synchronized groups" pa se automatski uključuje u build, nije
  trebalo dirati `.xcodeproj`.
- U `ContentView.swift` su dodate samo: dugme "Develop" u header-u, i
  `makeShowGridThumbnail(...)` promenjena iz `private` u internal (da je
  Develop-ov filmstrip može ponovo koristiti bez duplog koda).

## Šta je gotovo (Faza 1)

- **Filmstrip** levo — sve fotke iz otvorenog foldera, klik menja koju
  editovanu fotku gledaš; foto sa postojećim edit-om ima mali badge.
- **Live preview** u sredini — GPU-ubrzano preko Core Image/Metal, radi na
  downsample-ovanoj (1600px) verziji dok vučeš slajdere da bude glatko;
  pun kvalitet se koristi samo za export.
- **RAW podrška** — CR2/CR3/NEF/ARW/DNG/RAF/ORF/RW2/PEF/SRW se dekodiraju
  kroz pravi RAW develop (`CIRAWFilter`), ne preko ugrađenog JPEG preview-a.
- **Basic paneli**:
  - *Light*: Exposure, Contrast, Highlights, Shadows
  - *Color*: Temperature, Tint, Saturation, Vibrance
  - *Detail & Effects*: Sharpness, Vignette
- **Crop & Rotate**: rotate 90° levo/desno, Straighten slajder (-45°...45°),
  crop alat sa 4 ugla za resize + drag za pomeranje.
- **Before/After** — drži dugme da vidiš originalnu (needitovanu) sliku.
- **Non-destructive** — edit se čuva po fotki u `UserDefaults` preko
  `PhotoEditStore` (ista `filename|filesize` logika kao `PhotoLabelStore` za
  like/rating — prati fotku kroz move/rename unutar BriefShow-a). "Reset
  All" vraća sve na neutralno.
- **Export Edited Copy** — Save panel, snima nov JPEG sa primenjenim
  izmenama; original nikad nije diran.

## Poznata ograničenja / stvari koje nisu urađene

- Nema **Whites/Blacks** ni **tone curve** — samo Highlights/Shadows preko
  `CIHighlightShadowAdjust`, nema pravu krivu.
- Nema **histogram**.
- Nema **presets** (sačuvaj/primeni isti "look" na više fotki odjednom),
  ni copy/paste podešavanja između fotki.
- Nema **maske / lokalni adjustment** (radial, graduated, brush) — to je
  najveći posao od svega što nedostaje, realno je "Faza 3+".
- Nema pravi **healing/clone brush**.
- **Straighten** posle rotacije trenutno ne radi automatski re-crop —
  posle jačeg straighten-a mogu se videti "prazni" uglovi dok ručno ne
  podesiš crop. Trebalo bi dodati auto-fit crop posle straighten-a.
- RAW edit trenutno ide kroz isti pipeline kao JPEG (`CIRAWFilter` samo
  dekoduje pa se isti Exposure/Contrast/... filteri primenjuju odozgo) —
  nije "prava" RAW obrada gde se expozicija radi tokom samog demosaic-a
  (`CIRAWFilter` ima svoje native `exposure`/`boostAmount`/`neutralTemperature`
  property-je koje trenutno ne koristimo).
- Export je samo **JPEG**; nema PNG/HEIC/TIFF opciju, nema izbor kvaliteta
  u UI-ju (fiksno 0.92 compression).
- Nema keyboard shortcuts u Develop prozoru (npr. "\\" za before/after kao
  u pravom Lightroom-u).
- Build je testiran (`xcodebuild` prolazi čisto), ali ekran **nije vizuelno
  proveren u pravoj app-i** — sledeći put prvo pokrenuti i provideti da
  crop/rotate/sliders rade kako treba na realnim fotkama (i JPEG i RAW).

## Šta dalje (predlog redosleda za Fazu 2)

1. Vizuelna provera Develop ekrana u pokrenutoj app-i (sliders, crop, RAW).
2. Whites / Blacks (verovatno preko tone curve pristupa umesto zasebnih
   filtera, da se sve — Highlights/Shadows/Whites/Blacks — svede na jednu
   `CIToneCurve` sa pomerenim tačkama).
3. Histogram u adjustment panelu.
4. Auto-fit crop posle straighten-a (da nema praznih uglova).
5. Presets + copy/paste settings između fotki.
6. Iskoristiti native RAW kontrole (`CIRAWFilter.exposure`,
   `.neutralTemperature`, `.neutralTint`, `.boostAmount`) umesto generičkog
   pipeline-a za RAW fajlove — bolji kvalitet.
7. Lokalni adjustment (maske) — najveći zalogaj, ostaviti za kraj.

## Vezano

- Odluke iz razgovora: ostaje **u istom** Xcode projektu/app-u kao BriefShow
  (ne poseban `.app`, ne poseban proizvod — nema "BriefEdits" brendiranje,
  samo "Develop" unutar BriefShow-a), standalone je (ne dira grid ni
  slideshow), podržava i RAW.
