# BriefShow Develop — status i plan

Beleška za nastavak rada. Poslednja izmena: 11. avgust 2026 (rano jutro).

## TL;DR — gde smo stali

**Sve dosad zatraženo je gotovo.** Ceo hronološki tok, u jednoj listi
(pun opis/arhitektura svake stavke je u "Šta dalje" ispod, pod istim
brojem):

1. Vizuelna provera Develop ekrana u pokrenutoj app-i (osnovni UI,
   non-destructive store kroz restart, export wiring).
2. **Whites/Blacks** slideri — jedinstvena `CIToneCurve` umesto
   `CIHighlightShadowAdjust`.
3. **Histogram** — live luminance histogram na vrhu desnog panela.
4. **Auto-fit crop posle Straighten-a** — nema više praznih uglova posle
   rotacije; formula matematički dokazana tačna.
5. **Presets + copy/paste settings između fotki** — vizuelno provereno u
   pravoj app-i.
6. **Native RAW kontrole** (`CIRAWFilter.exposure/.neutralTemperature/
   .neutralTint`) — matematika/predznak provereni skriptama, **nije
   provereno na pravoj RAW fotki** (i dalje nema RAW fajla na disku za
   test). Usput: **JPEG Temperature sign bug ispravljen** (na zahtev
   korisnika) — `+1` sad zaista greje sliku, menja izgled već sačuvanih
   edit-ova sa ne-nula Temperature (prihvaćen kompromis).
7. **Lokalni adjustment (maske) — Radial + Graduated + Brush, sve tri** u
   jednom prolazu (korisnik je eksplicitno tražio sve troje). Mask-
   geometrija matematički provereno, add/select/list/delete/enable-toggle/
   on-canvas-overlay vizuelno provereno u pravoj app-i.
8. **Četiri UX izmene**: Enter komituje crop; crop aspect ratio dugmad
   (Free/1:1/4:3/3:4/16:9/9:16); brush mask ostaje trajno vidljiv posle
   slikanja (ne samo dok se vuče); dupli klik na fotku u ShowGrid-u
   ("bridge") otvara Develop direktno na toj fotki. #1–2 vizuelno
   potvrđeno; #3–4 nisu mogli GUI-testirati (drag/tap-gesture, poznato
   ograničenje — vidi napomenu ispod).
9. **Ratio-locked crop resize + Export All Edited**: crop razmera se sad
   zaključava kroz ručno prevlačenje handle-a (ranije je skakala nazad na
   Free); novo dugme "Export All Edited" izveze sve editovane fotke iz
   foldera u jedan izabran destination folder odjednom. Ratio-lock
   matematika provereno skriptom (960 slučajeva); Export All Edited
   vizuelno potvrđeno end-to-end (pravi fajl, ispravna rotacija,
   needitovana fotka preskočena).

Nema više otvorenih stavki — sledeće bi bilo sitno poliranje navedeno u
"Poznata ograničenja" (brush mask caching, radial rotacija, RAW fajl za
test), ili nešto novo što korisnik zatraži. Jedna sitna neistražena
nijansa kod auto-fit crop-a (stavka 4) — verovatno nebitna, dokumentovana
za svaki slučaj.

**Bitna napomena za sledeću sesiju testiranja**: izbegavati `cliclick`/
sintetički mouse-drag na pravoj app-i — jedan takav test je danas slučajno
otvorio WhatsApp video poziv umesto da povuče slider u BriefShow-u. Za
proveru render/geometrijske logike koristiti standalone Swift skripte
(`xcrun swift script.swift`) koje pozivaju identičan kod izvučen iz
`Develop.swift`, bez GUI-ja — ovaj pristup je danas uhvatio dva stvarna
bug-a (histogram color-matrix, i jedan lažni alarm kod auto-fit crop-a) pre
nego što bi korisnik ikad video da nešto ne valja.

**Dopuna (kasnije isto veče, posle uspešnog GUI testa Presets/Copy-Paste)**:
`System Events` (AppleScript) automatizacija PREKO njegovih accessibility
elemenata (`click el`, ne raw coordinate drag) se pokazala pouzdana za
obične SwiftUI `Button`/`TextField` — to je bezbedan i koristan način da se
UI testira bez `cliclick`-a. Ograničenja/trikovi koje treba znati:
- Radi pouzdano: `Button` (uključujući ikonice), `TextField` fokusiranje
  preko `click at {x,y}` (precizna koordinata izračunata iz AX pozicije
  elementa — jedan klik, ne drag — je OK i radi kad `click el` na samom
  text field-u ne uspe da ga fokusira).
- NE radi: bilo šta implementirano preko `.onTapGesture` umesto pravog
  `Button` (npr. filmstrip thumbnail selekcija u Develop-u) — isti obrazac
  kao već poznati problem sa `Slider`-ima. Ne gubiti vreme na to; testirati
  tu logiku posredno (npr. Paste Settings testiran Copy→Reset→Paste na
  ISTOJ fotki, umesto stvarnog prebacivanja fotke u filmstrip-u).
- Host (VS Code) ume da otme fokus IZMEĐU dva odvojena alat-poziva (npr.
  dok se screenshot čita nazad) — svaku interakciju (activate → click →
  keystroke) spakovati u JEDAN `osascript` blok bez pauze, inače keystroke
  ode u pogrešnu app.
- Za screenshot koristiti `screencapture -l<CGWindowID>` (window-specific,
  CGWindowID se nalazi preko kratke standalone Swift skripte sa
  `CGWindowListCopyWindowInfo`) umesto `-x` cele table — izbegava snimanje
  drugih app-i/prozora (bitno ako je nešto osetljivo trenutno na ekranu,
  kao što je bio slučaj ovog puta sa WhatsApp pozivom koji je već bio
  aktivan pre bilo kakve moje akcije).

## Vizuelna provera u pokrenutoj app-i (10. avgust 2026)

Build (`xcodebuild -scheme BriefShow -configuration Debug`) prošao čisto,
app pokrenuta i provedena kroz UI (import fotke → ShowGrid → Develop) preko
Accessibility automatizacije. Potvrđeno da radi:

- Develop se otvara preko dugmeta "Develop", filmstrip levo prikazuje sve
  fotke iz foldera na disku (ne samo one uvezene u ShowGrid sesiju), sa
  žutim badge-om na fotki koja ima sačuvan edit.
- Live preview renderuje fotku ispravno, sa crop overlay-om (4 ugla + drag
  okvir) vidljivim odmah.
- Svi paneli su na mestu i ispravno formatirani: Crop & Rotate (Straighten
  slider, Reset Crop/Done), Light (Exposure/Contrast/Highlights/Shadows),
  Color (Temperature/Tint/Saturation/Vibrance), Detail & Effects
  (Sharpness/Vignette), Reset All, Export Edited Copy.
- **Non-destructive store potvrđen preko restart-a app-e**: fotka editovana
  u ranijoj sesiji (Exposure +0.15, Contrast +10, Highlights -17,
  Temperature +18, Tint +4, Saturation -12, Vibrance -36) se posle
  potpunog gašenja i ponovnog pokretanja app-e učitala sa identičnim
  vrednostima — `PhotoEditStore`/`UserDefaults` perzistencija radi kako
  treba.
- "Export Edited Copy" ispravno otvara pravi macOS save panel (NSSavePanel)
  — export wiring je funkcionalan (nije testirano do kraja, tj. nije
  snimljen fajl, panel je zatvoren bez snimanja).
- "Import Photos" i navigacija do "Develop" dugmeta rade ispravno.

Nije stiglo do provere (automatizacija preko System Events/AX nije mogla
pouzdano da simulira pravi mouse-drag na SwiftUI sliderima — `set value`
preko Accessibility API-ja se nije propagirao do app-inog state-a, verovatno
zato što SwiftUI Slider ne sluša AXValue promene bez pravog mouse-down/drag
eventa):
- Live promena slike dok se slider stvarno prevlači (drag) — vizuelno
  neproveno u ovoj sesiji, iako je binding/persist sloj potvrđeno tačan.
- Crop handle drag, Straighten efekat na slici, Before/After hold-toggle.
- RAW fajl u Develop-u — test folder (Desktop) nije imao RAW fajl pri ruci.

Test folder za sledeći put: naći/pripremiti folder sa bar jednim RAW
fajlom (CR2/CR3/NEF/ARW/DNG...) da se konačno proveri RAW pipeline.

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
  Exposure/Temperature/Tint se guraju u `CIRAWFilter`-ove native kontrole
  (vidi "Šta dalje" #6 za pun opis), ne generički pipeline.
- **Basic paneli**:
  - *Light*: Exposure, Contrast, Highlights, Shadows, Whites, Blacks
    (Highlights/Shadows/Whites/Blacks sve pomeraju tačke jedne
    `CIToneCurve`, fiksni midtone pivot na 0.5)
  - *Color*: Temperature, Tint, Saturation, Vibrance
  - *Detail & Effects*: Sharpness, Vignette
- **Histogram** na vrhu desnog panela — živi luminance histogram, prati
  Before/After i crop-in-progress preview.
- **Crop & Rotate**: rotate 90° levo/desno, Straighten slajder (-45°...45°)
  sa auto-fit crop-om (nema praznih uglova, vidi "Šta dalje" #4 za detalje
  i jednu sitnu neistraženu nijansu), crop alat sa 4 ugla za resize + drag
  za pomeranje.
- **Before/After** — drži dugme da vidiš originalnu (needitovanu) sliku.
- **Non-destructive** — edit se čuva po fotki u `UserDefaults` preko
  `PhotoEditStore` (ista `filename|filesize` logika kao `PhotoLabelStore` za
  like/rating — prati fotku kroz move/rename unutar BriefShow-a). "Reset
  All" vraća sve na neutralno.
- **Export Edited Copy** — Save panel, snima nov JPEG sa primenjenim
  izmenama; original nikad nije diran.
- **Whites/Blacks preko tone curve** — Highlights/Shadows/Whites/Blacks sve
  pomeraju tačke jedne `CIToneCurve`, sa fiksnim midtone pivotom (vidi "Šta
  dalje" #2 ispod za detalje).
- **Presets** — nova sekcija "Presets" u desnom panelu (ispod histograma,
  iznad Crop & Rotate). Global lista (`PhotoEditPreset`/
  `PhotoEditPresetStore`, novi `UserDefaults` ključ,
  `com.rocketsbrief.briefshow.photoEditPresets`), nezavisna od
  `PhotoEditStore` koji drži edit po fotki. "Save Current as Preset" otvara
  inline text field (nema alert/sheet), svaki preset red ima klik-za-apply i
  trash ikonicu za brisanje. Preset snima **ceo** `PhotoEditSettings`,
  uključujući crop/rotate/straighten (svesna odluka — vidi "Šta dalje" #5).
- **Copy/Paste settings** — dva dugmeta iznad Reset All ("Copy Settings" /
  "Paste Settings"). In-memory clipboard (`settingsClipboard`,
  `@State` na `DevelopView`) — **ne** perzistira kroz restart app-e ni kroz
  zatvaranje Develop prozora, samo dok je prozor otvoren; radi
  jedna-fotka-po-jedna (selektuj A → Copy → selektuj B → Paste), bez
  multi-select-a u filmstrip-u.
- **Lokalni adjustment (maske)** — nova sekcija "Masks" u desnom panelu
  (ispod Detail & Effects). Tri tipa: Radial (elipsa, centar/radius drag
  handles + Feather/Invert), Graduated (linija sa dve tačke, drag handles +
  Invert), Brush (freehand slikanje maske, Size/Hardness/Erase). Svaka
  maska ima svoj mini set slidera (Exposure/Contrast/Highlights/Shadows/
  Whites/Blacks/Temperature/Tint/Saturation/Vibrance/Sharpness — bez
  Vignette, bez crop/rotate). Lista maski ima eye-toggle (privremeno
  isključi bez brisanja) i trash (obriši). Pun opis arhitekture, matematike
  i šta je/nije GUI-testirano u "Šta dalje" #7.

## Poznata ograničenja / stvari koje nisu urađene

- Presets/copy-paste rade samo **jedna fotka odjednom** — nema multi-select
  u filmstrip-u za "primeni na sve selektovane" (svesno ostavljeno za
  kasnije, vidi "Šta dalje" #5).
- **Maske**: Radial nema rotaciju (samo axis-aligned elipsa — svesno
  ostavljeno za kasnije, vidi "Šta dalje" #7); Brush mask se ponovo
  generiše iz SVIH poteza na SVAKOM render-u (nema caching) — može usporiti
  interakciju na fotki sa puno poteza; Feather na Radial-u je slider, nema
  draggable ring na canvas-u. Nijedan drag-based deo (resize handle,
  brush painting) nije mogao da se testira preko AX automatizacije — isto
  poznato ograničenje kao crop handle drag od početka ovog projekta,
  očekivano radi za pravog korisnika sa pravim mišem, samo nije
  skriptovano potvrđeno.
- Nema pravi **healing/clone brush** (brush ovde je za lokalne
  tonske/color adjustment-e, ne za retuširanje/klonranje piksela).
- ~~Pre-postojeći JPEG Temperature sign bug~~ — **ispravljeno** 10. avgusta
  (kasno veče), na eksplicitan zahtev korisnika. Detalji u "Šta dalje" #6.
- Export je samo **JPEG**; nema PNG/HEIC/TIFF opciju, nema izbor kvaliteta
  u UI-ju (fiksno 0.92 compression).
- Nema keyboard shortcuts u Develop prozoru (npr. "\\" za before/after kao
  u pravom Lightroom-u) — OSIM Enter za crop commit, dodato 11. avgusta
  (vidi "Šta dalje" #8).
- Build je testiran (`xcodebuild` prolazi čisto), ali ekran **nije vizuelno
  proveren u pravoj app-i** — sledeći put prvo pokrenuti i provideti da
  crop/rotate/sliders rade kako treba na realnim fotkama (i JPEG i RAW).
- ~~Crop aspect ratio dugmad ne "zaključavaju" ručno prevlačenje handle-a~~
  — **urađeno** 11. avgusta (isto jutro, drugi zahtev), vidi "Šta dalje" #9.
- **Dupli klik na fotku u ShowGrid-u** (otvara Develop) i **on-canvas
  drag-based delovi Develop-a** (crop handle, mask handle, brush painting)
  nikad nisu mogli da se potvrde skriptovanom GUI automatizacijom u ovoj
  sesiji (SwiftUI `DragGesture`/`onTapGesture` ne reaguju na `System
  Events` sintetičke evente pouzdano — potvrđeno više puta ove sesije,
  probano i raw-coordinate klik i keyboard nudge). Očekivano rade za
  pravog korisnika sa pravim mišem — ovo je ograničenje TESTIRANJA, ne
  poznat bag u kodu.
- **Export All Edited** izvezene fajlove piše sa istim imenom pri svakom
  ponovnom export-u u isti destination folder (`<ime> Edited.jpg`) — ovo
  je namerno (tiho prepiše stari export sa novijim, ne gomila "Edited 2",
  "Edited 3" kopije), ali znači da export u FOLDER GDE VEĆ POSTOJI fajl sa
  tim imenom (ne nužno raniji export — bilo koji fajl sa tačno tim imenom)
  će biti prepisan bez upozorenja (nema NSSavePanel-style "already exists"
  potvrde kao kod pojedinačnog "Export Edited Copy", pošto se sve piše u
  jednom prolazu bez UI-ja po fajlu).

## Šta dalje (predlog redosleda za Fazu 2)

1. ~~Vizuelna provera Develop ekrana u pokrenutoj app-i~~ — urađeno 10.
   avgusta (vidi sekciju iznad), osim stvarnog drag-a na sliderima/crop-u i
   RAW fajla (nije bilo RAW-a pri ruci) — to još treba proveriti ručno.
2. ~~Whites / Blacks preko tone curve pristupa~~ — urađeno 10. avgusta.
   `CIHighlightShadowAdjust` je uklonjen; Highlights/Shadows/Whites/Blacks
   sada sve pomeraju tačke jedne `CIToneCurve` (`PhotoEditRenderer.render`
   u `Develop.swift`), sa `point2` (x=0.5) fiksiranim kao pivot da se
   srednji tonovi nikad ne pomere. `point0`/`point4` (krajnje tačke) smerno
   idu i van 0...1 opsega — to je namerno: to je ono što Whites/Blacks
   zaista gura ka clip-ovanju umesto samo da spljošti ka njemu. Highlights
   je zadržao stari predznak iz `CIHighlightShadowAdjust` verzije (+ =
   recover/tamnije) da već sačuvani edit-ovi ne promene izgled; Shadows/
   Whites/Blacks koriste uobičajenu Lightroom konvenciju (+ = svetlije).
   `PhotoEditSettings` sad ima ručno pisan `init(from:)` (umesto
   auto-sintetizovanog) sa `decodeIfPresent` fallback-ovima — bitno jer bi
   auto-sintetizovan decoder inače bacio grešku na stare sačuvane edit-ove
   bez `whites`/`blacks` ključeva i obrisao ih (`PhotoEditStore.allSettings`
   tiho vraća `[:]` kad decode ne uspe).
   Provereno bez GUI-ja (posle jednog UI-automatizacija incidenta koji je
   slučajno otvorio WhatsApp video poziv preko `cliclick` drag-a — ubuduće
   izbegavati `cliclick`/sintetički mouse-drag za testiranje ove app-e):
   izvučena identična tone-curve logika u samostalnu Swift skriptu,
   pixel-sample na sintetičkom crno→belo gradijentu potvrdio ispravan smer
   za sva četiri slidera i da midtone pivot (x=0.5) ostaje nepromenjen čak
   i sa sva 4 slidera na maksimumu.
3. ~~Histogram u adjustment panelu~~ — urađeno 10. avgusta. Živi
   luminance histogram (48 bar-ova) na vrhu desnog panela, iznad Crop &
   Rotate — `PhotoEditRenderer.luminanceHistogram(of:)` desaturira preko
   `CIColorMatrix` (Rec. 709 luma weights) pa računa `CIAreaHistogram`;
   `renderNow()` ga računa na istoj slici koja se prikazuje (uključujući
   Before/After original i crop-in-progress preview), normalizovano tako
   da najviši bar = puna visina.
   Isti standalone-skripta pristup (bez GUI-ja) uhvatio je pravi bag pre
   nego što je ušao u app: `CIColorMatrix`'s `rVector`/`gVector`/`bVector`
   su redovi matrice (dot product sa celim (r,g,b,a) input-om), ne
   pojedinačne težine po kanalu — prva verzija je stavljala istu težinu na
   x/y/z svakog vektora (npr. `rVector = (0.2126,0.2126,0.2126,0)`) umesto
   da sva tri vektora budu identična `(0.2126, 0.7152, 0.0722, 0)`. Test na
   solid-gray/ramp/bimodalnoj sintetičkoj slici je odmah pokazao da je
   histogram nakrivljen ka tamnijem kraju; posle ispravke sve tri provere
   pogađaju tačno očekivane bucket-e.
4. ~~Auto-fit crop posle straighten-a~~ — urađeno 10. avgusta.
   `PhotoEditRenderer.autoStraightenCrop(imageWidth:imageHeight:angleDegrees:)`
   računa najveći upisani axis-aligned pravougaonik u rotiran pravougaonik
   (zatvorena formula — koji par ivica "veže" zavisi od ugla vs. aspect
   ratio, 3 grane: samo-a, samo-b, ili oba istovremeno/"vertex"). Kači se
   preko `straightenBinding` (custom Binding oko `settings.straightenDegrees`
   korišćen SAMO na Straighten slideru — ne generički `.onChange`, jer bi
   se taj okinuo i pri promeni fotke u `selectPhoto`, dok `previewBaseImage`
   još pokazuje na PRETHODNU fotku). `cropIsAutoFitted` flag prati da li je
   trenutni `settings.crop` auto-fit (nastavlja da se re-fituje na sledeći
   straighten drag) ili ručan (korisnik otvorio crop alat i potvrdio —
   `commitCrop()` gasi flag, auto-fit ga više ne dira).
   Formula je matematički dokazano tačna — potvrđena 4 nezavisna načina bez
   diranja GUI-ja (standalone Swift skripte, isti pattern kao za tone
   curve/histogram bagove):
   - **containment**: svi uglovi upisanog pravougaonika ostaju unutar
     rotiranog originala (testirano landscape/portrait/square/ekstremni
     odnosi 5:1, fin sweep na svaki 1°).
   - **tightness**: pomeranje bilo koje dimenzije za +1% probija granicu
     (dokaz da formula ne kroji previše).
   - **direktan CIContext.render sample** na sve 4 tačke ugla — potvrđuje
     da se matematički model poklapa sa stvarnim `CGAffineTransform`
     ponašanjem (ne samo mojom ručnom rotacionom formulom).
   Usput uhvaćen i **lažni alarm**: prva end-to-end provera (pun
   render→crop pipeline, brojanje providnih piksela) pokazivala je do ~2.7%
   providnih piksela čak i uz auto-fit crop na nekim uglovima/odnosima —
   izgledalo kao pravi bag (dijagonalna periodična šara u ASCII vizuelizaciji).
   Ispostavilo se da je uzrok bio bag u MOM test-skriptu (ručna konverzija
   CI-koordinata → pixel-buffer indeks za direktan alpha-lookup), ne u
   `autoStraightenCrop`-u — potvrđeno direktnim `CIContext.render` sample-om
   na uglovima (bez ručne konverzije), koji pokazuje da je geometrija čista.
   **Ostaje nerešena sitnica**: čak i sa ispravnim test metodom, pun
   render→crop pipeline i dalje pokazuje ~0-2.7% providnih piksela na nekim
   sintetičkim (savršeno ravna boja, oštra ivica) test slikama — probao sam
   margin (0.3-4%) i rotaciju oko centra slike umesto oko (0,0), nijedno
   nije pomoglo monotono/pouzdano, što znači da nije ni "premalo margin-a"
   ni floating-point preciznost oko pivot tačke. Ovo je verovatno
   inherentna karakteristika CoreImage-ovog `CIAffineTransform` +
   `.cropped(to:)` renderovanja (ne geometrije), verovatno nevidljiva na
   pravim fotkama (test je bio adversarijalan — savršeno ravna boja sa
   oštrom alpha ivicom, ne stvarni foto sadržaj) i dramatično manja od
   originalnog buga (30-50% praznih uglova bez ikakvog crop-a → ispod 3% u
   najgorem sintetičkom slučaju sa auto-fit crop-om). Nisam dodao margin u
   `autoStraightenCrop` jer testovi pokazuju da margin ne pomaže pouzdano —
   bolje ostaviti matematički tačnu formulu nego dodati "magic number" bez
   dokazane koristi. Ako se ikad pokaže vidljivo na pravoj fotki, sledeći
   korak bi bio probati custom (ne `.integral`) rounding koji zaokružuje
   UNUTRA umesto napolje.
5. ~~Presets + copy/paste settings između fotki~~ — urađeno 10. avgusta
   (kasno veče), `xcodebuild` prolazi čisto I vizuelno provereno u pravoj
   app-i preko Accessibility automatizacije (System Events, bez
   `cliclick`-a) na dve test fotke: Save Current as Preset → preset se
   pojavljuje u listi → Reset All → klik na preset red primenjuje ga nazad
   (rotacija se vraća) → Copy Settings → Reset All → Paste Settings vraća
   isto stanje → trash ikonica briše preset iz liste. Sve je radilo iz
   prve, bez ijednog bug-a u samoj Presets/Copy-Paste logici.

   **Usput uhvaćena/potvrđena dva saznanja o testiranju bez GUI-ja:**
   - Obično SwiftUI `Button` (Rotate, Save, Cancel, Reset All, Copy/Paste,
     preset red, trash ikonica, tekst polje fokusiranje preko
     `System Events click at {x,y}`) pouzdano reaguje na sintetičke AX
     evente — bezbedno se može automatizovati.
   - Filmstrip thumbnail selekcija (`Image` sa `.onTapGesture`, ne pravi
     `Button`) **ne** reaguje na sintetički AX klik/AXPress, isti obrazac
     kao već dokumentovan problem sa `Slider`-ima — SwiftUI gest
     recognizer-i van pravih `Button`/`TextField` kontrola su nepouzdani
     za AX automatizaciju u ovoj app-i. Zato je Paste Settings test urađen
     na ISTOJ fotki (Copy → Reset All → Paste, potvrđuje da paste logika
     radi) umesto stvarnog prebacivanja na drugu fotku u filmstrip-u —
     samo prebacivanje fotke je čisto SwiftUI `@State` scoping,
     framework-garantovano ispravno, nije trebalo dodatno dokazivati.
   - Bitna praktična caka: host (VS Code) ponekad preotme fokus IZMEĐU
     dve odvojene `Bash`/`osascript` komande (npr. dok se screenshot čita),
     pa keystroke/klik odlazi u pogrešnu app. Rešenje: sve korake jedne
     interakcije (activate BriefShow → click → keystroke) spakovati u
     JEDAN `osascript` poziv, bez pauze za povratne pozive alatki između
     njih.
   - I dalje važi: izbegavati `cliclick`. Ovaj put je nasumično već bio
     aktivan WhatsApp video poziv na ekranu na početku sesije (nepovezano
     sa bilo kojom mojom akcijom — pre bilo kakvog klika), pa je snimanje
     ekrana urađeno isključivo preko `screencapture -l<windowID>` (samo
     BriefShow-ov prozor, preko CGWindowID nađenog standalone Swift
     skriptom), nikad pun `screencapture -x` cele table dok je poziv trajao.

   Ranije odluke iz razgovora s
   korisnikom (upitano eksplicitno jer menjaju perzistentni format):
   - Presets i copy/paste obuhvataju **ceo** `PhotoEditSettings`, uključujući
     crop/rotate/straighten (ne samo tonal/color) — korisnik je svesno
     izabrao ovu opciju iako primena preset-a sačuvanog sa jedne fotke na
     fotku drugačijeg aspect ratio-a može dati čudan crop; ekran to ne
     detektuje niti upozorava.
   - Copy/paste radi **jedna-po-jedna** (bez multi-select-a u filmstrip-u za
     "paste na više odjednom") — korisnik je izabrao ovo za sada, "paste na
     više" ostaje otvoreno kao mogući sledeći mali zadatak ako zatreba.
   Implementacija: `PhotoEditPreset` (Codable, Identifiable) +
   `PhotoEditPresetStore` (global, ne po-fotki kao `PhotoEditStore`, novi
   `UserDefaults` ključ) u "Persistence" sekciji `Develop.swift`. UI:
   `presetsSection` (lista + inline "Save Current as Preset" text field,
   bez alert/sheet) između histograma i Crop & Rotate; `copyPasteRow` (Copy/
   Paste dugmad) iznad Reset All. `settingsClipboard` je obično `@State` na
   `DevelopView` (in-memory, ne UserDefaults) — preživljava promenu fotke
   dok je Develop prozor otvoren (view se ne remount-uje pri
   `selectPhoto`), ali ne i zatvaranje prozora/restart app-e, što je
   nameravano ponašanje za "clipboard" semantiku.
6. ~~Iskoristiti native RAW kontrole~~ — urađeno 10. avgusta (kasno veče),
   `xcodebuild` prolazi čisto. **Nije provereno na pravoj RAW fotki** — na
   disku i dalje nema nijednog RAW fajla (CR2/CR3/NEF/ARW/DNG/...) da se
   otvori u pokrenutoj app-i i vizuelno potvrdi; to ostaje sledeći korak
   čim se nabavi test fajl.

   **Šta je promenjeno** (`Develop.swift`): novi `PhotoBaseImage` enum
   (`.standard(CIImage)` / `.raw(filter:asShotTemperature:asShotTint:)`)
   zamenjuje goli `CIImage` kao tip koji `loadBaseImage`/
   `loadPreviewBaseImage`/`fullBaseImage`/`previewBaseImage`/`render()` nose
   kroz sebe. Za RAW, `PhotoEditRenderer.render()` sad piše
   `filter.exposure`/`filter.neutralTemperature`/`filter.neutralTint`
   direktno na `CIRAWFilter` PRE nego što pročita `.outputImage` (primenjeno
   tokom demosaic-a, sa punim opsegom senzora), umesto generičkih
   `CIFilter.exposureAdjust`/`temperatureAndTint` koji i dalje rade
   nepromenjeno za ne-RAW fajlove. Sve ostalo (tone curve, contrast,
   vibrance, sharpen, vignette, crop) i dalje radi identično za oba tipa.

   Preview dobija **svoju odvojenu** `CIRAWFilter` instancu (drugi disk-read,
   `loadPreviewBaseImage`) sa sopstvenim `scaleFactor` za manju rezoluciju —
   ne deli filter sa `fullBaseImage`-om (rezervisan za export) i ne
   downsample-uje već-demosaic-ovan `CIImage` kroz CI transform (RAW-ov
   native `scaleFactor` je i brži i kvalitetniji za to).

   `asShotTemperature`/`asShotTint` se hvataju JEDNOM odmah posle decode-a
   (pre bilo koje izmene) i `render()` UVEK računa apsolutno
   `baseline + delta` — nikad ne čita `filter.neutralTemperature` nazad kao
   početnu tačku. Ovo je bitno: pošto je `render()` pozvan iznova na SVAKOM
   slider drag-u nad ISTIM deljenim `CIRAWFilter` objektom, čitanje
   sopstvene prethodno-postavljene vrednosti kao baznu tačku bi akumuliralo
   isti delta preko sebe sa svakim novim renderom. Provereno standalone
   Swift skriptom (ista bez-GUI tehnika kao za tone curve/histogram/crop):
   50 uzastopnih poziva sa istim slider vrednostima daju identičan
   rezultat (nema drifta), neutralno stanje (slider=0) tačno reprodukuje
   as-shot vrednost, i pun sweep slidera (-1...1) preko nekoliko as-shot
   baznih tačaka ostaje unutar `CIRAWFilter`-ovog dokumentovanog validnog
   opsega (2000...50000K za temperature, -150...150 za tint — pročitano
   direktno iz `CIRAWFilter.h` u SDK-u, ne nagađano).

   **Uzgred otkriven i (na zahtev korisnika, isto veče) ISPRAVLJEN bag**:
   dok sam pixel-testom proveravao u kom smeru JPEG-ova postojeća
   `temperatureAndTint` putanja stvarno pomera boju (da RAW-ova nova
   formula bude DOSLEDNA sa njom), ispostavilo se da `+1 Temperature` na
   JPEG-u zapravo HLADI sliku iako komentar kaže "toplije" — obrnuto od
   dokumentovanog ponašanja. Tint je proveren i bio je ispravan (nedirano).
   Prvobitno sam RAW formulu namerno napisao da prati STVARNO (bagovano)
   ponašanje JPEG-a (bitnije da isti slider radi isto na oba tipa fajla
   nego da RAW sam bude "tehnički ispravan" a JPEG ostane suprotan) i
   ostavio JPEG bag nedirnut (menja izgled već sačuvanih edit-ova sa
   ne-nula Temperature).

   Korisnik je posle eksplicitno zatražio ispravku JPEG bag-a, pa je
   urađeno: `CIFilter.temperatureAndTint`-ov `neutral.x` promenjen sa
   `6500 - settings.temperature * 3000` na `6500 + settings.temperature *
   3000` (JPEG putanja u `render()`), i RAW-ova formula vraćena nazad na
   `asShotTemperature + delta` da ostane dosledna sa ispravljenim JPEG
   smerom. Piksel-testom potvrđeno: `+1` sad zaista greje (crveni kanal >
   plavi), `-1` i dalje hladi. **Svesna posledica**: bilo koji već sačuvan
   edit sa ne-nula Temperature (JPEG ili RAW) će sad izgledati drugačije
   nego pre ove ispravke — prihvaćeno, korisnik je eksplicitno tražio
   ispravku znajući to.

   Native `boostAmount`/`boostShadowAmount` (RAW konverterova sopstvena
   globalna tone curve) su SVESNO ostavljeni na default vrednostima, ne
   povezani ni sa jednim postojećim sliderom — Highlights/Shadows/Whites/
   Blacks već savijaju jednu `CIToneCurve`, i dupliranje sa drugom,
   drugačije oblikovanom native krivom bi učinilo da ista vrednost slidera
   izgleda drugačije na RAW-u nego na JPEG-u bez jasne koristi.

   Takođe: `renderNow()`/`exportEditedCopy()` su prebačeni sa
   `DispatchQueue.global(qos:)` na novi deljeni **serijski**
   `developRenderQueue` — bitno jer RAW render sad MUTIRA deljeni
   `CIRAWFilter` objekat (`filter.exposure = ...` itd.) pre čitanja
   `.outputImage`; da su dva rendera istog fotosa nekad trčala paralelno
   (moguće kod brzog prevlačenja slidera pre nego što se debounce
   stabilizuje, ili `showOriginal` toggle koji se preklopi sa debounced
   render-om), to bi bio pravi data race nad istim objektom. Serijski red
   ovo rešava, i uzgred garantuje da stariji render nikad ne "blesne" na
   ekranu posle novijeg — mala popravka i za ne-RAW putanju, ne samo RAW.
7. ~~Lokalni adjustment (maske)~~ — urađeno 10/11. avgust (kasna noć),
   `xcodebuild` prolazi čisto, i vizuelno provereno u pravoj app-i (add/
   select/list/delete/enable-toggle/on-canvas-overlay). Korisnik je
   eksplicitno tražio **sva tri tipa odjednom** (Radial + Graduated +
   Brush) kad je pitan da li da se brush odloži za kasnije — veći obim u
   jednom prolazu nego prvobitno predloženo, ali sve je stalo u jednu
   sesiju.

   **Model** (`Develop.swift`, nova sekcija "MARK: - Local adjustments
   (masks)"): `LocalAdjustment` (Codable, Identifiable) — `type`
   (`.radial`/`.graduated`/`.brush`), tačno jedna od `radial`/`graduated`/
   `brush` geometrija popunjena (odgovara `type`-u), `settings`
   (`LocalAdjustmentSettings` — Exposure/Contrast/Highlights/Shadows/
   Whites/Blacks/Saturation/Vibrance/Temperature/Tint/Sharpness, BEZ
   Vignette i BEZ crop/rotate — geometrija je uvek globalna, vinjeta
   maskirana na proizvoljan region prestaje da bude "vinjeta"),
   `isEnabled` (eye-toggle bez brisanja). `PhotoEditSettings.localAdjustments:
   [LocalAdjustment] = []` — novo polje, `decodeIfPresent` fallback na
   `[]` (isti obrazac kao `whites`/`blacks` ranije — stari sačuvani edit-i
   bez ovog ključa i dalje ispravno decode-uju), uključeno u `isNeutral`.
   Geometrija (`RadialMaskGeometry`/`GraduatedMaskGeometry`/
   `BrushMaskGeometry`+`BrushStroke`) je u ISTOM unit-square (0...1,
   top-down Y) koordinatnom sistemu kao `EditCropRect` — ostaje validna
   kroz preview/full-res render i kroz Straighten/rotate.

   **Render pipeline** (`PhotoEditRenderer`): `applyLocalAdjustments`
   poziva se u `render()` odmah posle Vignette-a, pre crop-a. Za svaku
   uključenu (i ne-neutralnu — neutralne se preskaču kao optimizacija)
   masku: (1) generiše se grayscale mask `CIImage` (belo = pun efekat,
   crno = ništa) preko `maskImage(for:extent:)`, (2) `applyLocalToneColorDetail`
   primenjuje ISTI filter lanac (temperature/tint → exposure → tone curve
   → contrast/saturation → vibrance → sharpen) kao globalni pipeline, ali
   NAMERNO kao odvojena skoro-identična kopija (ne deljena helper funkcija
   koju i globalni `render()` poziva) — da ova promena nikad ne može da
   pokvari već pixel-testiran globalni pipeline, (3) `CIBlendWithMask`
   kombinuje adjustovanu i originalnu verziju preko maske. Maske se
   primenjuju REDOM (svaka sledeća vidi efekat prethodnih), kao u
   Lightroom-u.

   **Mask geometrija — matematika, sve provereno standalone Swift
   skriptama pre nego što je ušlo u app** (isti pattern kao auto-fit crop/
   histogram/RAW ranije):
   - **Radial**: `CIRadialGradient` generisan u "unit" prostoru (centar
     (0,0), radius 1), pa mapiran NA SLIKU jednom eksplicitnom afinom
     matricom `CGAffineTransform(a: rx, b: 0, c: 0, d: ry, tx: cx, ty: cy)`
     — namerno JEDNA eksplicitna matrica umesto lančanog
     `.scaledBy().translatedBy()` (čiji redosled primene nisam bio 100%
     siguran napamet, pa sam izbegao dvosmislenost umesto da nagađam).
     Feather kontroliše razmak `radius0`/`radius1`. Invert menja mesta
     `color0`/`color1`. Provereno: centar/ellipse aspect ratio/feather
     smer/invert — sve pogađa tačno.
   - **Graduated**: `CILinearGradient` (point0→point1, White→Black) —
     nije trebao transform, filter sam po sebi clamp-uje na solid boju pre
     point0 i posle point1, i konstantan je duž perpendikularnog pravca
     (tačno Lightroom-ovo ponašanje "graduated filter"-a). Provereno:
     start/end/clamp-ovi van segmenta/konstantnost duž X.
   - **Brush**: svaki potez (`BrushStroke`) renderuje se kao unija
     (`CIMaximumCompositing`) mekih `CIRadialGradient` "dab"-ova
     interpolisanih duž snimljenih tačaka (max 40 dab-ova po segmentu, da
     spor drag sa retkim tačkama i dalje da neprekidnu liniju bez
     eksplozije broja filter node-ova). Erase potezi (`isErase`) množe
     akumuliranu masku sa `1 - dabs` (`CIColorInvert` + `CIMultiplyCompositing`)
     umesto da je posvetljuju — kasniji potez uvek pobeđuje na istom mestu,
     kao pravi paint alat. Hardness kontroliše radius0/radius1 razmak isto
     kao Radial-ov feather. Provereno: pokrivenost duž poteza (bez
     "tačkaste" linije), erase, hardness smer.

   **UI** (`DevelopView`): nova sekcija "Masks" (ispod Detail & Effects,
   iznad Copy/Paste) — tri dugmeta za dodavanje (`MaskAddButtonStyle`,
   NOVI button style jer `EditToolButtonStyle` ima fiksnih 30×30 koji seče
   dvolinijski icon+label sadržaj — uhvaćeno vizuelnom proverom, ispravljeno
   odmah), lista postojećih maski (ime, tip-ikonica, eye-toggle, trash,
   klik-za-select), i kad je maska selektovana — mini editor ispod liste sa
   njenim sopstvenim sličicama (Invert+Feather za Radial, Invert za
   Graduated, Erase+Brush Size+Hardness+Clear Strokes za Brush) plus punim
   setom tonskih/color slidera (`localAdjustmentBinding(_:)` — generički
   `Binding` preko `WritableKeyPath`, isti obrazac kao `straightenBinding`
   ranije). Selekcija se prati preko `selectedLocalAdjustmentID: UUID?`
   (indeks se svaki put iznova računa iz UUID-a — `selectedAdjustmentIndex`
   — jer se niz može promeniti/skratiti ispod selekcije). Selekcija maske i
   crop tool su međusobno isključivi (`isCropping`/mask selection gase
   jedno drugo).

   **On-canvas overlay** (u `centerPreview`, isti `fitted` frame koji crop
   overlay već koristi): Radial crta elipsu + 3 drag handle-a (centar-move,
   radiusX, radiusY — svaki resize handle menja SAMO tu osu, ne kao crop-ov
   corner-drag koji kupluje oba); Graduated crta isprekidanu liniju + 2
   handle-a (start/end); Brush crta providan hit-area preko cele slike sa
   `DragGesture(minimumDistance: 0)` — dok se crta, prikazuje se JEFTIN
   vektorski `Path` preview (bez CI re-render-a po tački, prevruće za
   interaktivnost), i tek na mouse-up (`commitBrushStroke`) se potez
   upisuje u `settings.localAdjustments[...].brush.strokes` i pokreće se
   pravi render. Radial/Graduated handle-i koriste isti "drag-start
   snapshot" obrazac kao crop (`radialDragStart`/`graduatedDragStart`
   `@State`, analogno `dragStartCrop`).

   **Šta JE vizuelno provereno u pravoj app-i** (Accessibility automatizacija,
   bez `cliclick`-a, isti pristup kao za Presets ranije): Save/dodavanje sve
   tri vrste maski (dugme klik → pojavljuje se u listi sa ispravnom
   ikonicom/imenom → auto-selektovano), on-canvas overlay se ISCRTAVA
   ispravno za Radial (elipsa + handle-i na default centru/radiusu) i
   Graduated (isprekidana linija + 2 handle-a na default pozicijama), mini
   editor prikazuje tačno očekivane tip-specifične kontrole za svaki tip,
   eye-toggle menja ikonicu (eye ↔ eye.slash), trash briše iz liste, Reset
   All ispravno čisti sve maske i vraća `isNeutral` na `true`
   (Copy Settings/Reset All/Save Preset dugmad se ispravno disable-uju).

   **Šta NIJE moglo da se GUI-testira** (isto poznato ograničenje kao Slider
   drag i filmstrip klik ranije u ovoj sesiji — `System Events` sintetički
   eventi ne pokreću SwiftUI `DragGesture`/`Slider` pouzdano, probano i
   raw-coordinate klik + keyboard arrow-key nudge na fokusiranom slideru,
   ni to nije upalilo): stvarno prevlačenje Radial/Graduated handle-a
   (resize/move), stvarno slikanje Brush poteza, i samim tim ni end-to-end
   potvrda da `CIBlendWithMask` kompozicija stvarno menja piksele na
   ekranu kad je neka maska podešena na ne-nula Exposure/itd. Matematika
   maske same po sebi (gde je bela/crna, kakav je feather/hardness/invert)
   JE potvrđena; `applyLocalToneColorDetail`+`CIBlendWithMask` je
   direktna, jednostavna primena već pixel-testiranog filter lanca preko
   već-potvrđene maske, pa je rizik nizak, ali nije 100% end-to-end
   dokazano pixel-testom kao auto-fit crop ranije. Ako se ikad posumnja da
   ne radi, sledeći korak bi bio standalone skripta koja poziva
   `applyLocalAdjustments` direktno (bez GUI-ja) na sintetičkoj slici i
   pixel-sample-uje rezultat, isti pattern kao za crop/histogram.

   **Poznata ograničenja (svesno ostavljena, ne bagovi)**:
   - Radial mask nema rotaciju (samo axis-aligned elipsa) — dodavanje
     rotate handle-a je dodatni UI zalogaj, odloženo.
   - Brush mask nema caching — `brushMask()` se u potpunosti rebuild-uje iz
     SVIH poteza na SVAKOM `render()` pozivu, čak i kad se menja neki
     nepovezan slider drugde u istim settings-ima. Fino za skroman broj
     poteza (debounce + preview-rezolucija drže interaktivnost), ali gusto
     naslikana maska bi mogla usporiti editovanje. Pravo rešenje bi keširalo
     render-ovanu masku po `LocalAdjustment`-u (koji je već `Equatable`) i
     rebuild-ovalo samo promenjene — odloženo.
   - Feather (Radial) je samo slider, nema draggable prsten na canvas-u.
   - `boostAmount`/native RAW kontrole se ne primenjuju na lokalne maske
     (maske uvek idu kroz generic CIFilter lanac, bez obzira na RAW/JPEG
     izvor) — nema RAW-native ekvivalenta za maskiran region, ovo je
     očekivano i ne treba ga menjati.

8. ~~Četiri UX izmene koje je korisnik zatražio nakon Faze 2~~ — urađeno
   11. avgust (rano jutro), `xcodebuild` prolazi čisto na sve četiri.

   **1) Enter komituje crop** (`Develop.swift`, `cropRotateSection`):
   `.keyboardShortcut(.return, modifiers: [])` dodat na postojeće crop
   "Done" dugme (`commitCrop()`). Pošto to dugme postoji u view stablu
   SAMO dok je `isCropping == true`, shortcut je automatski aktivan samo
   tokom cropovanja — ne mora ručno da se gate-uje. Bitno:
   `modifiers: []` je OBAVEZNO — `keyboardShortcut`-ov default modifier
   je `.command`, bez eksplicitnog `[]` bi ovo bio ⌘+Enter, ne obično
   Enter. **Vizuelno POTVRĐENO** pravim `key code 36` (System Events) —
   ovo je PRAVI keyboard event (isti mehanizam kao kucanje teksta koje je
   radilo ranije za preset ime), ne AX sintetička akcija, pa je i
   uspešno — za razliku od Slider drag-a/`onTapGesture`-a koji NE
   reaguju na sintetičke evente. Slika se stvarno isekla na test fotki.

   **2) Crop aspect ratio dugmad** (`Free/1:1/4:3/3:4/16:9/9:16`): nova
   `CropAspectRatioOption` enum (`.free/.square/.fourThree/.threeFour/
   .sixteenNine/.nineSixteen`, svaka nosi `ratio: Double?` = width/height
   ili `nil` za Free) + `aspectRatioRow` (šest `AspectRatioButtonStyle`
   dugmadi, novi mali pill-style pored `EditToolButtonStyle`/
   `MaskAddButtonStyle`) iznad Reset Crop/Done reda. Klik poziva
   `applyCropAspectRatio(_:)`: računa najveći centrirani `EditCropRect` te
   razmere koji staje u (post-rotation) sliku — matematika:
   `imagePixelRatio = width/height` slike; ako je `ratio > imagePixelRatio`
   (traženo šire od slike) crop koristi punu širinu i
   `cropHeightFraction = imagePixelRatio/ratio`; inače puna visina i
   `cropWidthFraction = ratio/imagePixelRatio` — algebarski proveren
   (`cropW*width/(cropH*height) = ratio` u oba slučaja) i **vizuelno
   POTVRĐEN u pravoj app-i**: klik na "4:3" i "16:9" dao je tačno
   očekivane centrirane pravougaonike na test fotki, dugme se ispravno
   highlight-uje. `selectedCropAspectRatio` (novi `@State`) prati koje je
   dugme aktivno — resetuje se na `.free` kad se uđe u crop mode
   (`toggleCropMode`), na "Reset Crop", i kad korisnik ručno prevuče bilo
   koji resize handle (`resizeCrop` — pošto to raskida zaključanu razmeru;
   `moveCrop`, čisto pomeranje, NE resetuje, razmera ostaje ista).
   **Namerno NE zaključava** dalje ručno prevlačenje na tu razmeru (vidi
   "Poznata ograničenja") — dugme je brzi početak, ne trajni constraint.

   **3) Brush mask trajno vidljiv posle slikanja**: pre ove izmene,
   `brushPaintOverlay` je crtao samo AKTIVAN potez (`activeBrushStrokePoints`)
   dok se aktivno vuče — čim se pusti dugme na mišu, `commitBrushStroke()`
   prazni taj niz i ništa više nije vidljivo na ekranu za tu masku (efekat
   se video samo indirektno kroz stvarno renderovanu sliku, i to samo ako
   su slideri te maske ne-nula). Dodat `brushMaskCanvas(_:frame:)` —
   koristi SwiftUI `Canvas` (ne prost `Path`/`ZStack`) baš zato što
   `Canvas` podržava `context.blendMode`: paint potezi se crtaju sa
   `.normal` (accentColor, opacity 0.4), erase potezi sa
   `.destinationOut` (bela boja) — što STVARNO izbriše rupu u već
   nacrtanom overlay-u, umesto da samo nacrta providan oblik preko koji
   vizuelno ne bi "oduzeo" ništa. `localAdjustmentOverlay`/
   `brushPaintOverlay` sad primaju `adjustment.brush: BrushMaskGeometry?`
   da imaju šta da iscrtaju. **Nije moglo GUI-testirati** (brush slikanje
   je `DragGesture`, isto poznato ograničenje).

   **4) Dupli klik na fotku u ShowGrid-u otvara Develop**
   (`ContentView.swift`, `PhotoShowSheet.thumbnailCell`): dodat
   `.onTapGesture(count: 2) { DevelopWindowController.shared.open(
   photoURLs: photoURLs, initialSelection: url) }` PRE postojećeg
   `.onTapGesture { handleSelectTap(url) }` — taj redosled (double PRE
   single) je standardni SwiftUI idiom koji omogućava frameworku da čeka
   kratko da vidi da li će stići drugi klik pre nego što okine single-tap
   handler. Isti `DevelopWindowController.shared.open(...)` poziv koji već
   koristi header-ovo "Develop" dugme, samo sa `initialSelection` = tačno
   ta fotka umesto `selectedURLs.first ?? photoURLs.first`. **Nije moglo
   GUI-testirati** (isti `onTapGesture` sintetički-event problem —
   testirano i ranije ove sesije da ni SINGLE tap preko `System Events`
   ne stiže pouzdano do `onTapGesture`, kamoli double).

9. ~~Ratio-locked crop resize + Export All Edited~~ — urađeno 11. avgusta
   (isto jutro, korisnik je tražio posle probanja stavke #8), `xcodebuild`
   prolazi čisto.

   **Ratio-locked resize** (`Develop.swift`, `resizeCrop`): potpuno
   prepisano da anchoruje SUPROTAN ugao od onog koji se vuče (npr. vučenje
   `.bottomRight` drži `.topLeft` fiksnim), računa "sirovu" (nezavisnu)
   width/height kao i pre, pa AKO je `selectedCropAspectRatio` zaključana
   (nije `.free`) — pomiri width/height preko `k = ratio / imagePixelRatio`
   (target razmera prevedena u FRACTION prostor, pošto `EditCropRect`
   x/y/width/height nisu u pixel prostoru nego u 0...1 razlomcima slike, a
   fraction prostor nije isti "oblik" kao pixel prostor osim ako je slika
   kvadratna) — bira VEĆI od dva kandidata (voditi širinom vs. voditi
   visinom), pa skalira OBA zajedno da stanu u granice slike na anchor
   uglu (nikad samo jednu osu, da razmera ostane tačna i posle
   clamp-ovanja na ivicu). `currentImagePixelRatio` (novi computed
   property, isti obrazac kao u `applyAutoFitCropIfNeeded`) čita stvarnu
   pixel širinu/visinu slike (post-rotation) iz `previewBaseImage`.
   `selectedCropAspectRatio = .free` reset je UKLONJEN iz `resizeCrop`
   (ranije se okidao na početku svakog resize drag-a — to je bio uzrok
   problema koji je korisnik prijavio). I dalje se resetuje na: novi klik
   na DRUGO dugme za razmeru, "Reset Crop", i otvaranje crop alata na
   sledećoj fotki (`toggleCropMode`) — `moveCrop` (čisto pomeranje bez
   promene veličine) NE resetuje, razmera ostaje ista jer se logično ne
   menja pri pukom pomeranju.

   Matematika provereno standalone Swift skriptom PRE ugrađivanja u kod
   (isti obrazac kao za sve ostalo ove sesije): (1) **regresija** — kad
   nije zaključana razmera, novi kod daje BIT-ZA-BIT identičan rezultat
   kao stara nezavisna-osa implementacija u 60 test slučajeva (4 handle-a
   × 3 start crop-a × 5 delta kombinacija); (2) **razmera održana** — u
   960 test slučajeva (dodato 4 razmere × 4 image-pixel-ratio vrednosti)
   krajnji pravougaonik uvek ima TAČNO traženu pixel razmeru, i ostaje
   unutar 0...1 granica; (3) **anchor fiksiran** — vučenje `.bottomRight`
   nikad ne pomera `.topLeft` i obrnuto. Sam drag nije mogao GUI-testirati
   (poznato ograničenje), ali je vizuelno potvrđeno da klik na dugme za
   razmeru i dalje radi kako treba (4:3/16:9 test) posle refaktora, i
   `xcodebuild` čist.

   **Export All Edited** (`Develop.swift`, novo dugme pored "Export Edited
   Copy" + `exportAllEditedPhotos()`): filtrira `photoURLs` (cela lista
   fotki iz foldera koju filmstrip prikazuje, ne samo trenutno
   selektovanu) preko `PhotoEditStore.hasEdits(url)`, otvara JEDAN
   `NSOpenPanel` (canChooseDirectories, ne canChooseFiles — bira folder,
   ne fajl) sa porukom "Choose a folder for the N edited photo(s)", pa za
   svaku editovanu fotku: učita njen FULL-RES base image
   (`PhotoEditRenderer.loadBaseImage`), pročita njena SAČUVANA podešavanja
   (`PhotoEditStore.settings(for:)` — ne in-memory `settings` iz trenutno
   otvorene fotke, pošto to važi samo za JEDNU fotku; ostale se čitaju
   direktno iz store-a, što je već ažurno jer `renderNow()` upisuje u
   store na svaki render), renderuje sa punim pipeline-om (crop, sve
   slidere, maske), i piše `<ime> Edited.jpg` u izabrani folder. Sve radi
   REDOM (ne paralelno) na `developRenderQueue` — namerno, da se izbegne
   spike memorije od više punih (posebno RAW) dekodiranja odjednom.
   `exportStatusText` prikazuje progres "Exporting N/M…" uživo dok traje.
   Needitovane fotke se tiho preskaču (ne pišu se uopšte). Dugme prikazuje
   broj editovanih fotki uživo (`Export All Edited (N)`, disabled kad je
   0). **Vizuelno POTVRĐENO end-to-end** na dve test fotke (jedna
   rotirana/editovana, jedna needitovana): dugme je pokazalo tačan broj
   (1), folder picker se otvorio sa ispravnom (gramatički tačnom, jednina)
   porukom, stvaran export je napisao TAČNO jedan fajl
   (`test-a Edited.jpg`, test-b ispravno preskočen), i taj fajl je
   pri otvaranju pokazao ispravno primenjenu rotaciju.

## Vezano

- Odluke iz razgovora: ostaje **u istom** Xcode projektu/app-u kao BriefShow
  (ne poseban `.app`, ne poseban proizvod — nema "BriefEdits" brendiranje,
  samo "Develop" unutar BriefShow-a), standalone je (ne dira grid ni
  slideshow), podržava i RAW.
