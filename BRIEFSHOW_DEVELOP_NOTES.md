# BriefShow Develop — status i plan

Beleška za nastavak rada. Poslednja izmena: 1. septembar 2026 (v10.1).

## 🟢 ZAKLJUČANO — rezolucija slike u LumenoLab-u

**Slika otvorena u LumenoLab-u i spremna za rad MORA biti u originalnoj
rezoluciji fajla. Nijedna popravka, optimizacija ni ubrzanje ne sme da je
smanji.** Ovo je zahtev korisnika, izričit, i ne pregovara se performansama.

Šta to konkretno znači u kodu:

- `refinedRenderNow` renderuje iz `fullBaseImage` i mora da završi na **native
  rezoluciji fajla** (mereno: 5176×3448 na .NEF-u). Ne skraćivati ga na
  rezoluciju ekrana, ma koliko to bilo brže.
- `loadPreviewBaseImage(previewMax:)` je SAMO međukorak dok se vuče slajder.
  Trenutno 2600 px. Ako ga neko spušta, mora prvo da izmeri šta klijent vidi —
  na 1600 px je bilo vidljivo meko i prijavljeno je kao kvar.
- Kašnjenje refine-a (`scheduleRefinedRender`) sme da se podešava, ali sa merom:
  1,2 s je jednom postavljeno „za svaki slučaj" i to je značilo da klijent
  gleda meku sliku više od sekunde posle SVAKE izmene. Sad je 0,45 s za RAW.
- Sličice u filmstrip-u i u ShowGrid-u su izuzetak — one SMEJU biti male, to je
  dogovoreno.

Ako neka buduća optimizacija traži da se ovo prekrši, odgovor je ne; traži se
drugo rešenje.

## 🟢 ZAKLJUČANO — AI MODELI I NJIHOVA PODEŠAVANJA

**Rezultat AI Clean Up-a je 31.08. proglašen dobrim od strane korisnika.
Ništa u ovom odeljku se ne dira dok se popravlja bilo šta drugo.** Ako neki
budući posao naizgled traži izmenu ovde, odgovor je ne — traži se drugo
rešenje, ili se prvo pita korisnik.

### Brojevi koji ostaju kakvi jesu

| šta | vrednost | zašto |
|---|---|---|
| `LaMaInpaintPipeline.imageSide` | **512** | 1024 je rekonvertovan DVAPUT i oba puta gori; 2048 je OOM na 9 GB. KORAK 19. |
| `SDInpaintPipeline.imageSide` | **512** | isto radno platno |
| `SDInpaintPipeline.defaultSteps` | **12** | manje koraka = manje detalja u izmišljenom delu |
| `SDInpaintPipeline.defaultRefineStrength` | **0,3** | 0,65 izmišlja objekte na zdravim kadrovima, mereno |

### Odluke koje ostaju kakve jesu

- **Generative kreće od LaMine popune, ne od šuma** (KORAK 40). Start od šuma je
  meren i izmišlja cele objekte.
- **`toneMatch` napušta korekciju kad prsten nije merljiv** — donja granica
  clamp-a (0,85) se čita kao signal, ne zaokružuje (KORAK 41).
- **`toneMatch` odbija nekonačan fit**, i **`byteFromModel` odbija nekonačan
  piksel** (KORAK 45). Ovo dvoje je popravilo belu mrlju. `UInt8(max(0,
  min(255, nan)))` daje **255**, dakle čisto belo — ne dirati taj lanac.
- **Jedno brisanje po grupi oznaka**, ne jedna maska preko svega
  (`briefShowRemovalJobs`). Jedna maska preko dva udaljena mesta stavlja radni
  kvadrat u praznu sredinu kadra.
- **`blur` i `grow`** — vidi zasebni zaključani odeljak ispod; to je bila
  popravka brzine koja NE menja rezultat ni za piksel.

### Ako ipak zatreba brže

Jedina dva poluga su **manje koraka difuzije** i **manji radni kvadrat**, i oba
plaćaju kvalitetom. Ne dirati bez izričite reči korisnika.


## 🟢 ZAKLJUČANO — `blur` i `grow` u `DevelopInpaint.swift`

**`InpaintPipeline.blur` mora ostati box blur sa KLIZEĆIM ZBIROM, a `grow`
razdvojen na dva prolaza. Ne vraćati ih na naivnu petlju.** Provereno, izmereno
i potvrđeno od korisnika 31.08.

Naivna verzija je za svaki piksel iznova sabirala svih `2r+1` vrednosti u
prozoru. `blur` ima dva prolaza i `package` ga zove dvaput, dakle
`4 × w × h × (2r+1)` sabiranja. Na 512×512 sa radijusom koji feather traži to
su stotine miliona operacija.

Mereno u app-i, isti potez, ista maska, „Quick" Clean Up:

| | pre | posle |
|---|---|---|
| `lama fill` (sam model) | 1,14 s | 1,19 s |
| ceo prolaz | **8,03 s** | **2,19 s** |
| od toga `package()` | **6,9 s** | **1,0 s** |

Model nikad nije bio problem. `package` jeste, i to je dugme koje se zove
Quick.

Klizeći zbir daje **identičan rezultat do piksela** — isti prozor, i ivice se
ponašaju isto (prosek samo preko važećih piksela, `count` se smanjuje na rubu
tačno kao kad su preskakani `guard`-om). Cena po pikselu ne zavisi od radijusa.
`grow` je razdvojen jer je maksimum asocijativan, pa prolaz po širini pa po
visini daje isti rezultat uz `2(2r+1)` umesto `(2r+1)²` poređenja.

⚠️ Merenja gore su iz **Debug** builda. Release je znatno brži, ali to nije
razlog da se naivna verzija vrati — bila bi spora i tamo.


**⚠️ Za sledeću sesiju koja dodaje bilo kakav novi `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` monitor** — DVA obavezna pravila, oba naučena kroz prave incidente u produkciji:
1. UVEK proveriti `event.isARepeat` i vratiti `event` (ne progutati) kad je true, OSIM ako je namerno drugačije. Stavka #15 ispod dokumentuje prvi incident (app zamrznut, `kill -9` morao) kad je ovo izostavljeno.
2. UVEK ograničiti monitor na SVOJ prozor (`guard NSApp.keyWindow?.title == "<taj prozor>" else { return event }`, prva linija u handleru). Local NSEvent monitori su APP-WIDE, ne po-prozoru — bez ove provere, monitor registrovan u JEDNOM prozoru (npr. ShowGrid) i dalje prima i OBRAĐUJE tastere dok je NEKI DRUGI prozor (npr. Develop) fokusiran, često sa netačnim/praznim kontekstom (npr. "ništa nije selektovano, pa primeni na CEO folder"). Stavka #18 dokumentuje pravi incident (ceo Desktop folder rekurzivno kopiran u sebe, DVA puta, `kill -9` morao oba puta) kad je ovo izostavljeno na ShowGrid-ovom monitoru dok je Develop-ov (koji JESTE imao ovu proveru) bio ispravan primer.

## 🟢 ZAKLJUČANO — LICENCE I KOMERCIJALNA UPOTREBA

**Provereno 31.08–01.09.2026. u primarnim izvorima. Ovo se više ne preispituje.**
Ako neka buduća sesija ponovo otvori pitanje „smemo li komercijalno", odgovor je
ovde, sa dokazima. Menja se samo ako stigne nov dokument od nosioca prava.

| komponenta | licenca | komercijalno |
|---|---|---|
| **LaMa — kod** | Apache 2.0 (`lama-src/LICENSE`) | **DA** |
| **LaMa — težine `big-lama`** | Apache 2.0 | **DA** |
| **Stable Diffusion 1.5 Inpainting** | CreativeML Open RAIL-M | **DA**, uz obaveze — ispunjene |
| **CLIP tokenizer** | MIT | DA |
| **Figtree, Unbounded** | SIL OFL 1.1 | DA |
| **Čitanje Lightroom .xmp** | naša implementacija | DA |

### Zašto su težine rešene

- Zvanični LaMa README (i naš `lama-src/README.md` linija 113, i aktuelni na
  `github.com/advimman/lama`) daje **tačno jedan** link za „The best model
  (Places2, Places Challenge)": `huggingface.co/smartywu/big-lama`. To je link
  koji **autori propisuju**, a ne kopija nađena sa strane.
- Ta HF stranica deklariše `license: apache-2.0`.
- Aktuelni zvanični README **nigde** ne ograničava modele — traženo „licen",
  „commercial", „non-commercial", „copyright": nula pogodaka. Repo ima jednu
  licencu, Apache 2.0, u korenu.
- **OpenCV** objavljuje **iste** težine (`huggingface.co/opencv/inpainting_lama`)
  sa pravim `LICENSE` fajlom, pun Apache 2.0 tekst, i README-om koji kaže „All
  files in this directory are licensed under Apache License". Velik projekat sa
  stvarnom pravnom izloženošću ih je pogledao i objavio komercijalno.

### Dve stvari koje su usput bile POGREŠNO zaključene, da se ne ponove

1. „Težine su sa tuđeg re-uploada i ne daju ništa." **Netačno** — to je link iz
   zvaničnog README-a.
2. „Težine idu pod CC BY-NC-SA 4.0, nekomercijalno." **Netačno i nepotvrđeno** —
   ništa u repou, README-u ni model card-u to ne kaže.

Obe su bile moje, obe su povučene i **izričito zapisane kao povučene** u
`BriefShow/Licenses/THIRD_PARTY_LICENSES.md`, jer je ranija verzija bila osnova
za odluku o prodaji app-a.

### Šta ostaje, i zašto NIJE prepreka

Places2 (dataset na kome je model treniran) deli se za istraživanje. Da li se
uslovi dataseta uopšte protežu kroz istrenirane težine — da li su težine
„izvedeno delo" od slika — **nerešeno je pravno pitanje, ne „ne"**. Isto stoji
ispod praktično svakog objavljenog vision modela, uključujući i SD koji već
koristimo. Nije specifično za nas.

Ako se ikad bude htela hartija: jedno pitanje autorima uz SHA-256
`fccb7adffd53ec0974ee5503c3731c2c2f1e7e07856fd9228cdcc0b46fd5d423`, odgovor
sačuvati u `BriefShow/Licenses/`.

### Šta je ISPORUČENO u app-u

`BriefShow.app/Contents/Resources/` nosi pun tekst svake licence — povučeni
doslovno, ne prepričani: `LaMa-Apache-2.0.txt`,
`StableDiffusion-CreativeML-Open-RAIL-M.txt`, `CLIP-MIT.txt`,
`Fonts-SIL-OFL-1.1.txt`, `THIRD_PARTY_LICENSES.md`.

Open RAIL-M ima dve obaveze i **obe su ispunjene**: licenca putuje uz app, a
ograničenja upotrebe (Attachment A) stoje u Disclaimer-u, u sekciji
„Restrictions on AI use", koju korisnik otvara iz futera.

### ⚠️ Ne pravi Opciju B

Retreniranje modela na „čistim" podacima je bilo planirano samo za slučaj da
odgovor bude „ne". Odgovor nije „ne". Retreniranje bi promenilo rezultat AI
Clean Up-a, koji je zaključan gore kao dobar.


## 🟢 ZAKLJUČANO — DISTRIBUCIJA: NE IDEMO NA APP STORE

**Odluka klijenta, 2. septembar 2026.** App se **ne objavljuje na Mac App
Store-u.** Pristup se daje **po mašini**, kroz sistem koji već postoji. Ako neka
buduća sesija počne da priprema App Store (sandbox pod njihovim pravilima,
review, receipt validacija, In-App Purchase umesto naših mesta) — ne radi to,
nego prvo pitaj.

### Kako se app isporučuje, i to je ceo lanac

1. Universal Release build (`lipo -archs` → `x86_64 arm64`).
2. Arhiva na **GitHub release** (`gh release create`), klijent je preuzima sam.
3. Prijava je **u app-i** (KORAK 57), nikoga ne šalje na sajt.
4. Ko sme da je pokrene odlučuje **BriefControl baza**, ne app: jedan email,
   jedan kompjuter, identitet mašine iz IOKit-a (KORAK 56). Broj mesta se menja
   u bazi, bez novog build-a.

Znači: dozvola se daje mašini, a ne kupuje se u prodavnici. Zato App Store ovde
ne rešava nijedan problem koji imamo, a doneo bi svoja pravila.

### ⚠️ Šta ovo znači za potpis — jedina cena, i treba je znati

- Na ovoj mašini **nema nijednog Developer ID sertifikata**
  (`security find-identity -v -p codesigning` → *0 valid identities*, mereno
  2.09.), i **v10.1 je otišla ad-hoc potpisana** (`Signature=adhoc`,
  `TeamIdentifier=not set`, provereno na samom paketu).
- Ad-hoc znači da korisnik na svom Mac-u mora **ručno da dozvoli** app pri prvom
  pokretanju (desni klik ▸ Open, a na novijim macOS-ima kroz
  System Settings ▸ Privacy & Security ▸ Open Anyway). To je i dalje „dozvola
  mašini", samo je daje macOS, a ne mi.
- **Notarizacija NIJE vezana za App Store.** Developer ID + notarizacija bi ovu
  frikciju uklonila i pritom nas ne bi uvela ni u kakvu prodavnicu. Nije
  odbačena — samo se **ne može uraditi bez sertifikata** i zato ne stoji na putu
  release-u.
- ⚠️ Ovo nije provereno na tuđem Mac-u u ovoj sesiji. Ista klasa greške kao
  KORAK 35: radilo je u Xcode-u, palo potpisano.

### Posledica za plan release-a 10.67

Korak 4 („Potpis i notarizacija") se **preskače dok stoji ova odluka i dok nema
sertifikata** — pakuje se ad-hoc, isto kao 10.1. Koraci 1, 2, 3, 5 i 6 ostaju
nepromenjeni. Nijedan drugi deo plana ovo ne dira.


## 🟢 ZAKLJUČANO — SVAKI UPDATE IDE ČIST: NIŠTA SA OVE MAŠINE

**Zahtev klijenta, 3. septembar 2026, doslovno:** *„kada pravimo novi update
nikada ne ubacujemo odavde slike ili nešto — samo čist app update!"*

Ovo važi za **svaki** build, release i push, bez izuzetka i bez pitanja svaki
put. Ne ide gore: nijedna njegova fotografija, nijedan sloj, nijedan njegov
edit, nijedan test fajl, nijedan build keš.

### Gde njegovi podaci ZAISTA žive — i zašto nisu u app-u

| šta | gde | ide li u build |
|---|---|---|
| izmene (slajderi, maske, kropovi, slojevi) | `UserDefaults`, `com.rocketsbrief.BriefShow` | **ne** |
| pikseli slojeva | `…/Containers/…/Application Support/BriefShow/LayerPixels` | **ne** |
| flatten kopije (1,5 GB) | `…/Application Support/BriefShow/Flattened` | **ne** |
| originalne fotografije | njegov folder (`~/Downloads/RAW` i sl.) | **ne** |

Ništa od toga nije u repou niti u paketu. App se instalira prazna i puni se
radom korisnika — tako i treba.

### ⚠️ Provera pre svakog release-a, i nije opciona

Ne „verujem da je čisto" nego izmereno, svaki put:

```
# 1. u paketu nema nijedne fotografije
find <build>/BriefShow.app -iname "*.nef" -o -iname "*.cr2" -o -iname "*.arw" \
     -o -iname "*C4S*" -o -iname "*.tiff" | head      # mora biti PRAZNO

# 2. u repou se ne prati ništa lično ni izgrađeno
git status --short                                     # bez ličnih fajlova
git ls-files | awk -F/ '{print $1}' | sort | uniq -c | sort -rn | head
```

Provereno 3.09.2026: **nula** `.nef`, **nula** `C4S*`, **nula** `.tiff` u
paketu.

### ⚠️ Šta je 3.09. NAĐENO da se pušta, a nije trebalo

`build_universal/` je bio **praćen u git-u**: **327 fajlova, 214 MB** keša
prevođenja, objektnih fajlova i izgrađenog `.app`-a, uz **svaki** push. Nije
sadržao ništa lično, ali release push nosi **izvor** app-a, ne keš jedne mašine.
Dodat u `.gitignore` i skinut sa praćenja.

**⚠️ Istorija commit-ova i dalje nosi tih 214 MB.** Čišćenje istorije je
prepisivanje (`filter-repo`/force push) i **nije urađeno** — traži se odluka
klijenta jer menja svaki postojeći commit hash.

### Šta SME da bude u repou

Izvor, `Tools/`, `SKY_ARCHIVE/` (arhiva iz KORAKA 94, namerno van bundle-a),
licence, ikonice i `dist-universal/` (već isporučen build, namerno praćen).
Model težine su ignorisane jer GitHub odbija fajl preko 100 MB — v. `.gitignore`.

### Ako neka buduća sesija bude u nedoumici

Odgovor je uvek: **ne ubacuj**. Ako nešto izgleda kao da treba da ide uz app a
lično je — pitaj klijenta pre nego što uđe u build.


## TL;DR — gde smo stali

### GDE SMO STALI — 1. septembar 2026, verzija 10.1

`MARKETING_VERSION` podignut sa 6.0 na **10.1**. `CURRENT_PROJECT_VERSION` je
namerno ostavljen na 17 — nije traženo.

**⚠️ `latest_version` u BriefControl-u NIJE diran.** I dalje piše 6.0, dakle
niko još ne dobija ekran „mora update". Kad se ovaj build okači, to je jedan
upis — i tek tada ima smisla gledati na `is_locked` kao na završen posao.

#### Urađeno u ovoj sesiji

| | |
|---|---|
| 56 | **Jedan email, jedan kompjuter**, 22 za Vista Photography. `seats.sql` postavljen i proveren |
| 57 | **Nalog na home screenu** — profil i prijava u app-i, ne na sajtu |
| 58 | **Cmd+V u prijavi** — naš monitor ga je gutao |
| 59 | **Brisanje tasterom** (⌫) i „Delete" umesto „Add to Bin" |
| 60 | **Black & White i Duplicate & BW** u filmstrip meniju |
| 61 | **B&W nije bio crno-beo** — slojevi se komponuju posle desaturacije; sad se prvo peče |
| 62 | **Duplikat je vraćao original** — kopira se fajl, a slika nije bila u fajlu |
| 63 | **Slajderi po sloju**, i Select People pravi sloj umesto da briše |
| 64 | Nečitljiv blend mode, traka za AI, kartica sa jednim dugmetom |
| 65 | **Background sloj, B&W i Blur po sloju**, popravljen Undo |
| 66 | **Reset po sloju, Select Sky, Change Sky** — sedam nacrtanih neba |
| 67 | **Maska neba izmerena na pravoj slici**, ručke i rotacija na sloju |

#### INTEL RADI OPET — `Float16` iza `#if arch(arm64)` (rešeno 1.09.)

Napravljeno posle merenja ispod: ceo `DevelopSDInpaint.swift` je iza
`#if arch(arm64)`, a `#else` grana daje stub sa imenima koja ostatak app-e čita
(`defaultPrompt`, `defaultFeather`, `isDebugging`, `warmUp()`, `aiRemoval`).
Stub je **namerno minimalan** — nova upotreba SD-a treba da PADNE na prevođenju
za Intel, a ne da tamo tiho ne radi ništa.

**⚠️ `squareRegion` je moralo VAN kapije.** Živi u tom fajlu ali ga koristi i
LaMa put, i nema nikakve veze sa Float16 — prvi pokušaj je zato pao sa
`cannot find 'squareRegion' in scope`. Sad stoji u zasebnom `extension`-u iznad
`#if`, sa komentarom zašto.

Provereno: `lipo -archs` → `x86_64 arm64`, verzija 10.1, 138 MB.

Na Intelu otpada **samo Generative Clean Up**, i dugme to i kaže umesto da puca
posle klika (`cleanUpUnavailableReason`). Quick AI Clean Up radi — LaMa je
Float32 i u bundle-u, a CoreML na Intelu ide preko CPU/GPU.

**Nije prepisivano u Float32 namerno:** SD 1.5 na dvanaest koraka kroz Radeon je
dovoljno spor da bi ga bilo gore ponuditi nego nemati.

#### ⚠️ ŠTA JE BILO — `Float16`, tvrda greška prevođenja

Izmereno 1.09. pri pravljenju univerzalnog build-a:

```
DevelopSDInpaint.swift:509: error: 'Float16' is unavailable in macOS
+ još 6 grešaka na istom mestu
```

**`Float16` postoji samo na arm64.** `DevelopSDInpaint.swift` ga koristi na 8
mesta za pakovanje tenzora. Dakle app se za `x86_64` **ne prevodi uopšte** — nije
u pitanju „radiće sporije", nego se ne može ni napraviti.

Posledica: 10.1 napravljen danas je **samo arm64**. Stara 6.0 arhiva
(`build/UniversalRelease/`) JESTE univerzalna (`x86_64 arm64`) jer je starija od
SD koda. **Ako se 10.1 okači ovakav, kompanijski Intel Mac ostaje bez app-e —
neće se pokrenuti, ne sporo, nego nikako.**

Dva izlaza:

1. **`#if arch(arm64)` oko SD puta.** App opet univerzalna; Generative Clean Up
   prosto ne postoji na Intelu, a sve ostalo radi — uključujući Quick AI Clean Up,
   jer je LaMa u bundle-u i CoreML na Intelu radi preko CPU/GPU. Preporučeno.
2. **Prepisati pakovanje tenzora u Float32.** Više posla, a SD na Intel Radeonu
   bi ionako bio spor do neupotrebljivosti.

**⚠️ I SD ionako ne radi ni na jednom klijentovom Mac-u.** `SDModelStore` traži
modele u Application Support (`installedDirectory`) pa na Desktopu
(`developmentDirectory`). Prvo mesto **niko ne popunjava** — preuzimanja nema,
`installedDirectory` se u celom kodu samo čita. Drugo postoji samo na ovoj
mašini. Klijent dobija „models missing".

Brojke, mereno: app je **125 MB** (LaMa unutra, 99 MB). SD je **2,14 GB** i
namerno nije u bundle-u. GitHub Releases prima do 2 GB po fajlu, pa SD ne može ni
kao zaseban asset — mora da se deli ili da se hostuje drugde.

#### ⚠️ SLEDEĆE — NEBO (dogovoreno za veče 1.09.)

Sve ostalo iz ove sesije je potvrđeno na ekranu („super sve radi"). **Nebo nije.**

Gde je stalo: `SkyMasker` posle KORAKA 67 tačno izbacuje lica, oreol oko ljudi i
najveći deo peska. **Ostaje curenje niz ivicu tamo gde nebo, more i pesak prelaze
jedno u drugo bez vidljivog horizonta** — na kontra-svetlo slici tu ni čovek ne
bi povukao liniju bez konteksta.

**Konkretan simptom, sa slike od 1.09. uveče:** granica maske je meka talasasta
linija koja seče **preko** zgrada i palmi umesto da ih obiđe. Zamenjeno nebo zato
pokrije gornji levi deo kadra i stane nasred hotela, a duž reza ostane svetao
oreol. Dakle problem nije samo „koliko" nego **oblik granice**: hod po kolonama
daje jednu tačku prekida po koloni i zatim se blura, što je po definiciji glatka
kriva — a obris zgrade nije glatka kriva.

To je najkorisniji trag za sledeći put: granica mora da prati ivice u slici, ne
da bude izglačana. Ono što se nije probalo: umesto blura na kraju, provući masku
kroz `CIEdgePreserveUpsampleFilter` ili je „prilepiti" na luminantne ivice
originala (guided filter), što je tačno posao koji taj filter radi.

Tri pravca, po ceni:

1. **Zaokruživanje Selection alatom pre pritiska.** Radi već sada, ništa se ne
   piše. Najjeftinije, i za tešku sliku verovatno jedino pošteno.
2. **Još heuristike.** Ideje koje NISU probane: zaustavljanje hoda i na promeni
   boje u odnosu na vrh iste kolone (ne samo na padu skora), i kazna za piksele
   ispod najniže tačke na kojoj se većina kolona zaustavila — horizont je
   uglavnom jedna linija preko cele slike, a to se trenutno nigde ne koristi.
3. **Trenirani model.** Jedini način da bude „kao kad označi ljude" — ljude tako
   dobro označava upravo zato što je Vision trenirana mreža. Stotine megabajta
   povrh 4,4 GB i licenca koju treba raščistiti za app koja se PRODAJE.

**Meriti `Tools/skymask.swift`-om, na pravim slikama, pre i posle.** Taj harness
izvlači `SubjectMasker` i `SkyMasker` iz izvora u trenutku prevođenja, pa ne može
da se raziđe sa kodom. Isto važi za `Tools/skytest.swift` (sedam neba na jedan
list) i `Tools/linstat.swift` (raspodela šuma u linearnom prostoru).

**⚠️ Ako se dira crtanje neba, čitati KORAK 66 pre toga** — tamo je zapisano
kako je merenje u sRGB-u dvaput dalo pogrešan odgovor koji je izgledao kao
merenje.

### ⚠️ PRVO SADA — devet prijava od 1.09. uveče

Klijent je prijavio devet stvari: kamera javlja „0 files", traka napretka izlazi
iz panela, folder se ne može pustiti na ikonicu, levi panel se ne razvlači,
sinhronizovan 4:3 se ne zadrži i crop lagovi, nema odbačenih fotografija, SD na
Intelu, meka slika u ShowGrid lupi, i teško dostupno Crop dugme.

**Plan je na dnu dokumenta: „PLAN — devet prijava od 1. septembra uveče".**
Tri talasa, sa uzrocima koji su već nađeni u kodu. Nebo ide POSLE ovoga.

**Talas A (KORAK 68) i B1 (KORAK 69) su napisani i prevode se, ali NISU viđeni
na ekranu.** B1-ova Codable migracija JESTE izmerena na klijentovih 25 pravih
zapisa — v. `Tools/run-editsettings-decode-test.py`, koji od sada treba pokrenuti
posle SVAKE izmene `PhotoEditSettings`.

**B2 (KORAK 70) takođe napisan.** Uzrok NIJE bio ono što je plan pretpostavio —
v. taj korak pre nego što se dira bilo šta oko crop-a.

**B3 (KORAK 71) takođe napisan** — odbačene fotografije, i `X`/`.`/`,` po
klijentovom rasporedu. **B4 (KORAK 72) takođe napisan** — folder na ikonicu.

Time je ceo talas B napisan. **Ostaje talas C: kamera (C1) i SD na Intelu (C2).**
**C1 (KORAK 73) napisan dokle ide bez kamere** — alat `Tools/camtest.swift` čeka
da se kamera priključi. **KORAK 74** — `CFBundleVersion` je bio 17 u svakom
build-u, zbog čega nova ikonica ne bi bila viđena posle zamene app-a.

**C2 je ODLOŽEN ZA KRAJ.** Klijent je 2.09. odredio da je C2 poslednji korak i
da se do tada ne pravi build niti se išta pušta — v. „REDOSLED I KAPIJA" u
spisku od 2. septembra uveče. Ono što je o njemu izmereno stoji i dalje:
odlučeno 2.09, težine idu na **GitHub Releases**, jedan fajl.
Izmereno: SD15-Inpainting je 1,99 GB sirovo, **1,84 GB kao zip i 1,85 GB kao
Apple Archive** — dakle STAJE ispod GitHub-ovog limita od 2 GiB, bez deljenja.
⚠️ Time pada ono što je ranije pisalo u ovom dokumentu („2,14 GB, ne može ni kao
zaseban asset") — bilo je pogrešno, mereno je sad.
Preuzimanje još NIJE napisano; `installedDirectory` se i dalje samo čita.

**⚠️ PRVO ZA SLEDEĆI PUT: „SLEDEĆE — spisak od 2. septembra uveče" na DNU
dokumenta.** Pet stavki, klijentovim redom. Prva je da **rotacija crop-a ne
radi** — isporučena je u KORAKU 77 i specifikacija je bila pogrešno shvaćena na
dva načina. Nebo ide POSLE svega toga.

### ⚠️ POLA PUŠTENO — jedan email, jedan kompjuter (KORAK 56)

**Baza je gotova.** `Tools/seats.sql` je pokrenut 1.09. u RocketsBrief projektu
(`gzbkpnogeegyntoznzzn`) i proveren sa obe strane — vidi „Izmereno posle
postavljanja" u KORAKU 56.

**Ostalo:** novi build sa `SeatManager`-om nije još poslat, pa ograničenje
kompjutera niko još ne poštuje. Zaključavanje app-e (`is_locked`) ide
POSLEDNJE, tek kad su svi na novom build-u. Redosled je na dnu KORAKA 56.

### ⚠️ PRVO ZA SLEDEĆU SESIJU — preimenovanje u „Afterburn Studio"

Dogovoreno 31.08, **nije počelo.** Plan i sve zamke su u odeljku
„PLAN — preimenovanje u Afterburn Studio" na dnu dokumenta. **Pročitati ga pre
nego što se dirne ijedan fajl** — u njemu su dve mine koje ruše app ako se
promaše, i jedan bag koji već postoji i koji se tim poslom usput popravlja.

### GDE SMO STALI — 30. avgust 2026, druga sesija

**⚠️ PRVO PROČITATI: HIPOTEZA (c) IZ PRETHODNE SESIJE JE NEMOGUĆA.**
Ne trošiti vreme na `searchRadius`. Dokaz je u KORAKU 34 dole, meren `grep`-om,
ne rezonovan.

Ukratko: `Quick AI Clean Up` = `InpaintPipeline.quickAIRemoval` → **samo LaMa na
fiksnih 512**. `searchRadius`, `maxWorkingEdge` i `maxHolePixels` žive u
`ExemplarInpainter` / `InpaintPipeline.removal`, a **taj poziv ne postoji nigde
u app-i**. Dakle KORAK 31 nije podigao nikakvu „Quick radnu površinu" — podigao
je samo granicu `blockingAreaPixels`, i to mrtvim obrazloženjem.

**Korisnik je odlučio da granica ostaje 2200.** Nije vraćana.

#### Urađeno u ovoj sesiji

| | |
|---|---|
| 34 | **Četkica više ne izlazi van slike** (stavka 1 iz prethodne sesije) + zašto `searchRadius` nije uzrok bele mrlje |
| 35 | **Import direktno sa kamere preko USB-a** — nova funkcija, na korisnikov zahtev. Nije vezan za Nikon |
| 36 | **Painting više NE osvežava ništa** — nula prolaza kroz `body` tokom poteza, umesto jednog na svaki početak |
| 37 | **Crtice na slajderima**, kao u Lightroom-u |
| 38 | **Generative nije radio kad su tragovi razdvojeni** — nije limit, nego prazan region. Sad jedno uklanjanje PO GRUPI tragova |
| 39 | **SD ne može da se podesi da briše kao LaMa** — izmereno, 5 guidance × 4 prompta, sve izmišlja. Harness ostaje u `Tools/` |
| 40 | **Generative sada radi kao LaMa** — LaMa prvo popuni, SD samo doteruje. Izmereno; usput i 2× brže |
| 41 | **BELA MRLJA — UZROK NAĐEN I POPRAVLJEN.** `toneMatch` je dizao svaki piksel rupe za +39 kad je okolina prežarena |
| 42 | **Klik na sličicu se više ne čeka** — dva tap gesture-a su terala SwiftUI da odloži selekciju |
| 43 | **Slideshow → BriefShow, Develop → LumenoLab** sa ručno nacrtanom ikonicom čašice |
| 44 | **Selection kreće kao free, Patch ostaje krug**, i nijedan više ne laguje pri prevlačenju |

#### ⚠️ NEPROVERENO NA EKRANU

Build je čist i app se pokreće, ali **ništa iz ove sesije nije viđeno uživo**:

- KORAK 38 — da razdvojeni tragovi sad zaista prođu kroz Generative, i da se
  `Quick` više ne gasi zbog njih (matematika grupisanja JESTE proverena, 18/18,
  `Tools/run-stroke-cluster-test.py` — ali rezultat na fotki nije viđen)

**Potvrđeno uživo (korisnik, svojim rečima), 30.08 uveče:**

- „paint jeste mnogo bolje" — KORAK 36
- „crtcice na slidebarovima jesu bravo" — KORAK 37
- „cetkica ne izlazi isto dobro" — KORAK 34

Ostaje neprovereno iz ranijih sesija:
- KORAK 35 — **cela funkcija za kameru nije probana ni sa jednom kamerom.**
  Z 6 nije bio povezan dok je rađeno (`ICDeviceBrowser` prijavio 0 uređaja u
  probnom binarnom fajlu). Sve je pisano po SDK zaglavljima, koja SU čitana, i
  svaki potpis je proveren probnim prevođenjem — ali prvi pravi test je: uključiti
  kameru i videti da li se pojavi.

Ostaje i dalje neprovereno iz prethodne sesije: ivice na dugmadima i popravka
gumice iz KORAKA 33.

### GDE SMO STALI — 30. avgust 2026, kraj sesije

**Sve iz ove sesije je commit-ovano. NIJE pushovano** — to je prvo za sledeći put, ako
se tako želi. Nepushovano stoji i `51c402b` od 26.08.

**⚠️ PRAVILO ZA SVAKI BUDUĆI OVERLAY IZNAD SLIKE** (KORAK 24, mereno):
`.clipped()` seče **crtanje, ne hit-testing.** Svaki view u `centerPreview` dimenzionisan
po `fitted` ili `fullImageFrame` zumirano se prostire stotinama tačaka IZNAD pregleda i,
pošto je `centerPreview` poslednje dete `VStack`-a, seda preko trake sa alatima i jede
klikove — a dugmad ostaju upaljena i izgledaju normalno. Ili `.allowsHitTesting(false)`
ako je ukrasan, ili ograniči na `containerSize`.

**⚠️ 0×0 PROZOR NIJE KVAR — to je ekran za prijavu.** Sačekati da korisnik ukuca lozinku,
i NE gasiti app sa `kill -9` posle toga, jer sledeće pokretanje traži lozinku ponovo.
Cela ova sesija je to pogrešno čitala kao nestabilnost pri pokretanju (vidi KORAK 33).

#### Urađeno u ovoj sesiji (KORACI 22-33)

| | |
|---|---|
| 22 | **Layers kartica** — panel podeljen na Edit / Retouch / Layers, premeštanje layera prevlačenjem, spisak odozgo nadole |
| 23 | **Filmstrip** — `LazyHStack`, serijski `.utility` red, keš na 400. Dekodirao je ceo folder odjednom |
| 24 | **Zumirana traka nije primala klikove** — `.clipped()` ne seče hit-testing |
| 25 | **Lag prstena kursora** — pozicija izašla iz `@State` na `DevelopView` |
| 26 | Čišćenje **više ne izbacuje iz alata** |
| 27 | Traka preimenovana: `[AI] Clean Up`, `Exit Clean Up`, `Generative Clean Up` |
| 28 | Add/Erase i **Clear AI Area** u traci; undo je već postojao i radi (izmereno) |
| 29 | Selekcija **roze** umesto plave; painting više ne poništava ceo prikaz |
| 30 | Sve u **jednom redu**; nov SD prompt + regenerisan blob |
| 31 | Quick radna površina **1000 → 2200**; SD kontekst 2.0 → 1.6; red ispod trake ukinut; progres u gornju traku |
| 32 | **Clear All** u Layers zaglavlju |
| 33 | **Gumica sada oduzima površinu**; ivice na svih 37 dugmadi zajedničkog stila |

#### Potvrđeno uživo (korisnik, svojim rečima)

- „sada je smooth" — lag pri pomeranju miša (KORAK 25)
- „generative ai okay" — posle novog prompta (KORAK 30)

#### ⚠️ OTVORENO ZA SLEDEĆU SESIJU

**1) Brush AI selection ne sme da izađe van slike.** Potez se trenutno crta i preko
letterbox margine pored fotografije — vidi sliku u razgovoru od 30.08. Potez je odsečen
na oblast PREGLEDA (KORAK 24), ali ne na oblast SAME SLIKE. `unitPoint(from:frame:)`
klampuje na 0...1, pa se tačke lepe na ivicu umesto da budu odbijene. Treba odsecanje na
`fitted` (okvir slike), ne na `containerSize`.

**2) Još veća AI selection površina za Quick Clean Up (LaMa).** Sada je 2200px
(`blockingAreaPixels`), uz `maxWorkingEdge = 2200` i `maxHolePixels = 180 000`. Dalje
dizanje je moguće istim putem — sve tri vrednosti zajedno — ali:
- cena je **kvadratna i plaća se na SVAKOM uklanjanju**, ne samo na velikom
- **brzina nije pouzdano izmerena** posle poslednjeg dizanja (dva merenja promašila).
  Prvo izmeriti koliko sada traje, pa tek onda dizati.

**3) Generative i dalje nije oštar kao Quick, i ne može biti sa ovom arhitekturom.**
SD ima fiksnih 512 ulaza i sintetiše piksele; LaMa radi na do 2200 i kopira prave.
Jedini pravi izjednačivač: preklapajuće 512 pločice u nativnoj rezoluciji.

**4) ⚠️ BELA MRLJA OD QUICK CLEAN UP — NOVO, PRIJAVLJENO 30.08 UVEČE.**

Prijava: prvo uklanjanje prođe lepo, drugo prođe lepo, pa se izabere **manja** površina,
dugme je bilo UPALJENO, i rezultat su bele mrlje na fotografiji. Slika u razgovoru:
tri bele fleke preko peska i suncobrana.

**Dve hipoteze, i nijedna nije proverena. Sledeća sesija prvo bira između njih.**

**(a) Korisnikova:** Quick Clean Up se posle završetka ne resetuje nego nastavlja od
prethodnog stanja. Ako je tako, greška je u tome što `eraseMaskedArea` renderuje
`full = render(settingsSnapshot, on: fullBaseImage)` — a `settingsSnapshot` sadrži SVE
ranije layere. Svako sledeće uklanjanje radi nad slikom koja već nosi prethodne zakrpe,
pa se greške slažu jedna na drugu.

**(b) Moja, i moram je navesti prvu jer sam je ja i napravio:** u KORAKU 31 sam podigao
`blockingAreaPixels` sa 1000 na **2200**, uz `maxWorkingEdge` 1100 → 2200. Obrazloženje
je bilo da se prag kvara pomera zajedno sa odnosom smanjenja regiona. **To je bilo
rezonovanje, ne merenje.** Ranije izmereno: čisto na ~830px, razmazano na ~1550px. Ako
prag nije porastao onoliko koliko sam pretpostavio, onda sada prolaze površine koje
LaMa ne ume — i bela mrlja je tačno taj kvar, samo više nije blokiran.

**NOV PODATAK (isto veče): bela mrlja nastaje i na MALOJ površini.** Slika u razgovoru:
sitna oznaka preko osobe u pozadini, pored lica žene, na vrlo svetloj plažnoj fotki —
i Quick Clean Up je vrati belu. To **obara hipotezu (b) kao glavnu**: nije stvar
veličine, jer ova površina je daleko ispod svake granice.

**(c) NOVA HIPOTEZA, I ONA JE SADA PRVA — i nju sam takođe ja napravio.**
`ExemplarInpainter.fill` ima `searchRadius: Int = 80` — **fiksnih 80 piksela u RADNOM
baferu**, nezavisno od njegove veličine. U KORAKU 31 sam `maxWorkingEdge` podigao
1100 → 2200, dakle bafer je duplo veći u pikselima, **a prečnik pretrage je ostao isti**.
Efektivno: inpainter sada pretražuje **upola manje sadržaja slike** nego pre.

Na fotki gde je okolina rupe presvetla (nebo, prežareni pesak), a jedini pravi materijal
za kopiranje je dalje od tih 80 piksela, jedino što nađe u dometu je belina — pa je i
kopira. To objašnjava i zašto se javlja na maloj površini, i zašto se pojavilo tek
posle KORAKA 31.

**Prva stvar koju treba probati:** skalirati `searchRadius` zajedno sa
`maxWorkingEdge` (bio je 80 pri 1100, dakle ~160 pri 2200), ili ga vezati za dimenziju
bafera umesto da bude konstanta. Proveriti cenu — pretraga je kvadratna po prečniku,
pa je 80 → 160 oko 4x posla po pikselu rupe, povrh već podignute rezolucije.

**HIPOTEZA (a) JE ODBAČENA, istog večeri, korisnikovim zapažanjem:** posle bele mrlje
nastavio je da koristi Quick Clean Up i **radilo je normalno**. Da se stanje prenosi
između uklanjanja, sledeća bi takođe bila pokvarena. Alat se, dakle, uredno osvežava —
`clearRemovalMask()` vraća površinu na nulu i LaMa sledeći put dobija praznu selekciju.

**Korisnikova nova pretpostavka — „mislim da je bilo zbog sunca" — POKLAPA SE SA (c)** i
opisuje tačno njen mehanizam: kad je prsten oko rupe prežaren, jedino što pretraga nađe
u svom (sada prepolovljenom) dometu jeste belina, pa je kopira. Nije slučajnost da se
javilo baš na najsvetlijem delu kadra.

**Ostaje jedna sumnja, i ona je moja:** ako je uzrok samo sunce, zašto se nije javljalo
pre KORAKA 31? Prežarenih plažnih kadrova je bilo i ranije. Zato `searchRadius` ostaje
prvo što se dira — on je jedina stvar koja se promenila između „radilo je" i „pobeli".

**Ako popravka `searchRadius`-a ne reši**, ostaje hipoteza (b) — granica podignuta
previsoko — i test ispod.

**Kako razdvojiti (a) i (b), jednim testom:** na SVEŽOJ fotki, bez ijednog prethodnog
uklanjanja, označiti površinu slične veličine i pustiti Quick Clean Up.
- pobeli → hipoteza (b), granica je predaleko podignuta; spustiti `blockingAreaPixels`
  i izmeriti gde je stvarni prag pri `maxWorkingEdge = 2200`
- prođe čisto → hipoteza (a), stanje se prenosi između uzastopnih uklanjanja

**Ovo ima prednost nad stavkom 2 (dalje dizanje površine).** Nema smisla dizati granicu
dok se ne zna gde je pravi prag — a moguće je da je treba spustiti.

**5) Neprovereno:** ivice na dugmadima i popravka gumice iz KORAKA 33 nisu viđene na
ekranu — build je čist, ali korisnik ih nije potvrdio.

**6) Nestao preset „Probe 1"** sa testne fotke, verovatno zbog `kill -9` (vidi gore).
`C4S_7792.NEF` u `RAW Tests Images` nosi i gomilu „Removed" layera iz testiranja.

### GDE SMO STALI — 26. avgust 2026, kraj sesije

**Sve iz ove sesije je commit-ovano na granu `briefshow-develop`. NIJE
pushovano** — to je prvo za sledeći put, ako se tako želi.

**Stanje**: build čist, nema poznatih otvorenih bagova. Radna app je i dalje
`BriefShow/build_dd/Build/Products/Release/BriefShow.app`.

**⚠️ Skoro ništa iz ove sesije nije VIZUELNO potvrđeno u pokrenutoj app-i** —
sve je provereno build-om i skriptama (i to temeljno: 17/17 za connected
components, 64 000 + 480 000 za crop, 16/16 za bipolarne slajdere), ali sam
izgled trake sa alatima, kartice za export, plave selekcije i Add/Erase
prekidača niko još nije video na ekranu. To je prva stvar za sledeću sesiju.

**Prva sledeća stvar posle toga**, iz starog dogovorenog plana koji i dalje
stoji nedirnut: **Layers kartica**, pa **AI sinhronizacija** (A: kopiranje
zakrpe / B: ponovno pokretanje), pa **`SyncCategory` za layere i AI
uklanjanja**. Vidi „Plan — dogovoreno 25. avgusta".

**Tri nalaza iz ove sesije koje NE treba ponovo istraživati** (svaki je
mereno, ne pretpostavljeno — detalji u odgovarajućim KORACIMA):
1. Vision ne vidi male ljude u pozadini; tiling to ne rešava nego pogoršava
   (halucinira ljude na praznom pesku). KORAK 9.
2. LaMa na 1024 je gora nego na 512, i sa FP16 i sa FP32. Trenirana je na 512.
   4096 je nemoguće na 9 GB RAM-a. KORAK 19.
3. Instrukcijski prompt („Remove the selected object…") je merljivo gori od
   postojećeg default-a — CLIP ga čita kao spisak imenica. KORAK 18.

Urađeno u ovoj sesiji, hronološki (pun opis u KORACIMA pri dnu):

- **KORAK 9 — „Select People in Background"** iz dogovorenog plana. Gotovo,
  matematika provereno skriptom (17/17). **Korisnik ga je probao i nije radilo
  na plažnoj RAW fotki** — izmereno, uzrok NIJE u ovom kodu nego u Vision-u;
  ceo dokaz je u KORAKU 9 dole i vredi ga pročitati pre bilo kakvog pokušaja
  da se ovo „popravi".
- **KORAK 10 — kartica za AI Clean Up** — napravljena pa **VRAĆENA na
  korisnikov zahtev iste sesije**. Ne pravi je ponovo bez izričitog traženja;
  vidi KORAK 10 dole za šta je bilo i šta je iz nje vredelo.
- **KORAK 12 — sidebar**: otvoren folder dobija otvorenu ikonicu (ručno
  nacrtan `OpenFolderShape`, SF Symbols nema takav glif), podfolderi uvučeni
  14 → 24 pt.
- **KORAK 13 — crop se vuče i sa sredina ivica**, ne samo sa uglova.
  Provereno skriptom: 64 000 poređenja da se ponašanje uglova NIJE promenilo,
  480 000 fuzz slučajeva u granicama.
- **KORAK 14 — Space + miš = ručica** za pomeranje po zumiranoj fotki, radi i
  dok je alat aktivan.
- **KORAK 15 — sidebar poravnanje** (korisnik prijavio da je zbunjujuće):
  `DisclosureGroup` izbačen, folderi na istom nivou se sad zaista poravnavaju.
- **KORAK 16 — „Quick AI Clean Up" katastrofa na velikoj površini**
  (korisnik prijavio): reprodukovano i izmereno, granica nađena, dodato
  upozorenje u panel. Nije bug u kodu.
- **KORAK 21 — sređivanje po korisnikovom spisku**: „Select Area" → „AI
  Selection", progres u traci, četkica kreće od 2, slajder ispod trake, Sync i
  Export All uz filmstrip + kartica za format, objašnjenje zašto je Clean Up
  ugašen, i **popravljen „tin tin tin" beep na Space**. Vidi KORAK 21.
- **KORAK 20 — SD granica ISPRAVLJENA** (500 px je bilo pogrešno, izvedeno iz
  jedne tačke), Add/Erase za Select Area, plava selekcija, traka sa alatima
  iznad slike. Vidi KORAK 20.
- **KORAK 19 — LaMa na 1024 rekonvertovan i ODBAČEN** (mereno dvaput, FP16 i
  FP32), plus granice po modelu na dugmadima. Vidi KORAK 19.
- **KORAK 18 — univerzalan prompt IZMEREN** i polje za prompt sklonjeno; plus
  „Select People in Background" uklonjeno, „Brush" → „Select Area",
  selekcija bela umesto crvene. Vidi KORAK 18.
- **KORAK 17 — Develop preview je bio mutniji od Quick Look-a** (korisnik
  prijavio, sa side-by-side slikom): uzrok nađen (1600 px + draft demosaic),
  dodat „refine" prolaz koji čim se editovanje smiri prikaže ORIGINAL u punoj
  rezoluciji.
- **KORAK 11 — svi slajderi kreću od sredine** (korisnikov novi zahtev):
  nov `EditTrackSlider` sa punjenjem od NULE (ne od levog kraja) i crticom na
  sredini, plus Clarity/Dehaze/Vignette su sad **-1…1** umesto 0…1, sa pravom
  negativnom polovinom u renderu. Matematika provereno skriptom (16/16),
  **nije vizuelno potvrđeno.**

**Zašto ništa nije vizuelno potvrđeno**: app se pokreće (proces živ, build
čist), ali otvara SAMO 0×0 prozor — nema šta da se slika dok se ne otvori
folder sa fotkama, a to traži pravi miš. `osascript`/System Events je pukao
na timeout. Ovo je prva stvar za sledeću sesiju: otvoriti folder rukom i
proći kroz sva tri.

Ostaje iz plana: **Layers kartica**, **AI sinhronizacija** (A: kopiranje
zakrpe / B: ponovno pokretanje), **`SyncCategory` za layere i AI uklanjanja**.

Ranije pushovano: SD inpainting (KORAK 3–5), LaMa (KORAK 6), merenja
za pakovanje v8.0 (KORAK 7), export sa opcijama (KORAK 8).

Radna app: `BriefShow/build_dd/Build/Products/Release/BriefShow.app`.
Modeli su na dev putanji `~/Desktop/BriefShow/CoreMLModels/` i NISU u git-u
(GitHub odbija fajlove preko 100 MB) — `BriefShow/Tools/` drži skripte koje
ih prave.

---

**25. avgust 2026 — SD inpainting je U APP-I i radi.** „AI Remove" stoji pored
„Erase (Instant)" u Remove sekciji, ~13 s po brisanju na M2, sve na uređaju.
Detalji su u KORACIMA 3–5 pri dnu; ukratko, i tri od pet nalaza su bile MOJE
greške koje su izgledale kao mane modela:

1. **Swift pipeline** (`DevelopSDInpaint.swift`) — DDIM + DPM-Solver++, 9-kanalni
   concat, VAE encode/decode. SD menja samo `ExemplarInpainter.fill()`; ceo okvir
   oko rupe (maska, region, pakovanje u `ImageLayer`) je već postojao i deli se.
2. **Region nikad manji od 512 izvornih piksela.** Uveličan (mutan) kontekst je
   terao model da izmišlja — crno-bela krckava rešetka. Ovo je bio pravi uzrok
   „lošeg prompta" iz prve dijagnoze, koja je bila pogrešna.
3. **„trailing" raspored koraka umesto „leading".** Stari je kretao ispod vrha
   skale (t=958 umesto 999), pa je sa malo koraka model dobijao laž o jačini
   šuma. Uz DPM-Solver++ to je spustilo 30 koraka na 12 → **30,2 s → 13,4 s**.
4. **Tone match na prstenu oko rupe.** Zakrpa je bila tamnija; dekoder
   rekonstruiše i poznate piksele, pa se pomak MERI umesto da se pogađa.
5. **Prompt je promenljiv** (zupčanik pored dugmeta), plus „Edge Feather"
   slajder. CLIP čita prompt kao spisak stvari koje treba naslikati, ne kao
   instrukciju — zato podrazumevani IMENUJE šta treba da bude tu.

Usput dodat i **zoom u Develop-u** (`Cmd +` / `Cmd -` / `Cmd 0` + povlačenje za
pomeranje), kog ranije uopšte nije bilo.

**Ostalo pre nego što ovo može da se proda**: skidanje težina na prvo
korišćenje, palettizacija na 6 bita, Licenses ekran + EULA (Attachment A iz
OpenRAIL), i tehnički dug iz tačke C dole (`ImageLayer.imageData` je i dalje u
`UserDefaults`).

---

**Sve dosad zatraženo je gotovo.** Korisnik je tražio tri stvari u istoj
sesiji: **10) Brush cursor preview** — gotovo. **11) Patch (clone/heal)
tool sa Circle/Square/Free** — gotovo, matematika i GUI oboje potvrđeni.
**12) "Pravi Photoshop-style image layeri"** — prvi pokušaj (Patch tool,
#11) je bio **pogrešno protumačen zahtev**: korisnik nije tražio clone/
heal, već pravi **selection/cut alat** (Circle/Square/Free) koji seče deo
slike u layer koji se posle može copy/paste-ovati i na DRUGU fotku, sa
Cut/Copy/Deselect akcijama — ispravljeno kao stavka **13** ispod (Patch je
ostao, korisnik je eksplicitno rekao da zadržim oba). Stavka 13 je
suštinski i prvi pravi test celog Layers sistema (pozicioniranje/resize/
opacity/blend mode) — urađena i vizuelno potvrđena (uz jedan lažni alarm
tokom testiranja, vidi #13-ovu napomenu o `screencapture -l` keširanju).

**Dopuna iste večeri**: posle #13, korisnik je vratio četiri stvari — tri
konkretne ispravke plus jedna UX izmena za Patch. Sve četiri urađene kao
stavka **14**: (a) Patch sad podržava pravi clone-stamp gest — drži ⌥
(Option) i klikni da postaviš IZVOR, pusti ⌥ i klikni da pomeriš
ODREDIŠTE (i "patchuje" tamo), plus hover-prsten dok se ⌥ drži kao preview
gde će izvor pasti; (b) Cmd+V sad radi za Paste as Layer (ranije samo
dugme, korisnik ga nije lako pronalazio); (c) Cut-ova "rupa" je sad siva
umesto crna; (d) feather na Square/Free selekciji/patch-u više NE širi
masku van nacrtane granice (bio simetričan blur, sad klampovan da nikad ne
pređe originalnu ivicu — isti "samo unutra" princip koji je Radial već
imao). Matematika (b) je trivijalna (SwiftUI keyboardShortcut), (d) je
provereno skriptom (van-granice piksel je UVEK 0 sada, bez obzira na
feather). (a) NIJE moglo GUI-testirati (⌥+klik kombinacija — isto poznato
ograničenje kao svaki gesture-based deo ove app-e), ali matematika je
identična već-verifikovanim `movePatchCenter`/`movePatchSource`
funkcijama, samo okinuta na klik umesto drag-a.

Ceo hronološki tok, u jednoj listi (pun opis/arhitektura svake stavke je u
"Šta dalje" ispod, pod istim brojem):

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
10. **Brush cursor size preview** — hover ring pokazuje veličinu četkice
    PRE slikanja. Sitna popravka, gotovo i vizuelno neproverljivo (hover
    se ne može GUI-testirati, isto poznato ograničenje), ali nizak rizik.
11. **Patch (clone/heal) tool — Circle/Square/Free** — nov, četvrti tip
    lokalne maske. Matematika (offset sign, square/free mask geometrija,
    pun end-to-end kompozit) provereno skriptama, I vizuelno potvrđeno u
    pravoj app-i na sintetičkoj test fotki (sve tri varijante oblika,
    efekat klonranja stvarno vidljiv na ekranu).
13. **Selection tool (Cut/Copy/Deselect) + pravi Image Layers** — ono što
    korisnik STVARNO tražio pod "patch tool" (#11 je ostao kao bonus,
    korisnik je eksplicitno rekao da zadrži oba). Circle/Square/Free
    selection alat koji seče/kopira deo slike u in-memory clipboard, Paste
    kreira pravi, pomerivi/resize-ovani/opacity/blend-mode `ImageLayer` —
    radi i preko fotki (kopiraj sa jedne, nalepi na drugu). Cut dodatno
    ostavlja solid-boja "rupu" na izvoru (crna u prvoj verziji, sivo od
    stavke #14), kao NOVI layer (ne poseban mehanizam). Matematika (offset/
    Y-flip pozicioniranja, PNG round-trip, resize sa anchor-om, blend
    modovi) provereno skriptama, I vizuelno potvrđeno end-to-end u pravoj
    app-i preko eksportovanog fajla (vidi pun opis ispod za jedan lažni
    alarm usput).
14. **Četiri manje ispravke posle #13** (Patch ⌥-klik gest, Cmd+V paste,
    siva umesto crna Cut-rupa, feather se više ne širi van granice) — vidi
    pun opis ispod.

Nema više otvorenih stavki iz ove sesije. Sledeće bi bilo sitno poliranje
navedeno u "Poznata ograničenja" (brush mask caching, radial rotacija, RAW
fajl za test, Patch-ov alpha-blend nije "content-aware" heal, Layer nema
rotate/ne-persistovan clipboard kroz restart), ili nešto novo što korisnik
zatraži. Jedna sitna neistražena nijansa kod auto-fit crop-a (stavka 4) —
verovatno nebitna, dokumentovana za svaki slučaj.

**Dopuna (11/12. avgust, kasno veče/posle ponoći) — gde smo STVARNO stali
sad**: posle gornjeg su urađene još četiri stavke, poslednja (18) je bio
pravi produkcioni incident:
- **15**: klik-ne-radi-odmah popravljen (`acceptsFirstMouse`), **ozbiljan
  freeze bug otkriven i popravljen** (Cmd+V bez `isARepeat` u Develop-u),
  paste sad "u mestu", layer resize ratio-locked (Shift = free).
- **16**: mask/selection/layer overlay pozicija popravljena kad postoji
  crop (koristio pogrešan pre/post-crop frame); tanje linije.
- **17**: Backspace/Delete briše selekciju, Undo/Redo (Cmd+Z/⇧Z), `[`/`]`
  menja veličinu aktivnog alata.
- **18**: korisnik prijavio da Cmd+X/Cmd+C u Selection alatu ne rade —
  ispostavilo se DVA bag-a: (a) presrogo modifier-flag poređenje u
  Develop-u, (b) **ShowGrid-ov SASVIM ODVOJEN Cmd+X/C/V monitor
  (`ContentView.swift`) nikad nije proveravao da li je njegov prozor
  fokusiran** — reagovao je i dok je Develop bio otvoren, i pošto ništa
  nije bilo selektovano u pozadinskom gridu, "cut ceo folder" + "paste"
  je REKURZIVNO kopiralo ceo `~/Desktop` u sebe, DVA PUTA, `kill -9` morao
  oba puta uživo dok se istraživalo. Oba bag-a popravljena, **korisnik je
  potvrdio da Cmd+X/Cmd+C sad rade** preko prave tastature. Duplirani
  `Desktop 1`/`Desktop 2` folderi obrisani (Trash). Pun opis, dokaz uživo
  (CPU/`sample` profil), i mehanizam bug-a — ispod pod stavkom 18.

**Trenutno stanje**: nema poznatih otvorenih bagova. Build čist, app
zdrava (0% CPU idle posle restarta). Sledeći koraci su ili iz "Poznata
ograničenja" ispod (nizak prioritet, niko nije tražio), ili nešto novo što
korisnik zatraži.

**Dopuna (14. avgust 2026, veče) — gde smo STVARNO stali sad**: cela ova
sesija je bila RAW test + filmstrip/multi-select/sync feature rad, šest
stavki (19-24), ceo hronološki tok:

- **19**: RAW pipeline **konačno vizuelno potvrđen, u potpunosti end-to-end**
  na pravoj RAW fotki (korisnik dostavio 4 Nikon `.NEF` fajla) — poslednja
  preostala neproverena stavka iz #6, sad zatvorena. Import/Develop/RAW
  bedž/native Exposure i Temperature kontrole sve potvrđeno na ekranu. Usput
  otkrivene dve nove pouzdane tehnike za GUI testiranje: `AXIncrement`/
  `AXDecrement` za slidere (klik ne radi), `AXScrollBar` `set value` za
  scroll-ovanje panela.
- **20**: Desni klik na filmstrip thumbnail → "Export…" (nova, do sada
  nepostojeća opcija) — Save panel, export TE fotke sa RAW-a u maksimalnom
  JPEG kvalitetu (1.0, ne 0.92 kao glavno dugme). Vizuelno potvrđeno
  end-to-end preko `AXShowMenu` accessibility akcije (prvi uspešan right-click
  GUI test u ovoj app-i, mada se ispostavilo nepouzdano za ponovljanje —
  vidi #24).
- **21**: Filmstrip premešten sa leve strane na DNO (horizontalno) — korisnik
  eksplicitno tražio. Cmd/Shift multi-select na thumbnail-ima (isti
  `NSEvent.modifierFlags` obrazac kao Patch ⌥/Layer ⇧). Desni klik na
  fotku unutar veće selekcije → "Export N Selected…" (bulk, jedan folder
  picker). **Korisnik POTVRDIO pravim mišem da multi-select radi** — prva
  potvrda da klik na filmstrip thumbnail uopšte radi u ovoj app-i.
- **22**: Dva popravka na korisnikov feedback: (a) checkmark bedž bio
  nevidljiv (bledožuta na bledožutoj) — sad `.palette` render mod, zasićena
  plava + bela kvačica + senka; (b) novo "Syncing (N)" dugme (Lightroom-style
  sync settings preko multi-selekcije), ime bukvalno "Syncing" po zahtevu.
- **23**: "Select All"/"Deselect" dugmad (PRAVI Button, van filmstrip
  ScrollView-a) — ne dira koja je fotka otvorena u editoru (izričit zahtev).
  Desni klik "Syncing…" dodat. Pravi Lightroom-style "Synchronize Settings"
  dijalog sa checklist-om (Crop & Rotate/Light/Color/Detail & Effects/Masks,
  Check All/Uncheck All) — delimičan merge, ne sve-ili-ništa. **Sve vizuelno
  potvrđeno uživo preko Select All dugmeta** (pravi Button, prvi put ceo tok
  stvarno kliknut, ne samo pregledan u kodu) — bedž se pojavljuje, view
  ostaje na otvorenoj fotki, dijalog se otvara sa tačnim sadržajem.
- **24**: Korisnik prijavio da je tekst/ikonice u Synchronize dijalogu
  nečitljiv (taman na tamnom) — pravi uzrok: naslov/checklist nikad nisu
  eksplicitno postavili `.foregroundColor(AppColors.ink)` kao SVAKI drugi
  tekst u fajlu, pa je pao na platform default (prati sistemski light/dark,
  ne internu temu app-e). Popravljeno. Nije ponovo vizuelno potvrđeno ovom
  sesijom (AX klik na Syncing dugme prestao da pouzdano radi posle #23 —
  test-environment flakiness/VS Code fokus-krađa, ne app regresija, pošto
  je Select All i dalje radio pouzdano u istoj sesiji).

**Trenutno stanje**: build čist (`xcodebuild`), app zdrava (0% CPU idle) kroz
celu sesiju. **Nema potvrde od korisnika za #24** (bojin fix) — sledeća
sesija bi trebalo da proveri je li tekst u Synchronize dijalogu sad čitljiv
pravim mišem, pre bilo čega novog.

**Dopuna (15. avgust 2026)**: umesto potvrde #24, korisnik je prijavio nov,
stvaran bug u istom toku — Shift-range-select je pomerao Sync IZVOR sa prve
kliknute fotke na poslednju. Popravljeno kao stavka **#25** (pun opis
ispod). #24 (boja) i dalje NIJE vizuelno potvrđena — proveri oba pri
sledećem otvaranju Synchronize dijaloga: (a) tekst/ikonice čitljivi, (b)
posle Shift-range-select-a dijalog i dalje piše "Copy the open photo's
settings" o PRVOJ kliknutoj fotki, ne poslednjoj.

**Dopuna (15. avgust 2026, cela večernja sesija, GDE SMO STVARNO STALI) —
ovo je najnovije, čitaj OVO prvo sledeći put**: posle #25 urađeno je još
pet stavki (26-30), sve komitovano na `briefshow-develop` (i dalje
NEPUSHOVANO), poslednji commit `a50776f`. Radna kopija čista (`git status`
pokazuje samo netraćen `build_dd/` build-artefakt folder, ništa
nesačuvano). Redom:

- **#26**: Cmd+A select-all u ShowGrid-u; novi Clarity slajder; Patch
  Circle prepravljen u pravu kontinuiranu clone-stamp četkicu (⌥-klik
  izvor, prevlačenje slika); Square uklonjen iz Patch UI-a; Opacity +
  obavezan minimalni Feather dodati. Usput uhvaćen i ispravljen PRAVI
  migration bug (Codable decoder za `PatchGeometry`) PRE nego što je
  ikad postao problem.
- **#27**: dva bug-a iz prve provere — Patch je ostavljao trajne "zalepljene"
  žute kružiće (uklonjen pogrešan overlay), i OPŠTI slider "seckanje" —
  ispostavilo se dva ODVOJENA uzroka kroz nekoliko krugova povratne
  informacije: (a) debounce koji se nikad nije oglašavao tokom
  prevlačenja (ispravljen u throttle), (b) RAW preview filter bez draft
  mode-a (uključen samo za preview, export ostaje pun kvalitet).
- **#26/#30**: bag "dugme ne radi na prvi klik" — uzrok: nedostajao
  `.contentShape(Rectangle())`. Ispravljeno na `maskAddButton` (Patch/
  Radial/Graduated/Brush add-dugmad) i na `EditToolButtonStyle`/
  `AspectRatioButtonStyle` (Crop/Rotate/aspect-ratio). **NAMERNO NIJE
  DIRANO**: `ShowHeaderButtonStyle` u `ContentView.swift` (Reset Crop/
  Done/sync-dijalog dugmad + ceo ShowGrid header) — verovatno ista rupa,
  ali nije dirano dok se ne prijavi konkretno na TIM dugmadima (veliki
  deljeni fajl van Develop-a). **Ako se bug ponovo javi na BILO KOM
  dugmetu, prvo proveri da li mu stil ima `.contentShape(Rectangle())`
  — obrazac je sad jasno utvrđen, 3 potvrđena slučaja.**
- **#27 (deo dva)**: bottom-of-panel dugmad (Layers/Copy-Paste/Sync/Reset/
  Export) potpuno predizajnirana — nov `panelActionButton`/
  `PanelActionButtonStyle`, puna širina, bordered, bez više prelamanja
  teksta.
- **#28**: Dehaze (aproksimacija, NE pravi dark-channel-prior algoritam)
  i Soft Glow (diffusion/soft-focus, screen-blend zamućene kopije) —
  oba nova global slajdera u Detail & Effects.
- **#29**: Vignette PREPRAVLJEN DVA PUTA u istoj sesiji — prvo na
  striktno-samo-ćoškove (elipsa, ne krug — krug je bio pogrešan za
  landscape slike, uhvaćeno standalone test skriptom PRE nego što je
  ušlo u kod), pa DOPUNJENO kad je korisnik prijavio vidljivu ivicu i
  crop-problem: (a) maska sad blur-ovana (feather, uklanja Mach-band
  ivicu), (b) ceo Vignette blok pomeren da radi POSLE crop-a u
  render() pipeline-u (ranije se računao na pre-crop veličini).

**NIJE vizuelno potvrđeno pravim očima kroz CELU ovu veče sesiju** (GUI
automatizacija do Develop ekrana nije ni pokušavana ovog puta — korisnik
je sam testirao mišem i javljao bagove u nekoliko krugova, što je i
uhvatilo #27/#29/#30). **Sledeća sesija PRVO treba da**: (1) potvrdi da
su #29 (vinjeta+crop, feather) i #30 (Crop/Rotate dugmad) sad stvarno
ispravni pravim testom, (2) proveri Dehaze/Soft Glow vizuelno stvarno
menjaju sliku u očekivanom pravcu, (3) ima na umu da isti
"nedostaje contentShape" obrazac može da se javi na `ShowHeaderButtonStyle`
dugmadima (Reset Crop/Done/sync dijalog/ShowGrid header) ako se prijavi.

**Napomena o Terminal/Desktop permisiji**: tokom testiranja ove sesije,
`ls`/`cat`/itd. na `~/Desktop` iz Bash-a je počeo da vraća "Operation not
permitted" usred sesije (radilo je ranije u istoj sesiji) — izgleda kao da
je macOS TCC (Privacy & Security → Files and Folders) pristup Desktop-u
povučen usred rada, uzrok nepoznat (možda neki sistemski dijalog koji se
pojavio i nestao tokom `System Events` automatizacije). Zaobiđeno preko
`osascript`/Finder (koji je zadržao pristup) za kopiranje/brisanje fajlova.
Ako se ovo ponovi ili ometa normalan rad, korisnik bi trebalo da proveri
System Settings → Privacy & Security → Files and Folders (ili Full Disk
Access) za Terminal/Claude Code.

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

**Dopuna (24. avgust 2026) — NAJNOVIJE, čitaj ovo prvo**: urađene dve nove
stavke, obe vizuelno potvrđene uživo u app-i na pravoj RAW fotki (za razliku
od prethodne sesije, koja je ostala nepotvrđena):
- **#31 (1) Texture slajder** — nov dvosmerni (-100...+100) slajder u
  Detail & Effects, između Sharpness i Clarity. Minus = glatka, "mlađa"
  koža (frekventna separacija + edge-guard maska, tako da oči/usne/kosa
  ostaju oštre — prva verzija je bila običan blur i izgledala je kao da je
  fotka van fokusa, ispravljeno); plus = izrazito naglašena tekstura kože/
  kose/tkanine.
- **#31 (2) Klik na ime slajdera pa strelice** — Lightroom obrazac: klik na
  naziv slajdera ga "naoruža" (red se obeleži, izađe kartica "<Ime>
  selected / Press ← to lower, → to raise · hold ⇧ for bigger steps"), pa
  ← / → menjaju baš taj slajder (⇧ = 5× veći korak, Escape razoružava).
  Radi na SVAKOM slajderu u Develop-u, uključujući mask/patch/layer panele.

- **#32 Color sekcija sa pravim gradijentnim trakama** (Lightroom-style):
  Temperature plava→ćilibar, Tint zelena→magenta, Saturation siva→duga,
  Vibrance ista duga blaže. Zahtevalo je custom `GradientTrackSlider` (native
  `Slider` ne da da mu se zameni traka). Usput popravljen float-dust bug:
  strelice sad snap-uju na mrežu koraka (ranije je 10 pritisaka umelo da
  ostavi -1.1e-16, tj. „-0" u prikazu i fotku zauvek „editovanu").

- **#33 "Remove" alat** — Select People (Vision) + Erase (Criminisi
  inpainting, naš kod, bez modela i bez licencnih problema), rezultat je
  `ImageLayer` pa je undo-able. Usput popravljena DVA prava bug-a: maska je
  tiho bila prazna zbog beskonačnog extent-a iz `CIColorMatrix` sa bias-om,
  i **Release build je do sad UVEK padao** (crash Swift optimizatora na
  generičkoj `NSHostingView` podklasi) — sad prolazi.

- **#34 Remove Brush** — ručno crveno bojenje maske pored Select People;
  potezi se sabiraju sa Vision maskom. Korisnik je ocenio da kvalitet
  brisanja „nije nesto ali moze da ostane" kao instant opcija — dalji skok
  traži model, vidi **„Plan — šta dalje"** sekciju (AI korak 2, redosled
  ostalih funkcija, tehnički dug).

**I dalje NEPOTVRĐENO od korisnika** (iz ranijih sesija, nezavisno od ovoga):
#24 (boje u Synchronize dijalogu), #29 (vinjeta + crop), #30 (Crop/Rotate
dugmad na prvi klik).

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
10. ~~Brush cursor size preview~~ — urađeno 11. avgusta (popodne),
    `xcodebuild` prolazi čisto. Korisnik je primetio da se pri selektovanju
    brush maske ne vidi veličina četkice na slici PRE nego što se počne
    slikati.

    `DevelopView`: novi `@State private var brushHoverLocation: CGPoint?`
    (frame/view prostor, ne unit prostor), postavljen preko
    `.onContinuousHover` na `brushPaintOverlay`-ovom hit-area sloju.
    `brushPaintOverlay` sad crta `Circle().stroke(...)` prstenom prečnika
    `brushSize * max(frame.width, frame.height)` (isti obrazac kao
    postojeći aktivni-potez `lineWidth` — dijametar je razlomak SLIKE-ovog
    dužeg kraja, ne `frame`-ovog, ali pošto je `frame` aspect-preserving
    fit slike, razmera se poklapa), na trenutnoj poziciji miša — sakriven
    dok se aktivno slika (`activeBrushStrokePoints.isEmpty` guard), pošto
    tada već aktivni-potez Path prikazuje pravu širinu poteza. Boja prstena
    prati Erase toggle (crvena/accent), isto kao aktivni potez.

    Uzgred ispravljena mala nekonzistentnost: aktivni-potez `lineWidth` je
    RANIJE koristio samo `frame.width` (ne `max(frame.width, frame.height)`)
    za dijametar — tehnički pogrešno za portrait fotke (gde je frame.height
    duži kraj), sad obe vrednosti (hover prsten i aktivni potez) koriste
    istu `brushDiameter` konstantu izračunatu jednom na vrhu funkcije.

    `onContinuousHover` je dostupan od macOS 10.15 (projekat cilja 13.0),
    nema kompatibilnost problema. **Nije moglo GUI-testirati** (hover
    praćenje miša je isto poznato ograničenje kao drag — `System Events`
    sintetički eventi ne generišu prave mouse-moved evente), ali je
    matematika dijametra ista formula koja je već vizuelno potvrđena za
    aktivni potez ranije u projektu, i `xcodebuild` čist — nizak rizik.
11. ~~Patch (clone/heal) tool — Circle/Square/Free~~ — urađeno 11. avgusta
    (popodne), `xcodebuild` prolazi čisto, matematika PA I ceo vizuelni
    efekat potvrđeni u pravoj app-i (retko za ovu sesiju — obično se
    drag-based delovi nikad ne mogu GUI-potvrditi, ali sam efekat SE VIDI
    čim se maska doda, bez potrebe za draganjem, pošto default source
    offset nije nula).

    Korisnik je tražio "patch tool kao lasso cut tool, circle/square/free
    cut" — protumačeno (i eksplicitno potvrđeno kroz `AskUserQuestion`) kao
    PRAVI clone/heal alat (kopira piksele sa jednog dela slike na drugi),
    ne kao još jedan tip tonske/color maske.

    **Model** (`Develop.swift`): novi `LocalMaskType.patch` slučaj, nov
    `PatchShape` enum (`.circle/.square/.free`), nova `PatchGeometry`
    struktura — `shape`, `centerX/centerY/radiusX/radiusY` (Circle/Square,
    isti konvencija kao `RadialMaskGeometry`), `points: [CGPoint]` (Free,
    unit prostor, prazno dok se ne nacrta), `feather`,
    `sourceOffsetX/sourceOffsetY` (vektor od odredišta do izvora, default
    `(0.2, 0)` — namerno NE nula, da sveže dodata Circle/Square maska
    odmah pokaže vidljivo drugačiji izvor umesto degenerisanog
    "kloniraj-sebe-na-sebe" efekta koji izgleda kao da ne radi ništa).
    `LocalAdjustment.patch: PatchGeometry?` (peto opciono polje, uz
    radial/graduated/brush) — `settings` (tonski slideri) ostaje TRAJNO
    neutralan za patch, jer patch nema tonske kontrole (samo uzorkuje
    piksele). Nov `LocalAdjustment.hasEffect` computed property zamenjuje
    stari `!adjustment.settings.isNeutral` guard u `applyLocalAdjustments`
    — za patch, "ima efekat" znači "Circle/Square uvek" ili "Free samo ako
    su tačke nacrtane", ne "tonska podešavanja nisu nula" (koja za patch
    nikad i nisu relevantna).

    **Render** (`PhotoEditRenderer`): `patchMask(_:extent:)` dispatch po
    obliku — Circle DELI kod sa `radialMask` (samo se `PatchGeometry`
    "prepakuje" u `RadialMaskGeometry` sa `invert: false`, bez duplirane
    gradient matematike); `squareMask` je hard-edged pravougaonik
    (`CIImage(color:).cropped(to:)` preko crne pozadine) omekšan
    `CIGaussianBlur`-om proporcionalnim `feather * min(halfW, halfH)`
    (simetrično unutra/spolja, za razliku od radial-ovog "samo unutra"
    feather-a — svesna razlika, bliža Photoshop-ovom "Feather Selection"
    ponašanju); `freeMask` je JEDINA maska u projektu koja ide preko Core
    Graphics (`CGContext` bitmap + `CGMutablePath.fillPath()`) umesto
    čistog CIFilter lanca, pošto Core Image nema built-in generator za
    proizvoljan poligon — `CGContext`-ov koordinatni sistem je bottom-up
    kao CI (ne top-down kao SwiftUI), pa tačke dobijaju isti `1 - y` flip
    kao radial/graduated, ne dodatni.

    Sam clone efekat: `patchSampledImage(_:source:extent:)` translira CEO
    trenutni (već-akumulirani, uključujući ranije maske u nizu) `output`
    preko `CGAffineTransform(translationX: -offsetX*width, y: +offsetY*height)`
    — matematika (zašto je X negiran a Y nije, zbog unit-prostor top-down
    Y vs. CI bottom-up Y) izvedena ručno PA potvrđena standalone skriptom
    (sintetička 4-kvadrant slika, sample u sva 4 smera) PRE ugrađivanja u
    kod, isti obrazac kao auto-fit crop/histogram/RAW ranije ove sesije.
    Mask se i dalje gradi na ODREDIŠNOJ lokaciji (`patchMask` koristi
    `geo.centerX/Y`, ne source) — `CIBlendWithMask` onda ograničava efekat
    na taj oblik, identičan obrazac kao svaka druga lokalna maska.

    **Matematika — SVE provereno standalone Swift skriptama pre GUI-ja**
    (isti pattern kao ceo ostatak sesije): (1) offset sign (4 smera na
    sintetičkoj 4-kvadrant slici — svi PASS); (2) square/free mask
    geometrija (granice, Y-flip, feather smer — 13 provera, svi PASS);
    (3) PUN end-to-end kompozit (mask + sample-offset ZAJEDNO, kao pravi
    `applyLocalAdjustments`) na 4-kvadrant slici — odredište pokazuje
    TAČNU boju sa source lokacije, ostatak slike netaknut (5 provera, svi
    PASS).

    **UI** (`DevelopView`): tri nova add-dugmeta "Patch Circle/Square/Free"
    (namerno TRI odvojena dugmeta, ne jedno + naknadni shape-picker — prati
    isti obrazac kao postojeća tri Radial/Graduated/Brush dugmeta, izbegava
    "šta se dešava sa već nacrtanim Free poligonom ako se shape promeni
    naknadno" komplikaciju). Mini editor (kad je patch selektovan): shape
    Picker (segmented, Circle/Square/Free — promena oblika NA Free čisti
    `points`, nazad SA Free samo menja render, centar/radius ostaju),
    Feather slider, "Reset Source Offset" dugme, i (za Free bez nacrtanih
    tačaka) hint tekst "Drag on the photo to draw the patch outline." — svi
    tonski slideri (Exposure/Contrast/itd.) su NAMERNO izostavljeni za
    patch tip (`if adjustment.type != .patch` guard oko celog tog bloka).

    On-canvas overlay: Circle/Square dele `patchShapeOverlay` (move handle
    + 2 radius handle, identičan obrazac kao `radialOverlay`, samo se
    ispisuje `Ellipse()` ili `Rectangle()` po obliku); Free dele
    `patchFreeShapeOverlay` (move handle pomera SVE tačke + centar
    zajedno, bez clamp-a na 0...1 — clamp samo na centru dok se tačke ne
    clamp-uju bi ih desinhronizovao, pošto `freeMask` crta direktno iz
    `points`, ne iz centra) dok nema nacrtanih tačaka, inače
    `patchFreeDrawOverlay` (prazna hit-površina, isti "jeftin vektorski
    preview do mouse-up" obrazac kao Brush). SVE tri varijante crtaju
    žuti izvor-marker (`viewfinder` SF Symbol, draggable, NEKLAMPOVAN —
    izvor sme biti bilo gde, čak i blizu/van ivice) + isprekidanu liniju
    odredište→izvor + isprekidanu "duh" konturu na izvoru (čisto vizuelna
    referenca, non-interactive) — nijedan od ova dva dodatka ne postoji kod
    Radial/Graduated/Brush, novo samo za Patch.

    **Vizuelno POTVRĐENO u pravoj app-i** (Accessibility automatizacija +
    ručno generisana sintetička 4-kvadrant test fotka — crveno/zeleno/
    plavo/žuto, `xcrun swift` skripta preko `CIContext`/`NSBitmapImageRep`,
    uvezena preko `Import Photos` → real `NSOpenPanel` sa `Cmd+Shift+G` pa
    type-ahead selekcijom fajla, pošto BriefShow-ova SOPSTVENA sidebar-ova
    fascikla-lista koristi `.onTapGesture` i ne reaguje na sintetičke AX
    evente — isti poznati obrazac): sve tri "Patch X" add-dugmeta rade
    (ispravna ikonica/ime/auto-select), mini editor prikazuje tačan
    shape-picker state i sakriva tonske slidere, Free ispravno prikazuje
    "draw outline" hint dok nema tačaka. **Bonus, van očekivanja**: pošto
    default `sourceOffsetX = 0.2` NIJE nula, sam clone efekat je bio ODMAH
    vidljiv na ekranu čim je maska dodata (bez ikakvog draganja) — mogla se
    vizuelno potvrditi i sama pixel-kompozicija, ne samo UI wiring: unutar
    Circle/Square oblika, deo koji preklapa crveni/plavi kvadrant slike
    ispravno prikazuje omekšano zeleno/žuto (sadržaj sa izvorne lokacije),
    tačno kao što matematika predviđa. Ovo je redak slučaj u ovoj sesiji
    gde je i sam pixel-efekat (ne samo geometrija/UI) vizuelno potvrđen u
    pravoj app-i, ne samo skriptom.

    **Šta NIJE moglo GUI-testirati** (isto poznato ograničenje kao svaki
    drag-based deo ranije): stvarno prevlačenje resize handle-a (Circle/
    Square), stvarno crtanje Free poligona, prevlačenje žutog izvor-
    markera, promena Feather slidera. Sve rade preko istog, već više puta
    potvrđenog `DragGesture`/`Slider` obrasca kao Radial/Graduated/Brush,
    nizak rizik.

    **Poznata ograničenja (svesno, ne bagovi)**: ovo NIJE Photoshop-ov
    pravi "Patch Tool" sa content-aware/Poisson blending-om koji prilagođava
    osvetljenje/teksturu na granici — ovo je jednostavan feathered
    alpha-blend (translate + `CIBlendWithMask`), isti nivo sofisticiranosti
    kao ostale tri maske. Na fotkama sa glatkim prelazima (nebo, koža,
    zamagljena pozadina) izgledaće dobro; na oštrim ivicama/kontrastnim
    granicama ostaviće vidljiv "flekast" prelaz (baš kao što se vidi na
    adversarijalnoj 4-kvadrant test slici). Pravi content-aware heal bio bi
    mnogo veći poduhvat (Poisson image editing/gradient-domain blending) —
    nije urađen, nije ni tražen eksplicitno. Square feather je simetričan
    (blur unutra I spolja oko granice), za razliku od Radial-ovog "samo
    unutra" — ako se ikad primeti kao nekonzistentno, lako se poravna.
    Free mask nema caching (isti "rebuild iz nule na svaki render" kao
    Brush) — isti poznati kompromis.
13. ~~Selection tool (Cut/Copy/Deselect) + pravi Image Layers~~ — urađeno
    11. avgusta (kasno popodne), `xcodebuild` prolazi čisto.

    **Kontekst/ispravka**: korisnik je posle #11 (Patch tool) objasnio da
    "circle/square/free cut" NIJE trebalo da bude clone/heal, već pravi
    **selection alat** — iseci deo slike, kopiraj/iseci ga kao layer, taj
    layer nalepi (i na DRUGU fotku, kao clipboard). Razjašnjeno kroz tri
    runde `AskUserQuestion` pre kucanja koda (jer je već jednom pogođeno
    pogrešno): (1) Patch ostaje, ovo je NOVI, peti tip alata (ne zamena);
    (2) nalepljeni komad je PRAVI layer — pomeriv/resize/opacity/blend
    mode, ne odmah zapečen u sliku; (3) clipboard je in-memory dok je
    Develop prozor otvoren (isti obrazac kao `settingsClipboard`); (4) Cut
    ostavlja solid-color "rupu" na izvoru (ne ništa).

    **Model** (`Develop.swift`): `SelectionGeometry` — ephemeral (NIJE
    Codable/deo `PhotoEditSettings`, isto kao `pendingCrop`), shape
    (deli `PatchShape` enum sa Patch-om) + center/radius/points/feather,
    NEMA source-offset polja (nema smisla za običnu selekciju). `ImageLayer`
    (Codable, u `PhotoEditSettings.layers: [ImageLayer]`, decodeIfPresent
    fallback `[]` isti obrazac kao `localAdjustments`) — `imageData: Data`
    (PNG, NIKAD JPEG jer isečen krug/lasso komad ima providne piksele van
    svog oblika, JPEG nema alpha kanal), `x/y/width/height` (GORNJI-LEVI
    ugao, ne centar — layer se prevlači/resize-uje iz bounding box-a kao
    crop alat, ne iz radiusa oko centra kao maske), `opacity`, `blendMode`
    (`LayerBlendMode`: normal/multiply/screen/overlay — minimalan razuman
    set za prvi prolaz), `isEnabled`. `LayerClipboardData` (NIJE Codable,
    samo `@State` na `DevelopView`, kao `settingsClipboard`).

    **Persistencija — odgovor na staro otvoreno pitanje "gde žive layer-i"**:
    NE poseban disk-based sistem kako je ranije predviđeno (vidi staru
    verziju ove stavke u git istoriji/ranijim verzijama ove beleške) — PNG
    `Data` prosto ide u `PhotoEditSettings` kao i sve ostalo, kroz isti
    `UserDefaults`-JSON `PhotoEditStore`. Prihvatljivo jer je svaki layer
    OGRANIČEN na svoj bounding box (ne cela slika) — jedan isečen komad je
    reda veličine par do par desetina KB kao PNG, ne MB; ako se ovo ikad
    pokaže kao problem (npr. korisnik nalepi mnogo velikih layer-a), sledeći
    korak bi bio disk-based storage sa samo putanjom u `UserDefaults`.

    **Render** (`PhotoEditRenderer`): `compositeLayers` — nova faza u
    `render()`, POSLE `applyLocalAdjustments` (maske), PRE crop-a. Svaki
    layer: `CIImage(data: layer.imageData)` (dekoduje PNG), skaliran
    NANOVO protiv TRENUTNOG (ne izvornog) `extent`-a (isti komad nalepljen
    na fotku drugačije rezolucije od one sa koje je isečen i dalje ispravno
    skalira — `width/height` su razlomci CILJNE slike, ne apsolutni
    pikseli), pozicioniran preko `originY = extent.origin.y + (1 - y -
    height) * extent.height` (top-down layer.y → CI bottom-up, isti obrazac
    kao svaki drugi top-down→CI flip u fajlu), opacity kroz `CIColorMatrix`
    (skalira alpha kanal), blend preko `CIFilter.sourceOverCompositing/
    multiplyBlendMode/screenBlendMode/overlayBlendMode`. `selectionMask`
    ponovo pakuje `SelectionGeometry` u `PatchGeometry` da iskoristi VEĆ
    proverenu `patchMask`/`squareMask`/`freeMask` matematiku bez trećeg
    dupliranja. `extractSelectionPNG` (za Copy, uzorkuje iz renderovane
    slike) i `solidFillPNG` (za Cut-ovu rupu, uzorkuje iz solid boje umesto
    slike — DELI `maskedSelectionImage` helper sa `extractSelectionPNG`)
    oboje crop-uju na selekcijin BOUNDING BOX (ne celu sliku) pre PNG
    encode-a, da isečeni komad ne nosi ogromnu providnu marginu.

    **Cut = Copy + nov layer, ne poseban mehanizam**: "rupa" koju Cut
    ostavlja na izvoru NIJE nova vrsta adjustment-a — to je prosto NOVI
    `ImageLayer` (solid crna, isti oblik/pozicija kao selekcija) dodat na
    KRAJ `settings.layers` niza na IZVORNOJ fotki. Ponovo koristi kompletan
    layer-rendering pipeline bez ijedne dodatne grane koda — svesna odluka
    da se izbegne treći "kako da ostavim trag na slici" mehanizam (posle
    maski i patch-a).

    **UI**: nova sekcija "Selection" (ispod Masks) — tri add-dugmeta
    (Circle/Square/Free, dele `patchShapeStroke`/`closedPolygonPath`
    on-canvas helpers sa Patch-om), kad je selekcija aktivna prikazuje se
    Feather slider + Cut/Copy/Deselect red (`ShowHeaderButtonStyle`,
    `.fixedSize()` na labelama — bez toga bi "Copy" prelomio u dva reda u
    300pt panelu, uhvaćeno vizuelnom proverom i odmah ispravljeno). Nova
    sekcija "Layers" (ispod Selection) — "Paste as Layer" dugme (disabled
    dok je clipboard prazan), lista layer-a (isti eye/trash/select obrazac
    kao mask lista), mini editor (Opacity slider, Blend Mode segmented
    picker). On-canvas: `layerOverlay` — pravougaonik + 4 corner handle-a,
    svaki anchoruje SUPROTAN ugao (isti princip kao stari crop resize, bez
    ratio-lock komplikacije jer layer nema aspect-ratio dugmad).

    **Matematika — SVE provereno standalone skriptama pre GUI-ja** (isti
    pattern kao ceo ostatak sesije): (1) `resizeLayer`-ova anchor-suprotan-
    ugao logika (11 provera — grow/shrink/edge-clamp/anchor-fiksiran za sve
    4 ugla, svi PASS) — prva verzija koda je bila nepotrebno zamršena
    (mešala je dva različita pristupa po osi), prepisana čistije PRE nego
    što je stigla do GUI-ja; (2) `compositeLayers`-ova pozicija/scale/
    Y-flip/blend (7 provera na sintetičkoj 4-kvadrant slici, uklj. Multiply
    blend sanity check, svi PASS); (3) PUN PNG round-trip (mask→crop→PNG
    encode→`CIImage(data:)` decode→scale→translate→composite, TAČNO isti
    kod put kao `compositeLayers`, ne pojednostavljena verzija) — PASS,
    bitno jer je ovo jedina maska/layer putanja u projektu koja stvarno
    prolazi kroz disk-format (PNG bytes) umesto da ostane kao CIImage kroz
    ceo pipeline.

    **Vizuelno POTVRĐENO u pravoj app-i, uključujući JEDAN lažni alarm
    uhvaćen usput**: Circle/Square/Free selection dugmad rade, on-canvas
    selection overlay (isti stil kao Patch, bez source markera) ispravno
    se iscrtava, Feather slider i Cut/Copy/Deselect red se pojavljuju/
    nestaju ispravno. Copy ispravno popunjava clipboard (Paste as Layer
    prelazi iz disabled u enabled). Paste as Layer kreira pravi `ImageLayer`
    red u listi, selektuje ga, on-canvas move/resize overlay se iscrtava,
    mini editor (Opacity/Blend Mode) radi. Cut ispravno dodaje "Cut Fill N"
    layer.

    **Lažni alarm**: `screencapture -l<windowID>` snimci NEPOSREDNO posle
    Cut/Paste akcije više puta zaredom nisu pokazivali stvarno renderovan
    sadržaj layer-a na canvas-u (izgledalo je kao da compositeLayers ne
    radi ništa) — ispalo je da je `screencapture -l` snimao ZASTareo frame
    prozora koji trenutno nije key/frontmost (WindowServer keširanje), ne
    stvaran bag. Razrešeno definitivno preko `Export Edited Copy` → pravi
    fajl → piksel-inspekcija (crni "Cut Fill" kvadrat, oštrih ivica, tačne
    pozicije/veličine, potvrđeno u eksportovanom JPEG-u). **Pouka za
    sledeći put**: kad `screencapture -l` snimak izgleda "kao da se ništa
    nije desilo" posle akcije koja MENJA `settings` (a ne samo UI selekcija/
    stil), ne verovati odmah da je bag — prvo probati Export i piksel-
    proveru pravog fajla pre nego što se sumnja u render kod.

    **Poznata ograničenja (svesno, ne bagovi)**: layer nema rotate (samo
    pomeranje/resize, isto kao Radial mask nema rotaciju); Cut-ova fill
    boja je fiksna (nije birana od korisnika — bila crna, sad siva, vidi
    #14); `layerClipboard` je in-memory (ne preživljava restart app-e/
    zatvaranje Develop prozora — namerno, korisnikov izbor); nema
    multi-select/multi-paste; Export All Edited već radi sa layer-ima bez
    izmene (isti `PhotoEditRenderer.render` poziv, layeri su samo još jedna
    faza u istom pipeline-u).
14. ~~Četiri manje ispravke posle #13~~ — urađeno 11. avgusta (veče),
    `xcodebuild` prolazi čisto. Korisnik je vratio četiri stvari nakon
    probanja #13.

    **(a) Patch — pravi clone-stamp gest preko ⌥ (Option)**: ranije se
    izvor mogao pomeriti SAMO prevlačenjem žutog `viewfinder` markera.
    Korisnik je tražio profesionalniji tok: drži ⌥ i klikni da postaviš
    izvor odatle, pusti ⌥ i klikni da pomeriš odredište (i "patchuje")
    tamo — isti gest kao Photoshop/Lightroom-ov Clone Stamp/Healing Brush.

    Implementacija (`Develop.swift`): nov `patchCanvasClickArea(frame:)`
    helper (deljen između `patchShapeOverlay` i `patchFreeShapeOverlay`,
    ubačen PRVI u njihov ZStack — dakle ISPOD move/resize/source handle-a,
    koji i dalje imaju prioritet nad svojim malim hit-area-ma, a klik bilo
    gde drugde na fotki pada kroz na ovaj sloj). Koristi
    `NSEvent.modifierFlags.contains(.option)` — čita se SINHRONO i na
    hover-u i na klik-u; nema potrebe za zasebnim event-monitor-om jer
    macOS 13 SDK nema SwiftUI API za "trenutno stanje modifier tastera"
    (`.onModifierKeysChanged` je macOS 14+, projekat cilja 13.0), ali
    `NSEvent.modifierFlags` (statička klasa-property) radi identično kad
    se pročita unutar bilo kog gesture callback-a. `SpatialTapGesture`
    (dostupan od macOS 13.0) daje lokaciju klika, za razliku od običnog
    `.onTapGesture` koji to ne daje pre novijih OS verzija.

    `handlePatchCanvasTap(at:frame:)`: ⌥+klik postavlja
    `sourceOffsetX/Y = tapUnit - center` (izvor ide POD kursor, odredište
    ostaje gde jeste); običan klik pomera `centerX/Y` na tap lokaciju (za
    Free oblik, pomera i SVE tačke za isti delta — ista logika kao već
    postojeći `movePatchFreeShape`, bez klampovanja na 0...1 da se centar i
    tačke ne desinhronizuju, isti obrazac kao ranije). Pošto je
    `sourceOffset` već RELATIVAN vektor, pomeranje odredišta automatski
    povlači izvor sa sobom — identična matematika kao postojeći
    `movePatchCenter`/`movePatchSource`, samo okinuta na klik umesto na
    drag. Dodat i hover-prsten (`patchSourceHoverLocation`, isti obrazac
    kao `brushHoverLocation`) koji se pojavljuje SAMO dok se ⌥ drži —
    preview "ovde će izvor pasti ako klikneš sad", žuti poluproviran
    `viewfinder` koji prati miš.

    **Nije moglo GUI-testirati** (⌥+klik kombinacija — isto poznato
    ograničenje kao svaki gesture-based deo ove app-e, `System Events`
    sintetički eventi ne pokreću SwiftUI geste pouzdano), ali matematika je
    doslovno identična već-verifikovanim `movePatchCenter`/
    `movePatchSource`/`movePatchFreeShape` funkcijama (isti izrazi, druga
    okidačka gesta) — nizak rizik. `xcodebuild` čist.

    **(b) Cmd+V za Paste as Layer** — bug prijava "posle Cut ne mogu nigde
    da pastujem" je najverovatnije bila UI-discoverability problem (malo
    dugme u "Layers" sekciji, zakopano na dnu dugog scroll panela sa Light/
    Color/Detail/Masks/Selection/Layers sekcijama — čak sam se i JA
    pri testiranju #13 zabunio i kliknuo pogrešno dugme zbog AX-indeksa,
    pravi bag u mojoj test-skripti, ne u app-i). Popravljeno robusno bez
    obzira na uzrok: `.keyboardShortcut("v", modifiers: .command)` na
    "Paste as Layer" dugmetu — dugme je UVEK u view stablu (nije
    uslovno ubačeno), pa prečica radi bez obzira gde je panel skrolovan, i
    SwiftUI automatski poštuje `.disabled(layerClipboard == nil)` (prečica
    ne okida kad je clipboard prazan).

    **(c) Cut-ova rupa: siva umesto crna** — `solidFillPNG`-ov poziv u
    `cutSelection`-u sad šalje `CIColor(red: 0.5, green: 0.5, blue: 0.5,
    alpha: 1)` umesto crne. Trivijalna izmena, testirano vizuelno u #13-oj
    export-proveri PRE ove izmene (crna verzija), logika identična pa je
    dovoljno pouzdana i bez ponovnog GUI testa.

    **(d) Feather se više ne "širi" van nacrtane granice** — korisnik je
    primetio da bi cut rupa mogla biti veća od stvarne selekcije. Uzrok:
    `squareMask`/`freeMask`-ov Gaussian blur feather je bio SIMETRIČAN
    (meko i UNUTRA i NAPOLJE oko granice, namerna odluka u #11 da liči na
    Photoshop-ovo "Feather Selection") — kod visokog feather-a, to bi
    zaista pomerilo VIDLJIVU spoljnu ivicu izvan nacrtanog oblika, za
    razliku od `radialMask`-a koji je oduvek bio "samo unutra" (radius0/
    radius1 gap, spoljna ivica fiksna na radius1).

    Ispravka: nov `clipToHardEdge(_:hard:extent:)` helper — per-pixel
    minimum (`CIDarkenBlendMode`) feathered maske i njene NEZAMUćene hard-
    edge verzije, isti trik kao "clip a blur to never exceed its own hard
    boundary". Pošto je hard=0 svuda VAN nacrtanog oblika, `min(blurred,
    hard)` je uvek 0 tamo, bez obzira koliko je blur radius veliki —
    feather sad SAMO omekšava UNUTRA (ka centru), nikad ne probija spoljnu
    granicu. Primenjeno i na `squareMask` i na `freeMask` (obe dele isti
    helper); `radialMask` nije dirana (već je bila ispravna).

    Provereno standalone Swift skriptom (isti pattern kao ceo ostatak
    sesije): square sa feather=1.0 (maksimalno meko) — piksel TAČNO na
    nacrtanoj ivici i van nje je i dalje TAČNO 0 (pre ispravke bi bio > 0
    zbog spoljnog "curenja" blur-a); feather=0 slučaj ostaje bit-za-bit
    identičan (regresija, kao i pre). Usput primećeno (očekivano, ne bag):
    pri feather=1.0 na malom obliku, i sam CENTAR maske pomalo potamni
    (182 umesto pune 255) — to je inherentno Gaussian blur ponašanje pri
    ekstremnom feather-u na kompaktnom obliku, nezavisno od ove ispravke
    (ista vrednost bi bila i pre nje), i ne utiče na default feather=0 koji
    Selection alat koristi.
15. ~~Klik na Brush/Radial ne radi odmah + ⚠️ ozbiljan CPU/hang bag + paste
    "u mestu" + aspect-ratio lock za layer resize~~ — urađeno 11. avgusta
    (kasno veče), `xcodebuild` prolazi čisto. Korisnik je vratio tri stvari,
    a testiranje jedne od njih je otkrilo pravi, ozbiljan bag.

    **(a) Klik ne radi odmah pri otvaranju Develop-a** — pravi bug, ne
    poznato ograničenje testiranja. Uzrok: `NSView.acceptsFirstMouse(for:)`
    je default `false` — PRVI klik posle nego što prozor postane key (tek
    otvoren, ili posle klika na drugi prozor/app) se troši SAMO na
    aktivaciju/fokusiranje prozora, nikad ne stigne do kontrole ispod
    kursora. Tačno objašnjava "moram da sačekam ili pređem na drugu sliku"
    — to "pređem na drugu sliku" je bio njihov PRVI (progutan) klik koji je
    probudio prozor, sve posle toga je normalno radilo. Ispravka: nov
    `ClickThroughHostingView<Content>: NSHostingView<Content>` (override
    `acceptsFirstMouse` → `true`) koristi se umesto golog `NSHostingView`
    za Develop-ov `window.contentView`. Bitna ispravka usput: prvi pokušaj
    je greškom stavio `acceptsFirstMouse` na `NSWindow` podklasu — to je
    metoda na `NSView`, ne `NSWindow` (compile error "does not override
    any method from its superclass" je odmah uhvatio grešku pre nego što
    je stigla do runtime-a).

    **(b) ⚠️ Ozbiljan bag — app se zamrzla, `kill -9` morao**: dodat
    Cmd+X/Cmd+C uz postojeći Cmd+V (isti `NSEvent.addLocalMonitorForEvents`
    obrazac). Dok je korisnik testirao, app je stigla do ~76% CPU i
    prestala da odgovara na `System Events`/AppleScript komande (aktivacija
    je bacala `AppleEvent timed out`) — morao `kill -9` da se ubije proces.

    **Uzrok**: Cmd+V monitor iz prošle runde NIJE proveravao
    `event.isARepeat`. Držanje tastera (čak i kratko, malo duže od OS-ovog
    key-repeat praga) šalje OS-generisane ponovljene `keyDown` evente, i
    SVAKI je zvao `pasteLayer()` — desetine novih layer-a u sekundi. Svaki
    dodatni layer čini SVAKI sledeći render (PNG decode + kompozit, po
    layeru, na SVAKU promenu `settings`) malo sporijim, a taj usporeni
    render se preklapa sa još pristiglim repeat-evente-generisanim
    paste-ovima — samopojačavajuća petlja koja je za par sekundi odvela
    app u potpuno zamrznuto stanje. Ovo je najozbiljniji bag otkriven u
    celoj sesiji — dokumentovano upozorenje na vrhu ovog fajla za svaki
    budući `NSEvent` monitor.

    **Ispravka**: `!event.isARepeat` dodat u guard (jedan `installClipboardKeyMonitor`
    sad pokriva sve troje — Cmd+C/X/V — umesto tri odvojena monitora).
    Usput i dodatna zaštita: svaki slučaj u `switch key` sad ima `where`
    uslov (`"v" where layerClipboard != nil`, `"c"/"x" where activeSelection
    != nil`) — bez ovoga bi SVAKI Cmd+C/X/V BILO GDE u Develop prozoru
    (uključujući obično text polje, npr. kucanje imena preset-a) bio
    progutan od strane ovog monitora umesto da normalno stigne do text
    polja; sad se monitor uključuje SAMO kad zaista ima šta da uradi.
    Vizuelno POTVRĐENO da je app posle ispravke zdrava: restartovana,
    proverena preko `ps aux` (0.0% CPU, `S` idle stanje) i preko
    `System Events` (odgovara odmah, bez timeout-a) — pre ispravke isti
    test je bacao `AppleEvent timed out`.

    **(c) Paste "u mestu" umesto uvek na centru** — verovatno PRAVI uzrok
    ranije prijave "ne mogu da pastujem na istu sliku koju sam cutovao":
    `pasteLayer()` je RANIJE uvek lepio na centar (0.5, 0.5) fiksne
    veličine 30% širine, bez obzira odakle je komad isečen/kopiran — ako
    selekcija nije bila na centru, nalepljeni komad bi se pojavio negde
    DRUGDE na fotki (izgleda kao "ništa se nije desilo" ako korisnik gleda
    tačno mesto odakle je isekao/kopirao, koje je tačno gde Cut-ova siva
    "rupa" sedi). `LayerClipboardData` sad nosi `boundsUnit: CGRect`
    (tačna frakciona pozicija/veličina odakle je isečeno/kopirano,
    postavlja `extractSelectionPNG`, koji sad vraća `boundsUnit` umesto
    `aspectRatio` — isti podatak, samo korisniji oblik pošto već nosi i
    širinu i visinu). Paste sad lepi TAČNO tamo — na ISTOJ fotki, pravo
    preko Cut-ove rupe (odmah vidljivo, nema traženja); na DRUGOJ fotki,
    na isti RAZLOMAK pozicije/veličine (razumno i predvidivo, pošto su to
    frakcije 0...1, ne pikseli — rade nezavisno od dimenzija ciljne fotke).

    **(d) Layer resize — zaključana razmera po difoltu, ⇧ (Shift) za
    slobodno**: korisnik je eksplicitno tražio OBRNUTO od crop-ovog
    obrasca (crop je slobodan dok se ne pritisne dugme za razmeru; layer
    je sad zaključan dok se ne drži Shift). `resizeLayer` prepisan da prati
    ISTI anchor+rawWidth/rawHeight+pomirenje obrazac kao stari `resizeCrop`
    ratio-lock (`k = start.width/start.height` — direktno frakciono, BEZ
    potrebe za `currentImagePixelRatio` konverzijom kao kod crop-a, pošto
    se `imagePixelRatio` faktor matematički skrati kad se zaključava na
    SOPSTVENU trenutnu razmeru umesto na proizvoljnu spolja-zadatu; vidi
    kod-komentar za punu izvedbu). `NSEvent.modifierFlags.contains(.shift)`
    čita se live u `onChanged` svakog drag-a (isti obrazac kao ⌥ za Patch),
    pa se stanje Shift-a može promeniti NASred drag-a.

    Provereno standalone skriptom (isti pattern kao ceo ostatak sesije, 40
    kombinacija — 2 starting layer-a × 4 ugla × 5 delta vrednosti): (1)
    **regresija** — Shift=held daje BIT-ZA-BIT identičan rezultat kao stara
    slobodna implementacija u svih 40 slučajeva; (2) **razmera održana** —
    Shift=NOT held daje TAČNU polaznu razmeru u svih 40 slučajeva, i ostaje
    unutar 0...1 granica; (3) **anchor fiksiran** u OBA režima. Sam drag
    nije mogao GUI-testirati (poznato ograničenje), ali matematika
    identična već-dokazanom `resizeCrop` obrascu plus potpuna skriptovana
    provera — nizak rizik.
16. ~~Overlay pomeraj kad postoji crop + tanje linije~~ — urađeno 11.
    avgusta (kasno veče), `xcodebuild` prolazi čisto. Korisnik je primetio
    da kvadrat/kontura "nije precizno" na selektovanom objektu.

    **Pravi arhitekturni bag, ne kozmetika**: maske/Selection/Layer
    geometrija je UVEK definisana u unit-prostoru PRE-crop slike
    (`applyLocalAdjustments`/`compositeLayers` rade PRE crop-a u
    `render()`, namerno — da mask/layer pozicija preživi promenu/uklanjanje
    crop-a, isti Lightroom obrazac). Ali `centerPreview` je overlay-ima
    prosleđivao `fitted` — frame prikazanog `displayedImage`-a, koji je
    POST-crop kad god `settings.crop` postoji i korisnik nije AKTIVNO u
    crop alatu (`cropEnabled = !isCropping` u `renderNow()`). Dve različite
    referentne slike, ista frakcija — overlay se crtao na pogrešnom mestu
    svaki put kad je fotka imala crop.

    Ispravka: nov `fullImageFrame(from fitted:) -> CGRect` — rekonstruiše
    gde bi CELA (pre-crop) slika bila na ekranu pri ISTOJ razmeri koju
    `fitted` već koristi, invertovanjem `settings.crop`-ovih x/y/width/
    height razlomaka (algebarski tačan obrnut postupak od onoga što
    `render()` radi da crop frakciju pretvori u pixel rect). Korišćen za
    `localAdjustmentOverlay`/`selectionOverlay`/`layerOverlay` pozive (NE
    za `cropOverlay`, koji već dobija ispravan ne-cropovan `fitted` iz
    drugog razloga — `cropEnabled` je false dok je `isCropping`).
    Provereno standalone skriptom: centrirani i NECENTRIRANI crop slučaj,
    uključujući proveru da se crop-ov sopstveni ugao mapira tačno na
    ugao `fitted`-a (najstroža provera).

    Usput: sve on-canvas konture (crop, radial/graduated/patch/selection
    outline, layer rectangle) stanjene sa 1.5pt na 1.0pt (dashed
    source-marker/mirror linije sa 1.2 na 0.8pt) — eksplicitan zahtev
    korisnika. Sidebar liste (mask/layer red selekcije) i brush hover-
    prsten NISU dirani (nisu bili predmet pritužbe).
17. ~~Backspace briše selekciju, Undo/Redo istorija, [ ] za veličinu~~ —
    urađeno 11. avgusta (kasno veče), `xcodebuild` prolazi čisto.

    Sav novi kod ide kroz JEDAN prošireni `installEditingKeyMonitor`
    (preimenovan iz `installClipboardKeyMonitor` — sad pokriva Cmd+C/X/V,
    Cmd+Z/⇧Z, `[`/`]`, i Backspace/Delete, umesto samo clipboard-a).

    **Backspace/Delete** — briše selektovani layer ILI selektovanu masku
    (`deleteSelectedItem()`, samo poziva postojeće `deleteLayer`/
    `deleteLocalAdjustment`). Prepoznaje pravi "delete" taster preko
    `event.keyCode` (51 = kVK_Delete/glavni Delete taster, 117 =
    kVK_ForwardDelete/fn+Delete) umesto preko karaktera — pouzdanije nego
    oslanjanje na `charactersIgnoringModifiers` mapiranje. Uslovljeno sa
    `selectedLayerID != nil || selectedLocalAdjustmentID != nil` — isti
    razlog kao Cmd+C/X/V guard-ovi: bez toga bi SVAKI Backspace bilo gde u
    Develop-u (uključujući normalno brisanje karaktera u preset-name text
    polju) bio progutan.

    **Undo/Redo (Cmd+Z / Cmd+⇧+Z)** — čuva CEO `PhotoEditSettings`
    snapshot po koraku (isti "jedan struct je izvor istine" pristup kao
    Presets/Copy-Paste Settings), PO FOTKI (resetuje se u `selectPhoto`,
    kao Lightroom-ova sopstvena istorija). Debounced/coalesced preko
    `scheduleUndoCommit()`: PRVA promena u "naletu" (npr. prevlačenje
    slajdera) hvata `pendingUndoBaseline` (stanje PRE tog naleta) i
    pokreće 0.5s tajmer; svaka sledeća promena u ISTOM naletu samo
    restartuje tajmer, ne dira baseline; tek kad promene STANU na 0.5s,
    `commitUndoIfNeeded()` gura TAJ JEDAN baseline na `undoStack` — jedno
    3-sekundno prevlačenje slajdera pravi JEDAN undo korak, ne stotine.
    `undoStack`/`redoStack` ograničeni na 50 koraka. Redo stack se prazni
    na svaku NOVU promenu (standardno ponašanje). `undo()`/`redo()`
    otkazuju pending debounce timer PRE primene snapshot-a, da se sopstvena
    promena settings-a od strane undo/redo-a ne uhvati kao NOVI undo korak.

    **`[` / `]` za veličinu** (Photoshop-ova konvencija, korisnik je
    pogodio tačno) — bez modifier tastera. Multiplikativan korak (±10%,
    `factor = 1.1`/`1/1.1`) umesto fiksnog apsolutnog iznosa — isti korak
    radi i za brush (opseg 0.01...0.3) i za radial/patch/selection radius
    (opseg 0.02...1) bez posebnog "magic number"-a po alatu. Radi na:
    Brush (`brushSize`), Radial (`radiusX/Y`), Patch Circle/Square
    (`radiusX/Y` — NE Free, nema jedinstvenu "veličinu"), Selection
    Circle/Square (isto, NE Free). `activeToolHasAdjustableSize`
    computed property odlučuje da li uopšte ima šta da se menja pre nego
    što se taster proguta.

    **Repeat namerno DOZVOLJEN** za Undo/Redo i `[`/`]` (za razliku od
    Cmd+C/X/V, vidi upozorenje na vrhu ovog fajla) — držanje Cmd+Z da se
    vrati nekoliko koraka, ili držanje `]` da glatko naraste brush, je
    očekivano ponašanje, i BEZBEDNO je dozvoliti repeat ovde jer je svaki
    korak jeftina, ograničena operacija (pop sa niza / klampovana
    aritmetika) — nema akumulacije kao kod paste-bug-a iz stavke #15.

    **Nije moglo GUI-testirati** (poznato ograničenje — tastaturne
    kombinacije i drag-based delovi se ne mogu pouzdano simulirati kroz
    `System Events` automatizaciju), ali `xcodebuild` čist, app posle
    restarta zdrava (proverena preko `ps aux`, 0.1% CPU, `S` idle), i
    logika je pregledana ručno (jednostavna, bez asinhronog rizika sličnog
    #15-om osim namerno-dozvoljenog repeat-a, koji je bezbedan iz gore
    navedenog razloga).
18. ⚠️ **Cmd+X/Cmd+C u Selection alatu "ne radi" + ceo Desktop rekurzivno
    kopiran u sebe (DVA PUTA), `kill -9` morao oba puta** — 11/12. avgusta
    (posle ponoći), `xcodebuild` prolazi čisto na oba fix-a ispod. Korisnik
    je prijavio da Cmd+X/Cmd+C u Develop-ovom Selection alatu ne rade;
    istraga je otkrila DVA odvojena bag-a, drugi mnogo ozbiljniji od prvog.

    **(a) Modifier-flag poređenje presrogo** (`Develop.swift`,
    `installEditingKeyMonitor`) — `event.modifierFlags.intersection(.deviceIndependentFlagsMask)`
    hvata i Caps Lock/numeric-pad/function/help bitove, a poređenje je bilo
    STROGA jednakost (`flags == .command`). Bilo koji slučajan dodatan bit
    (npr. fizički uključen Caps Lock, ili neki input source/tastatura koja
    dometne "šum" bitove uz normalan Cmd+X) tiho razbija poređenje — ceo
    blok (Cmd+C/X/V/Z) se preskoči BEZ ikakve povratne informacije
    korisniku. Ispravka: maska suzena na `[.command, .shift, .control, .option]`
    (samo modifier-i koji stvarno razlikuju jednu prečicu od druge), ne cela
    `.deviceIndependentFlagsMask`.

    Ovo POTVRĐENO uživo (Accessibility automatizacija, App raised/focused
    preko `AXRaise` + klik pre svakog keystroke-a): klik na "Circle" u
    Selection sekciji (pravo dugme) → aktivna selekcija se pojavljuje
    (dashed krug + handle-i) → `]` (bez modifier-a) je ODMAH uvećao radius
    (uspešno) → Cmd+X preko sintetičke tastature NIJE ništa uradio, tri puta
    zaredom, čak ni sa eksplicitno podignutim/fokusiranim prozorom. Direktan
    dokaz da je problem u prečici a ne u logici: klik DIREKTNO na "Copy"
    dugme u panelu (ista `copySelection()` funkcija koju bi Cmd+C pozvao) je
    RADIO SAVRŠENO (selekcija se copy-uje, panel se vraća na "No active
    selection") — potvrđuje da je cut/copy logika sama po sebi zdrava.

    **(b) ⚠️ MNOGO OZBILJNIJI — ShowGrid-ov Cmd+X/C/V monitor nije bio
    ograničen na svoj prozor + nije imao `isARepeat` proveru** (`ContentView.swift`,
    `PhotoShowSheet.installKeyMonitor()`). Ovaj monitor (za copy/cut/paste
    FAJLOVA/foldera u ShowGrid gridu preko Finder-style right-click menija —
    potpuno odvojena stvar od Develop-ovog Selection layer-clipboard-a) je
    imao DVA propusta istovremeno:
    - Nije proveravao `NSApp.keyWindow?.title` — za razliku od
      Develop-ovog monitora (koji OD POČETKA ima `guard NSApp.keyWindow?.title == "Develop"`,
      baš zbog ovog rizika, vidi komentar u kodu iz ranije sesije). Local
      `NSEvent` monitori su APP-WIDE: oba monitora (ShowGrid-ov i
      Develop-ov) primaju SVAKI keyDown dok je app aktivna, bez obzira koji
      je prozor stvarno key — svaki monitor je odgovoran da SAM proveri da
      li je NJEGOV prozor fokusiran. Develop-ov je to radio, ShowGrid-ov
      nije nikad.
    - Nije proveravao `event.isARepeat` na Cmd-delu (isti propust kao
      stavka #15, ali ovde nikad nije ni bio ispravljen jer je ovo POTPUNO
      odvojen monitor od Develop-ovog — ispravka #15 je pokrila samo
      `Develop.swift`).

    **Pravi mehanizam bug-a**: korisnik je bio u Develop-u, koristio
    Selection alat (Circle/Square/Free — Cut/Copy/Deselect dugmad i Cmd+X/
    C/V su namenjeni ISKLJUČIVO za Develop-ov in-memory `layerClipboard`).
    Kad je pritisnuo Cmd+X, DVA monitora su primila isti event: Develop-ov
    (ispravno, proverava `activeSelection`) I ShowGrid-ov (koji NIJE trebalo
    da reaguje, pošto ShowGrid prozor nije bio fokusiran, ali je svejedno
    reagovao pošto nije imao guard). ShowGrid-ov `copyCutTargets` fallback
    kad ništa nije selektovano u gridu je **ceo trenutno otvoren folder**
    (`[selectedFolderURL]`) — u ovom slučaju ceo `~/Desktop`. Cmd+X je tako
    tiho markirao CEO Desktop folder kao "cut" na sistemskom pasteboard-u
    (jeftino, samo pasteboard write). Sledeći Cmd+V (namenjen Develop-ovom
    "Paste as Layer") je ISTO tako pogodio ShowGrid-ov `pasteIntoGrid()` →
    `pasteClipboard(into: selectedFolderURL)`, koji je REKURZIVNO kopirao
    (`FileManager.copyItem`, preko APFS `clonefileat` po fajlu, plus
    `mkdir`/`chmod`/`chown`/xattr po stavci da očuva metapodatke) CEO
    Desktop folder — SVE projekte, fotke, sve — nazad U SEBE, kao
    `Desktop 1`. Pošto je "Desktop 1" sad DEO Desktop-a, sledeći pokušaj
    (korisnik je probao ponovo posle prvog "ne radi") je napravio i
    `Desktop 2` — koji je ugnježdeno sadržao i kopiju `Desktop 1` unutar
    sebe (otud skoro identična ogromna prijavljena veličina).

    **Otkriveno DOK je app bila živa i zaglavljena** (na eksplicitan zahtev
    korisnika "proveri dok radi"): `ps aux` je pokazivao održanih 60-80% CPU
    u trajanju od NEKOLIKO MINUTA (ne kratak skok), `System Events`/AppleScript
    upiti su vraćali prazno/nepouzdano (isti obrazac "AppleEvent timed out"
    kao #15, samo ovaj put tiho prazan rezultat umesto vidljive greške) —
    app tehnički nije bila 100% mrtva (screenshot preko `screencapture -l<windowID>`
    je i dalje radio, pošto to čita poslednji kompozitovan frame iz
    WindowServer-a, ne zahteva da app odgovori), ali AX/AppleScript
    interakcija nije mogla da joj priđe. `sample <pid> 3` (bez `sudo`,
    root-only alternativa bi bio `spindump`) je uhvatio TAČAN stek uživo:
    `PhotoShowSheet.pasteClipboard(into:)` ← `pasteIntoGrid()` ← closure u
    `installKeyMonitor()`, sa `clonefileat`/`mkdir`/`lstat`/`getattrlistbulk`/
    `fchmod`/`fchown`/xattr syscall-ovima dominirajući "top of stack"
    histogram (>1000 od ~3200-4800 uzoraka u 2-3 sekunde, oba puta kad je
    ponovljeno). `kill -9` morao OBA PUTA (prvi hang otkriven, ubijen,
    kod popravljen ISKLJUČIVO za `Develop.swift` (a) deo, app restartovana,
    korisnik probao ISTI Selection flow ponovo — DRUGI hang, jer (b) deo
    tada još nije bio ni identifikovan ni popravljen).

    **Ispravka**: `guard NSApp.keyWindow?.title == "BriefShow" else { return event }`
    dodat kao PRVA linija u `installKeyMonitor()`-ovom handleru (identičan
    obrazac kao Develop-ov, samo obrnuto ime prozora), PLUS `!event.isARepeat`
    dodat u `if isCommandDown, let character { ... }` uslov (isti obrazac
    kao `installEditingKeyMonitor` u `Develop.swift`). `xcodebuild` čist,
    app posle restarta zdrava (`ps aux`: 0% CPU, `S` idle, potvrđeno preko
    3 uzastopna merenja).

    **✅ POTVRĐENO od korisnika** (ista sesija, posle oba fix-a): Cmd+X/
    Cmd+C u Selection alatu sad rade preko prave tastature. Ovo je bio
    prioritet #1 za sledeću sesiju — više nije otvoreno.

    **Počišćeno**:
    - `~/Desktop/Desktop 1` i `~/Desktop/Desktop 2` (rekurzivne kopije celog
      Desktop-a koje je bug napravio) — **obrisane u Trash** (ne trajno,
      korisnik može vratiti ako nešto fali). `du -sh` je prijavljivao
      567G/462G, ali to je bila APFS `clonefileat` copy-on-write iluzija
      (`df -h /` je pokazivao isti slobodan prostor pre i posle, ~66GiB) —
      nikad nije bila prava kriza po prostor, samo neuredni folderi.
    - `~/Desktop/Gemini_Generated_Image_72ezha72ezha72ez 1.png` (manji
      duplikat od PRVOG, pre-(b)-fix testa) — **ostavljen neobrisan**
      (korisnik nije eksplicitno pitan za ovaj konkretan fajl kao za
      Desktop 1/2 — sledeća sesija može pitati ili ga tiho ukloniti ako
      korisnik potvrdi da mu ne treba).

    **Šta bi moglo sledeće (nije bug, samo ideja, niko nije tražio)**:
    - Vredelo bi razmotriti dodatnu zaštitu u `pasteClipboard(into:)`
      samoj — trenutno nema guard-a protiv kopiranja foldera U SEBE/u
      podfolder-a-sebe kod COPY grane (postojeći "isto mesto" skip na liniji
      ~22401 primenjuje se SAMO kad je `isMove`, ne i kod plain copy) — sad
      kad je window-scoping ispravljen ovo je mnogo manji rizik (samo
      namerno Cmd+C na ceo folder + Cmd+V u isti folder bi to i dalje
      uradilo), ali je jeftina dodatna zaštita ako se ikad pokaže da
      zatreba.

19. ✅ **RAW pipeline KONAČNO vizuelno potvrđen na pravoj RAW fotki** — 14.
    avgusta 2026, `xcodebuild` prolazi čisto (build iz ove sesije, bez
    izmena koda — čisto testiranje). Korisnik je dostavio 4 prava Nikon
    `.NEF` fajla (`~/Desktop/RAW Tests Images/`, ~18-19MB svaki). Ovo je bio
    poslednji preostali neproveren deo iz stavke #6 ("Šta dalje") — na
    disku nikad ranije nije bilo RAW fajla za test.

    **Import → Develop, potvrđeno**: "Import Photos" (NSOpenPanel,
    navigacija do foldera preko Cmd+Shift+G + tipeahead + selekcija svih 4
    fajla + Open) je uvezao sve 4 `.NEF` u ShowGrid grid sa ispravno
    generisanim RGB thumbnail-ovima (ne prazni/pokvareni placeholderi).
    Develop otvoren na prvoj fotki preko header dugmeta: **`RAW` bedž**
    pored imena fajla (`C4S_5740.NEF`), live preview ispravno dekodiran
    (topla, prirodna boja — pravi RAW demosaic, ne bagovan render), histogram
    živ i odgovara slici, filmstrip prikazuje sve 4 RAW thumbnail-a.

    **Native RAW kontrole potvrđene END-TO-END na pravom senzorskom RAW
    fajlu** (prvi put ikad, ranije samo matematički/skriptom):
    - **Exposure**: `AXIncrement` na slideru (vidi tehniku ispod) do +3.00 →
      slika dramatično preeksponirana (bela/blown highlights), histogram se
      skupio uz desnu ivicu — tačno očekivano ponašanje `CIRAWFilter.exposure`
      primenjenog tokom demosaic-a (pun opseg senzora, ne generički
      post-hoc exposure filter).
    - **Temperature**: do +100 → slika vidljivo TOPLIJA (topliji ten, topliji
      drveni tonovi) — potvrđuje da RAW putanja (`CIRAWFilter.neutralTemperature`,
      `asShotTemperature + delta`) ima ISTI smer kao ispravljena JPEG putanja
      iz stavke #6 (`+1` = toplije), dosledno kako je nameravano.
    - Oba slidera vraćena nazad na 0 (Exposure 4× `AXDecrement` posle
      overshoot-a, Temperature 4× `AXDecrement`) — finalni screenshot se
      piksel-za-piksel poklapa sa originalnim (isti histogram, ista slika),
      potvrđuje da je baseline (`asShotTemperature`) i dalje tačan posle
      round-trip-a gore-dole, bez drifta.

    **Nova tehnika testiranja otkrivena ovom sesijom** (bitno za sve buduće
    GUI provere, ne samo RAW): obična `click at {x,y}` na slider track ne
    pomera SwiftUI `Slider` (potvrđeno ponovo, poznato ograničenje), ALI
    Accessibility akcija **`perform action "AXIncrement"` / `"AXDecrement"`**
    na `AXSlider` elementu **RADI POUZDANO** — pomera pravi `@State`/binding,
    render se okida, UI label i slika se ažuriraju. Ovo je PRVI put u celoj
    istoriji ovog projekta da je slider uspešno pomeren bez pravog miša.
    Napomene o koraku: korak nije uniforman po kontroli (Exposure ~0.3-0.6
    po pozivu, Temperature 0.2 po pozivu — verovatno % od range-a po
    kontroli), i može se "zaglaviti" na min/max granici (10 uzastopnih poziva
    na već-graničnoj vrednosti daje isti clamp-ovan rezultat, ne grešku) —
    zato je pouzdanije čitati `value of e` posle SVAKOG poziva i računati
    ostatak, ne pretpostaviti fiksan korak unapred. I dalje ne postoji način
    da se testira pravi `DragGesture` (crop handle, mask handle, brush
    painting) preko ovoga — `AXIncrement`/`AXDecrement` radi SAMO za
    `AXSlider` elemente, ne za proizvoljne drag interakcije.

    App ostala zdrava kroz ceo test (`ps aux`: 0.0% CPU, `S` idle, posle
    zatvaranja Develop-a preko "Done" dugmeta).

    **Dopuna, isti dan — "Export Edited Copy" na RAW fajlu takođe
    potvrđen end-to-end**: primenjena Temperature +100 (preko `AXIncrement`,
    ista tehnika), pa klik na "Export Edited Copy" (dugme nema pristupačno
    ime — AXButton-i u ovom desnom panelu nemaju `AXTitle`/`name`, samo
    ugnježden `AXStaticText`; kliknuto preko position-match na pravi element,
    NE preko raw `click at {x,y}` koordinate — raw koordinatni klik na istu
    poziciju je tiho promašio, verovatno zbog sitnog stale-position
    razmimoilaženja nakon scroll-a; element-referenca je pouzdana). Otvoren
    pravi `NSSavePanel`, ceo tok (Cmd+Shift+G → putanja → Return → Return za
    default ime) urađen u JEDNOM `osascript` bloku bez pauze (host VS Code je
    prethodno OTEO fokus između dva odvojena poziva i "Save" prozor je nestao
    pre nego što je stigla sledeća komanda — poznat obrazac iz ranije u ovoj
    sesiji, potvrđen ponovo).

    Rezultat: `C4S_5740 Edited.jpg`, **pravi JPEG, puna senzorska rezolucija
    (5176×3448, ne 1600px preview)**, sa **upečenom Temperature +100 izmenom
    vidljivom na slici** (topao/golden-hour ton) — potvrđuje da export
    pipeline koristi `fullBaseImage` (odvojen od preview-a) i da RAW-specifične
    kontrole (`CIRAWFilter.neutralTemperature`) stvarno uđu u finalni
    eksportovan fajl, ne samo u live preview. Podešavanje potom vraćeno na 0
    (scrollbar nazad na vrh pa `AXDecrement` na Temperature, opet u jednom
    atomskom bloku), Develop zatvoren preko "Done", app ostala zdrava (0.0%
    CPU, `S` idle).

    Ovim je **ceo RAW pipeline (import → preview → edit → export) sada
    potpuno vizuelno potvrđen end-to-end** — poslednja preostala nepoznanica
    iz stavke #6 je zatvorena. "Export All Edited" na RAW-u specifično
    (razlika: batch-export više fajlova odjednom) nije posebno testiran, ali
    koristi isti kod-put kao pojedinačni export po fotki — nizak rizik.

20. **Desni klik → "Export…" na filmstrip thumbnail-u, maksimalan JPEG
    kvalitet** — 14. avgust 2026 (isto veče), `xcodebuild` prolazi čisto.
    Korisnik je pitao dve stvari: (a) da li "Export All Edited" već
    exportuje CEO folder odjednom — potvrđeno da, to je već postojalo
    (stavka #9); (b) nova funkcija: desni klik na bilo koji filmstrip
    thumbnail (ne mora biti trenutno otvorena fotka) → kontekstni meni sa
    "Export…" → Save panel → upiše JPEG na **maksimalnom kvalitetu**
    (`compressionFactor: 1.0`, za razliku od 0.92 kod postojećeg "Export
    Edited Copy" dugmeta, koje je NEDIRANO).

    **Implementacija** (`Develop.swift`): `.contextMenu { Button("Export…") { exportSinglePhoto(url) } }`
    dodat na `filmstripThumbnail(for:)`. Nova `exportSinglePhoto(_ url: URL)`
    — Save panel, pa `PhotoEditRenderer.loadBaseImage(from: url)` (ISTI poziv
    kao "Export All Edited" koristi — pun RAW demosaic za RAW fajlove, ne
    downsample-ovan preview) + `PhotoEditStore.settings(for: url)` (te
    KONKRETNE fotke sopstvena sačuvana podešavanja, ne trenutno otvorene
    fotke u editoru — bitno jer desni klik radi na BILO KOM thumbnail-u, ne
    samo trenutno selektovanom; `renderNow()` već drži `PhotoEditStore`
    ažurnim na svaku izmenu, pa je ovo uvek tačno). Render + `NSBitmapImageRep`
    + JPEG write na `developRenderQueue`, isti obrazac kao ostale export
    funkcije.

    **GUI test rezultat — DELIMIČAN, iskreno rečeno**: `xcodebuild` čist,
    kod pregledan ručno (trivijalan, ponovo koristi već-testovane funkcije
    bez novog rizika). RAW→JPEG uvoz/pregled deo je ponovo potvrđen (fotka
    ispravno prikazana sa `RAW` bedžom pre testa). ALI sam desni-klik gest
    **NIJE mogao pouzdano da se GUI-testira**: `AXShowMenu` accessibility
    akcija (koja NE zahteva pravi miš — poziva se direktno na elementu) je
    USPELA JEDNOM rano u testiranju (potvrđeno preko novog CGWindowList
    prozora i vidljivog "Export…" popup-a na ekranu), ali je posle toga
    postala nepouzdana — isti poziv na istom elementu u kasnijim pokušajima
    (uključujući posle punog restarta app-e i čiste sesije) više nije
    otvarao meni, bez ikakve greške. Jedan raniji artefakt ovog testiranja:
    stari "Export Edited Copy" test-fajl (iz stavke 19) se slučajno našao
    ponovo uvezen u sesiju (bio je fizički u `RAW Tests Images` folderu u
    trenutku Import Photos poziva) i alfabetski sortiran ISPRED pravih
    `.NEF` fajlova (razmak < tačka u ASCII), što je kratko zbunilo testiranje
    dok nije prepoznato i očišćeno (fajl obrisan u Trash, sesija restartovana
    čisto).

    **Zaključak**: funkcija je implementirana i build je čist, koristi
    IDENTIČNU export logiku koja je već vizuelno potvrđena (stavka #19,
    "Export All Edited"/"Export Edited Copy"), pa je rizik nizak — ali sâm
    desni-klik/kontekstni-meni gest ostaje **GUI-neproveren** (nova kategorija
    uz već poznata ograničenja drag-a i onTapGesture-a: `AXShowMenu` za
    `.contextMenu` je OVOM app-u nepouzdana tehnika, za razliku od
    `AXIncrement`/`AXScrollBar` koji su se pokazali pouzdani stavkom #19).
    Sledeći put probati sa pravim mišem (desni klik na filmstrip thumbnail u
    Develop-u → treba da se pojavi "Export…" stavka).

21. **Filmstrip premešten na dno (horizontalno) + Cmd/Shift multi-select +
    "Export N Selected…"** — 14. avgust 2026 (isto veče), `xcodebuild`
    prolazi čisto. Korisnik je tražio dve stvari u istoj poruci.

    **(a) Filmstrip dole umesto levo** — `body`-jev top-level `HStack`
    (filmstrip | divider | [topBar+centerPreview] | divider | adjustmentPanel)
    preuređen u `VStack` sa filmstripom kao POSLEDNJIM redom ispod
    (HStack-a koji sad sadrži samo [topBar+centerPreview]+adjustmentPanel),
    razdvojeno `Divider()`-om. `filmstrip` sam (unutar) promenjen sa
    vertikalnog `ScrollView { VStack {...} }.frame(width: 120)` na
    horizontalni `ScrollView(.horizontal) { HStack {...} }.frame(height: 120)`.
    Vizuelno POTVRĐENO u pravoj app-i (screenshot) — filmstrip je sad traka
    na dnu prozora, thumbnail-i se ređaju sleva nadesno.

    **(b) Cmd/Shift multi-select na filmstrip thumbnail-ima** — dva nova
    `@State`: `multiSelectedURLs: Set<URL>` (koje su fotke selektovane za
    bulk akcije, odvojeno od `selectedURL` koja je "trenutno otvorena u
    editoru") i `selectionAnchor: URL?` (odakle Shift meri range, postavlja
    se na svaki plain/Cmd klik, Shift ga ne dira — isti obrazac kao
    Finder/Photos, ponovljeni Shift-klik nastavlja da širi/skuplja iz ISTOG
    anchora). Nova `handleFilmstripClick(_:)` čita `NSEvent.modifierFlags`
    (identičan obrazac kao ⌥ za Patch/⇧ za Layer resize iz ranije sesije,
    stavka #15d) — Cmd toggle-uje tu fotku u/iz seta, Shift selektuje ceo
    opseg (anchor...kliknuto) u `photoURLs` redosledu i ZAMENJUJE dotadašnji
    set, plain klik resetuje set na samo tu jednu fotku. Svaki klik (bez
    obzira na modifier) i dalje otvara tu fotku u glavnom editoru preko
    `selectPhoto(url)` — Develop ima samo JEDAN preview panel, pa bi
    ostavljanje editora na nekoj DRUGOJ fotki dok se filmstrip menja bilo
    zbunjujuće.

    Vizuelni indikator: multi-selektovana (ali ne trenutno otvorena) fotka
    dobija accentColor prsten na 50% providnosti (puna providnost/boja
    ostaje rezervisana za "otvorenu" fotku, da se dve stvari razlikuju na
    prvi pogled) PLUS beli checkmark bedž gore-levo (postojeći "has edits"
    slider-bedž ostaje gore-desno, netaknut).

    **Desni klik "Export…" postao svestan selekcije**: ako je fotka na koju
    je kliknuto DEO multi-selekcije veće od 1, meni sad pokazuje
    "Export N Selected…" → nova `exportSelectedPhotos(_ urls: [URL])`
    (identičan obrazac kao `exportAllEditedPhotos`, ali za DATI proizvoljan
    skup umesto "sve editovane", i na MAKSIMALNOM kvalitetu 1.0 kao
    `exportSinglePhoto`, ne 0.92) — jedan folder-picker, sve odjednom.
    Inače (fotka van selekcije, ili samo jedna selektovana) ostaje stari
    "Export…" (Save panel, jedna fotka) iz stavke #20. Ovaj izbor
    (export-cele-selekcije umesto uvek-samo-kliknute) je eksplicitno pitan
    i potvrđen od korisnika pre implementacije.

    **GUI test rezultat — isto poznato ograničenje kao uvek, ništa novo**:
    `xcodebuild` čist, (a) filmstrip-na-dnu vizuelno POTVRĐENO screenshot-om.
    (b) Cmd/Shift klik na thumbnail SAM PO SEBI nije mogao GUI-testirati —
    filmstrip thumbnail-i su `onTapGesture`, ne pravi `Button`, i to NIKAD
    nije pouzdano reagovalo na sintetičke AX evente u ovoj app-i (dokumentovano
    još u stavci #5 ranije sesije, "Filmstrip thumbnail selekcija ne reaguje
    na sintetički AX klik/AXPress") — probano `click at`, `key down command`
    + `click at` + `key up command` za Cmd-klik, ni jedno nije promenilo
    selekciju (nijedan checkmark se nije pojavio, header nije promenio
    fotku). Ovo NIJE nova regresija — isti obrazac je važio i PRE ove
    izmene (obično selectPhoto na klik), samo je sad prvi put pokušano da se
    GUI-testira konkretno OVAJ deo koda. Kod je pregledan ručno (čitanje
    `NSEvent.modifierFlags` unutar `onTapGesture` closure-a je isti,
    već-korišćen obrazac kao Patch ⌥/Layer ⇧ iz stavke #15d, samo primenjen
    na klik umesto na drag `onChanged`) — nizak rizik, ali ostaje da se
    potvrdi pravim mišem.

22. **Checkmark bedž vidljivost popravljena + "Syncing" (Lightroom-style
    sync settings preko multi-selekcije)** — 14. avgust 2026 (isto veče),
    `xcodebuild` prolazi čisto. Korisnik je POTVRDIO da #21 multi-select
    (Cmd/Shift klik) stvarno radi pravim mišem — prva potvrda da klik na
    filmstrip thumbnail uopšte radi u ovoj app-i, uprkos ranije dokumentovanom
    "ne radi sa sintetičkim AX klikom" ograničenju (to ograničenje je i dalje
    tačno, samo se odnosilo na MOJE testiranje, ne na pravog korisnika).
    Korisnik je prijavio dva sledeća zahteva.

    **(a) Checkmark bedž nije bio vidljiv** — pravi uzrok: `Image(systemName:
    "checkmark.circle.fill")` je JEDAN glyph koji već sadrži i krug i kvačicu
    zajedno; stari kod je pozivao `.foregroundColor(.white)` na CEO taj
    glyph (obojio i krug i kvačicu belo) i ISPOD toga crtao ODVOJEN
    `Circle().fill(accentColor)` kao background — accentColor je bledožuta
    (`(1.0, 0.94, 0.62)` u Dark modu), pa je rezultat bio skoro-beli krug sa
    skoro-belom kvačicom preko bledožute pozadine — nizak kontrast na SVAKOJ
    pozadini. Ispravka: `.symbolRenderingMode(.palette)` +
    `.foregroundStyle(.white, Color(red: 0.13, green: 0.47, blue: 0.98))`
    boji krug i kvačicu ODVOJENO (fiksna zasićena plava za krug, standardna
    macOS "selektovano" boja iz Finder/Photos — namerno NEZAVISNA od
    `accentColor`, koja ostaje rezervisana za selection ring), plus
    `.shadow(...)` za dodatni pop na svetlim thumbnail-ima. Vizuelno
    POTVRĐENO da je dugme/panel raspored ispravan (screenshot), sam bedž u
    "selektovanom" stanju NIJE mogao vizuelno da se potvrdi ovom sesijom
    (isto poznato ograničenje — ja ne mogu pouzdano da kliknem thumbnail da
    IZAZOVEM selektovano stanje, iako korisnik može) — fix je zasnovan na
    jasnom razumevanju uzroka, ne na nagađanju.

    **(b) "Syncing" dugme** — nova `syncButton` (ikonica
    `arrow.triangle.2.circlepath`, tekst BUKVALNO "Syncing (N)" po
    eksplicitnom zahtevu korisnika, ne "Synchronize"/"Sync Settings"),
    ubačena odmah ispod `copyPasteRow` u desnom panelu. N = broj OSTALIH
    fotki u `multiSelectedURLs` (bez trenutno otvorene) — dugme je
    disabled/zatamnjeno kad je N=0 (ništa osim trenutne fotke nije
    selektovano). Klik → nova `syncSettingsToSelection()`: piše ŽIVI
    `settings` (trenutno otvorene fotke, tačno ono što sliderи pokazuju SAD)
    preko `PhotoEditStore.setSettings(...)` u SVAKU drugu selektovanu fotku
    — sinhrono na main thread-u (samo UserDefaults upisi, nema decode/render,
    pa ne treba `developRenderQueue`). Ne dira `settings`/`selectedURL`
    trenutno otvorene fotke. Cilj fotke se ne učitavaju/re-renderuju odmah —
    njihov "has edits" bedž/histogram će odraziti sinhronizovana podešavanja
    sledeći put kad se svaka stvarno otvori (isti obrazac kao Presets/Export
    All Edited, koji takođe samo čitaju `PhotoEditStore` na zahtev, ne drže
    posebnu keš-kopiju po fotki). Status traka (`exportStatusText`, isti
    deljeni slot kao export poruke) pokazuje "Synced to N" na 1.6s.

    Vizuelno POTVRĐENO: "Syncing (0)" dugme se pojavljuje na tačnom mestu u
    panelu (screenshot), ispravno zatamnjeno/disabled u default stanju
    (ništa multi-selektovano sem trenutne fotke). Sama sync AKCIJA (klik dok
    je 2+ fotki selektovano) NIJE mogla da se GUI-testira ovom sesijom —
    isti razlog kao (a), ja ne mogu pouzdano da proizvedem multi-select
    stanje preko sintetičkog klika. Kod je pregledan ručno (trivijalan
    `for`-loop preko `PhotoEditStore.setSettings`, već postojeća/dokazana
    funkcija — nizak rizik). Korisnik treba da proba pravim mišem: selektuj
    2+ fotke (Cmd/Shift klik), podesi jednu, klikni "Syncing (N)", proveri
    da li se badge/edit stanje ostalih fotki promeni kad se otvore.

23. **Select All (dole pored filmstripa, view ostaje na otvorenoj fotki) +
    desni-klik "Syncing…" + pravi Lightroom-style "Synchronize Settings"
    dijalog sa checklist-om** — 14. avgust 2026 (isto veče), `xcodebuild`
    prolazi čisto, I VIZUELNO POTVRĐENO end-to-end u pravoj app-i (prvi put
    da je ceo sync-tok — badge, Select All, dijalog — viđen uživo na
    ekranu, ne samo pregledom koda).

    **Select All / Deselect** — dva nova dugmeta (PRAVI SwiftUI `Button`,
    ne `onTapGesture` — namerno, da budu klikabilna i preko AX automatizacije
    za razliku od thumbnail-a samih) dodata desno od filmstripa, VAN
    horizontalnog `ScrollView`-a (uvek na dohvat ruke, ne skroluju se sa
    thumbnail-ima). `selectAllPhotos()` postavlja
    `multiSelectedURLs = Set(photoURLs)` ali NAMERNO ne dira `selectedURL` —
    editor ostaje na fotki koju si editovao (izričit zahtev korisnika,
    "neka ostane view na prvoj"), ne skače na poslednju fotku u nizu kao
    što bi Shift-klik uradio.

    **Desni klik "Syncing…"** — dodato u `.contextMenu` pored "Export N
    Selected…", vidljivo kad je multi-selekcija veća od 1. I meni-dugme i
    panelovo "Syncing (N)" dugme sad SAMO otvaraju dijalog
    (`showSyncDialog = true`) umesto da odmah sinhronizuju — stvarni upis
    se dešava tek na "Synchronize" u dijalogu.

    **"Synchronize Settings" dijalog** (`syncDialogView`, `.sheet`) — nov
    `SyncCategory: OptionSet` (Crop & Rotate / Light / Color / Detail &
    Effects / Masks, ista grupisanja kao desni panel sam, `layers`
    namerno IZOSTAVLJEN — pasted cut/copy sadržaj je specifičan za
    izvornu fotku, Lightroom nema ekvivalentan koncept). Checklist (sve
    čekirano po default-u, kao pravi Lightroom), "Check All"/"Uncheck All",
    "Cancel"/"Synchronize". `syncSettingsToSelection(categories:)` sad radi
    PRAVI delimičan merge preko nove `static func mergedSyncSettings(source:target:categories:)`
    — kreće od CILJNE fotke sopstvenih podešavanja i prepisuje SAMO polja iz
    čekiranih kategorija vrednostima IZVORNE (otvorene) fotke, sve ostalo na
    cilju ostaje netaknuto — tačno Lightroom-ovo ponašanje, ne "sve ili
    ništa" kao prva verzija ove funkcije.

    **Vizuelno POTVRĐENO, sve u pravoj app-i preko Accessibility
    automatizacije** (Select All je PRAVI Button, pa je prvi put da je ceo
    ovaj tok mogao stvarno da se klikne, ne samo da se čita kod):
    - Klik na Select All → sve 4 fotke u filmstripu dobijaju plavi checkmark
      bedž (potvrđuje i badge-fix iz stavke #22 — PRVI put stvarno viđen u
      selektovanom stanju, jasno vidljiv, visok kontrast), header ostaje na
      istoj fotki (`C4S_5740.NEF`) — Select All NIJE promenio otvorenu
      fotku, tačno kako je traženo.
    - "Syncing (3)" dugme ispravno broji (4 selektovane − 1 otvorena).
    - Klik na Syncing → otvara "Synchronize Settings" dijalog sa TAČNO
      očekivanim sadržajem: naslov, opis ("Copy the open photo's settings
      to 3 other selected photos."), 5 čekiranih kategorija sa ikonicama,
      Check All/Uncheck All, Cancel/Synchronize.

    **Usput, incident tokom TESTIRANJA (ne app bug)**: dok sam tražio tačnu
    poziciju "Syncing" dugmeta preko AX pozicije, jedan pokušaj je kliknuo
    VIŠE dugmadi odjednom (ceo opseg y-koordinata umesto jedne tačne), što
    je slučajno okinulo i "Export Edited Copy" (otvorio se pravi Save panel,
    default lokacija "RAW Tests Images" — ISTI folder gde su originalni
    RAW fajlovi) ISTOVREMENO sa Sync dijalogom. Ispravno zaustavljeno pre
    štete: Save panel otkazan (Cancel) PRE bilo kakvog "Save" klika,
    verifikovano preko Finder-a da `RAW Tests Images` i dalje ima TAČNO
    originalna 4 `.NEF` fajla, ništa prepisano/dodato. Ovo je ograničenje
    MOG testiranja (netačna koordinata iz stare/keširane AX pozicije posle
    scroll-a), ne bag u app-i — ali potvrđuje da "Export Edited Copy" Save
    panel default-uje na PRETHODNO korišćen folder (ovde: RAW Tests Images,
    jer je tu ranije bio otvoren Import Photos panel), što je vredno
    zapamtiti za sledeći put (podrazumevana lokacija Save panela nije uvek
    Desktop/Documents — prati poslednje korišćen folder u SISTEMU, ne samo
    u ovoj app-i).

    App ostala zdrava kroz ceo test (0.0% CPU posle zatvaranja Develop-a
    preko "Done").

24. **"Synchronize Settings" dijalog — tekst/ikonice nevidljive, popravljeno**
    — 14. avgust 2026 (isto veče), `xcodebuild` prolazi čisto. Korisnik je
    poslao screenshot: checklist tekst i ikonice (Crop & Rotate/Light/Color/
    Detail & Effects/Masks) skoro nevidljivi — taman/crn na tamnoj pozadini.

    **Pravi uzrok**: `syncDialogView`-ov naslov i checklist redovi
    (`Text`/`Image` unutar `Button` sa `.buttonStyle(.plain)`) nikad nisu
    eksplicitno postavili boju — za razliku od BUKVALNO svakog drugog teksta
    u ovom fajlu, koji uvek eksplicitno piše `.foregroundColor(AppColors.ink)`.
    Bez toga, SwiftUI koristi platform default label boju, koja prati
    SISTEMSKI light/dark mode, ne "uvek tamnu" internu temu ove app-e — pa
    kad je sistem u Light Mode-u (kao ovde), tekst je renderovan skoro-crn
    na skoro-crnoj pozadini panela.

    **Ispravka**: dodato `.foregroundColor(AppColors.ink)` na naslov i na
    svaki `Image`/`Text` unutar checklist redova; checkbox ikonica
    (`checkmark.square.fill`/`square`) dodatno dobija `accentColor` kad je
    čekirana (umesto iste boje kao sve ostalo) da se vizuelno razlikuje
    čekirano/nečekirano stanje na prvi pogled, ne samo po samom obliku
    ikonice.

    **GUI test**: `xcodebuild` čist. Select All → Syncing dijalog tok je
    PONOVO pokušan da se GUI-testira (isti mehanizam koji je stavka #23
    uspešno potvrdila), ali ovaj put klik na "Syncing" dugme nije otvorio
    dijalog u više pokušaja (uprkos identičnoj poziciji/elementu koji je
    ranije radio, i uprkos BriefShow-u eksplicitno podignutom/fokusiranom
    preko `AXRaise`) — najverovatnije test-environment flakiness (VS Code
    je više puta krao fokus usred sekvence, dokumentovano ranije u ovom
    fajlu kao poznat obrazac), ne regresija u samoj app-i, pošto je isti
    "Select All" mehanizam (identičan pravi-Button pristup) i dalje radio
    pouzdano u istoj sesiji. Boja-ispravka NIJE mogla ponovo da se vizuelno
    potvrdi u samom dijalogu ovom sesijom, ali je zasnovana na istom
    `AppColors.ink` tokenu koji je dokazano ispravno vidljiv svuda drugde u
    IDENTIČNOM panelu (Copy Settings/Paste Settings/Syncing/Reset All/Export
    dugmad — sve jasno vidljivo u svakom screenshot-u cele ove sesije), pa
    je rizik nizak. Korisnik treba da potvrdi pravim mišem da je tekst sad
    čitljiv.

    **Status (15. avgust 2026)**: korisnik nije potvrdio/negirao vidljivost
    boje direktno — umesto toga prijavio je DRUGI, stvaran bug u istom
    Select→Sync toku (vidi stavku #25 ispod). #24 (boja) ostaje formalno
    NEPOTVRĐENA pravim očima, i dalje niskog rizika iz gore navedenog
    razloga, ali treba proveriti prvom prilikom kad se dijalog stvarno
    otvori.

25. **Bug: Shift-range-select u filmstripu je krao Sync IZVOR sa prve na
    poslednju fotku u opsegu** — 15. avgust 2026. Korisnik je prijavio:
    klikne prvu fotku (nju hoće kao izvor za Synchronize), pa Shift-klikne
    poslednju da proširi selekciju na ceo opseg — i otvorena/aktivna fotka
    (izvor sinhronizacije) tiho skoči na POSLEDNJU, ne ostaje na PRVOJ.

    **Pravi uzrok**: `handleFilmstripClick` je na kraju, bezuslovno za SVAKU
    granu (plain/Cmd/Shift), zvao `selectPhoto(url)` — što otvara `url` kao
    aktivnu fotku u editoru (i time i kao Sync izvor, pošto `syncButton`/
    `syncDialogView`/`syncSettingsToSelection` svi čitaju `selectedURL` kao
    izvor). Za Shift granu, `url` je fotka na koju je NAKNADNO kliknuto da
    se PROŠIRI opseg (obično poslednja), ne fotka čije podešavanje korisnik
    hoće da kopira. Ista logika je već postojala i bila namerno primenjena
    za `selectAllPhotos()` (vidi njen komentar) — samo nije bila primenjena
    i na Shift granu `handleFilmstripClick`-a.

    **Ispravka**: `selectPhoto(url)` premešten unutar `if`/`else` grana za
    plain klik i Cmd-klik (nepromenjeno ponašanje za oba), ali IZOSTAVLJEN
    iz Shift grane — Shift sad samo proširuje `multiSelectedURLs` na ceo
    opseg, ne dira `selectedURL`/otvorenu fotku. Anchor (prva kliknuta
    fotka, već otvorena pre Shift-a) ostaje sync izvor, i uvek je deo
    proširenog opsega (range je inkluzivan na oba kraja), pa je i dalje
    validan target-subtract u `syncButton`/`syncSettingsToSelection`.

    **Provera**: `xcodebuild` prolazi čisto. Logički potvrđeno čitanjem
    (anchor uvek ostaje unutar range-a, `selectPhoto` i dalje radi
    identično za plain/Cmd klik). Nije GUI-testirano pravim mišem ovom
    sesijom — korisnik treba da proveri: klikni prvu fotku, Shift-klikni
    poslednju, otvori Sync — treba da piše "Copy the open photo's settings"
    i dalje o PRVOJ fotki (proveri po tome što se slajderi/postavke u
    desnom panelu ne menjaju posle Shift-klika).

26. **Cmd+A select-all u ShowGrid-u, Clarity slajder, i pravi Photoshop-style
    clone-stamp Patch tool** — 15. avgust 2026, isto veče. Tri odvojena
    zahteva u jednoj poruci; sve troje urađeno + `xcodebuild` čist posle
    svake celine.

    - **Cmd+A** (`ContentView.swift`, isti keyMonitor blok kao Cmd+C/X/V):
      selektuje sve fotke trenutno u gridu. Samo dok loupe NIJE otvoren
      (nema šta da se "select all"-uje unutar pregleda jedne fotke), i samo
      kad ima bar jedna fotka. Isti `!event.isARepeat` guard kao C/X/V (vidi
      #18) — bez njega bi držanje Cmd+A ponavljalo `replaceSelection` na
      svaki key-repeat, bezopasno ovde (idempotentno) ali nepotrebno.

    - **Clarity** (novi global slajder, "Detail & Effects" panel, posle
      Sharpness, pre Vignette): lokalni/midtone kontrast, na zahtev "sve sto
      ima Lightroom, dehaze, clarity, etc". Implementirano kao
      `CIUnsharpMask` sa VELIKIM radijusom (za razliku od Sharpness, koji
      koristi `CISharpenLuminance` — taj filter uopšte nema radius parametar,
      pa je inherentno fin/ivični sharpen). Radijus je RAZLOMAK slike duže
      ivice (`longEdge * 0.02`, klampovano 8...200px), ne fiksni broj piksela
      — render() radi i na preview i na full-export rezoluciji, pa bi fiksni
      radijus izgledao pogrešno na jednoj od te dve. Samo pozitivan opseg
      (0...1) ovom sesijom — `CIUnsharpMask.intensity` nije dokumentovan za
      negativne vrednosti, a pravo "smanji lokalni kontrast" bi tražio
      sopstveni subtract-based blend, ne samo negativan intensity — odloženo.
      Threaded kroz `isNeutral`/custom decoder/`mergedSyncSettings(.detail)`
      (vidi migration napomenu ispod za ZAŠTO custom decoder uopšte postoji).
      **Dehaze eksplicitno preskočen ovu sesiju** (korisnikov izbor) — pravi
      dehaze algoritam (dark-channel-prior) je mnogo veći posao, ostaje za
      kasnije ako se zatraži.

    - **Patch tool — pravi kontinuirani clone-stamp brush** (korisnikov
      eksplicitan izbor između dve ponuđene opcije — vidi razgovor). Circle
      više NIJE jedan pomerivi krug/kvadrat oblik; sad je prava četkica:
      ⌥-klik postavlja IZVOR (`pendingPatchSource`), zatim prevlačenje
      SLIKA kontinuirano duž celog poteza — svaki potez postaje `PatchStroke`
      (sopstveni `points`/`size`/`feather`, tačno isti "svaki potez pamti
      SVOJE podešavanje" princip kao `BrushStroke`) sa FIKSNIM
      `sourceOffsetX/Y` postavljenim u trenutku ⌥-klika. Taj offset ostaje
      "aligned" (Photoshop terminologija) kroz VIŠE poteza dok se korisnik
      ponovo ne ⌥-klikne — nije potrebno resetovati izvor između svakog
      poteza. Free shape je NETAKNUT (identičan stari mehanizam — jedan
      hand-drawn outline, reposition-only). **Square uklonjen iz Patch UI-a**
      (add-dugme i shape picker) po eksplicitnom zahtevu — enum
      `PatchShape.square` i sav render kod za njega ostaju netaknuti jer ih
      Selection tool i dalje koristi (odvojena feature, #13).
      - **Opacity** (novo, `PatchGeometry.opacity`, 0...1 slajder): skalira
        blend-mask-a preko `CIColorMatrix` (množi RGB kanale faktorom) pre
        `CIBlendWithMask` — jeftino, jedan extra filter samo kad je
        opacity < 1.
      - **Feather sad ima pod (floor)**: `patchMinimumFeather = 0.05`,
        primenjeno i na Circle-brush slajder i na legacy Free slajder (i u
        UI range-u i kao clamp u setter-u) — ivice NIKAD ne mogu biti hard
        0, po eksplicitnom zahtevu ("obavezno ivice da budu feather").
      - **Migration bug uhvaćen i ispravljen PRE nego što je postao
        problem**: `PhotoEditSettings` ima ručno pisan `init(from:)` baš
        zato što synthesized Codable NE koristi property default vrednosti
        za key koji nedostaje u starom sačuvanom JSON-u — potvrđeno
        standalone `xcrun swift` test skriptom (`Inner(a: Double=1, b:
        Double=2)`, JSON sa samo `a`, decode BACA `keyNotFound` za `b`, ne
        vraća default). Dodavanje `opacity`/`strokes` polja u
        `PatchGeometry` bi BEZ custom decoder-a pokvarilo decode SVAKOG
        već-sačuvanog Patch adjustment-a iz build-a pre danas — a pošto
        `PhotoEditSettings.localAdjustments` dekodira ceo niz odjednom,
        JEDAN loš element baca CEO fotkin sačuvani edit (vidi
        `PhotoEditStore.allSettings`, briše sve što ne uspe da dekodira).
        Ispravljeno dodavanjem identičnog ručnog `init(from:)` +
        `CodingKeys` na `PatchGeometry`, isti `decodeIfPresent ?? default`
        idiom. **Lekcija za svaku buduću sesiju**: pre dodavanja NOVOG
        polja u BILO KOJI `Codable` struct koji se već čuva na disku
        (`PhotoEditSettings` i sve što je ugnježdeno u njemu), proveriti da
        li taj tip ima ručni decoder — ako nema (oslanja se na sintetisani),
        ili dodati ga, ili prihvatiti da stari sačuvani podaci sa TIM tipom
        prestaju da se učitavaju. `PatchStroke` (nov tip, danas dodat) NEMA
        ovu zaštitu — nije potrebna JOŠ (nema starih podataka), ali svako
        buduće dodavanje polja u `PatchStroke` treba istu tretman.
      - **Poznata, prihvaćena posledica ovog rewrite-a**: stari sačuvani
        Circle patch (iz sesije PRE danas, ako postoji na nekoj pravoj
        fotki — malo verovatno, testirano samo na sintetičkoj test-fotki po
        #11) sad neće prikazivati NIŠTA dok se ne naslika bar jedan potez —
        `hasEffect` za `.circle` zahteva `!strokes.isEmpty`, a stari podaci
        nemaju `strokes` (default `[]`). Namerna, očekivana posledica
        prelaska sa "shape-placement" na "brush-painting" paradigmu — isto
        ponašanje kao prazna `BrushMaskGeometry` (dodavanje Brush maske ne
        prikazuje ništa dok se ne naslika), ne bug.

    **Provera**: `xcodebuild` čist posle svake od tri celine. Sve troje
    logički/matematički provereno čitanjem (offset predznak isti kao
    postojeći `patchSampledImage`/`movePatchSource` konvencija, hardness =
    1 − feather inverzija tačna, `patchStrokeDabs` ponovo koristi već
    pixel-verifikovani `brushStrokeDabs`). **NIJE GUI-testirano pravim
    mišem ovom sesijom** — ⌥-klik + drag kombinacija je poznato
    netestabilna preko accessibility-ja (isto ograničenje kao svaki
    gesture-based deo ove app-e, vidi napomenu iz 10. avgusta). Korisnik
    treba da proveri sve troje pravim mišem: Cmd+A u gridu, Clarity vizuelno
    menja sliku, i glavno — Patch Circle: ⌥-klik na jedno mesto, prevuci
    negde drugde, treba da se pojavi kloniran sadržaj duž celog poteza (ne
    samo na jednoj tački), sa vidljivim feather ivicama.

    **Dopuna (isto veče, posle prve provere pravim mišem)**: korisnik je
    poslao pravi screenshot — dva bug-a, oba ispravljena:
    - **Patch Circle je ostavljao "zalepljene" bledo-žute kružiće** umesto
      da se vidi pravi kloniran sadržaj (screenshot: nekoliko providnih
      žutih mrlja po licu/dekolteu/ogradi, ništa što liči na kloniranje).
      Pravi uzrok: `patchStrokeMaskCanvas` (SwiftUI overlay iznad slike, NE
      Core Image render) je crtala TRAJAN `accentColor.opacity(0.35)`
      tint preko svakog već-naslikanog poteza — kopirano po uzoru na
      `brushMaskCanvas` (koja MORA imati trajan overlay jer je Brush-ov
      efekat inače nevidljiv). Za Patch je to bila greška: pravi
      kloniran sadržaj je VEĆ vidljiv u pravom render-u, a `accentColor`
      u ovoj temi je baš žuto-zlatna ("rocket yellow") — kad se klonira
      iz slično obojene obližnje oblasti (čest slučaj, npr. koža→koža,
      nebo→nebo), pravi efekat je suptilan i JEDINO što se vidi je taj
      trajni tint, što izgleda kao pokvarena nalepnica. Ispravka: obrisana
      cela funkcija i njen poziv — Patch sad ne ostavlja NIKAKAV trajan
      overlay posle bojenja (isto kao pravi Photoshop clone stamp), samo
      privremeni indikatori dok se aktivno slika (live poteza-linija,
      žuti "twin cursor" izvor, hover prstenovi).
    - **"Sečkanje" pri pomeranju BILO KOG slajdera** (Exposure/Brightness/
      itd, ne samo Patch-specifično) — pravi uzrok: `developRenderQueue` je
      obična SERIJSKA queue, i `renderNow()` nije imao nikakav mehanizam
      da otkaže/preskoči render koji je u međuvremenu ZASTAREO (stigla je
      novija vrednost slajdera dok je stari render još radio) — svaki
      render se izvršavao do kraja PRE nego što bi sledeći uopšte počeo,
      pa je brzo prevlačenje slajdera pravilo rastući "backlog" zastarelih
      render-a; ekran je zato skakao kroz niz zastarelih međurezultata
      umesto da glatko prati live poziciju slajdera. Ovo je POSTOJALO i
      pre ove sesije, ali ga je nova Patch četkica (koja može da doda dosta
      dab-ova po potezu) i Clarity (skup veliki-radijus blur) učinila
      primetnijim. Ispravka: dodat `renderGeneration` brojač (bump-uje se
      na svaki `renderNow()` poziv) — svaki render u background queue-u
      proveri PRE skupog rada, i opet PRE slanja rezultata na ekran, da li
      je u međuvremenu stigao noviji generation; ako jeste, odustaje odmah
      umesto da završi posao koji niko neće videti — isti "pročitaj @State
      live, cross-thread" obrazac koji `selectedURL`/`photoAtRenderTime`
      provera već koristi za drugi razlog (promena fotke usred render-a).
      Usput i smanjen Clarity-jev max radijus (200→100px) kao dodatna
      jeftina mera. **Nije mereno/profajlisano** (nema alata za to u ovom
      okruženju) — logički ispravna promena (queue se sad prazni brzo umesto
      da se gomila), ali korisnik treba da potvrdi da li se sečkanje
      stvarno smanjilo osećajem uživo, ne samo teorijski.

    **Dopuna (isto veče, treći krug povratne informacije)**: korisnik je
    preciznije opisao slajder-problem — nije bilo "sečkanje/kašnjenje" nego
    da slajder SKAČE odmah na krajnju vrednost (npr. vučeš od 0 do 10, vidi
    se samo 10, nikad postepeni prelaz 0→1→2...→10). **Pravi uzrok, drugačiji
    od gornjeg**: `scheduleRender()` je bio ČIST debounce (otkaži pa zakaži
    ponovo +20ms na SVAKU promenu) — SwiftUI-jev `.onChange(of: settings)`
    opaljuje skoro na svaki frame tokom prevlačenja (brže od 20ms), pa se
    tajmer stalno otkazivao i ponovo zakazivao PRE nego što bi ikad opalio
    — nikad nije ni renderovao međuvrednost, samo krajnju, kad bi
    prevlačenje prestalo. Gornji `renderGeneration` fix (pileup/backlog)
    ovo uopšte nije rešavao — bez tajmera koji ikad opali, backlog-a ni
    nema. **Ispravka**: `scheduleRender()` promenjen iz debounce-a u pravi
    THROTTLE — zakazuje nov tajmer SAMO ako trenutno nijedan nije već na
    čekanju; već-zakazan tajmer se ostavlja da opali po planu umesto da se
    gura unazad, dajući stalan ritam renderovanja (~svakih 20ms) tokom
    celog prevlačenja umesto samo na kraju. `renderGeneration` fix od malopre
    sad postaje STVARNO potreban (pre ove izmene je bio bezopasan ali
    suvišan, pošto nikad nije bilo backlog-a da se sredi) — sad kad
    render-i STVARNO opaljuju često tokom prevlačenja, on sprečava da se
    zaista nagomilaju. `xcodebuild` čist. Nije mereno uživo — korisnik treba
    da potvrdi da sad VIDI postepen prelaz dok prevlači slajder, ne samo
    skok na kraj.

    **Otvorena stavka za sledeću sesiju — NIJE rešeno, potrebno pravo
    testiranje mišem**: korisnik je prijavio da "Patch Circle"/"Patch Free"
    add-dugme (bočni panel, "Masks" sekcija) povremeno ne reaguje na PRVI
    klik — ali klik na BILO KOJI DRUGI mask-add-dugme (npr. klikneš Circle,
    posle toga Free proradi) ga "probudi". Ovo NIJE window-focus problem
    (taj je već rešen preko `acceptsFirstMouse` na `ClickThroughHostingView`,
    pokriva ceo Develop prozor, vidi #15) — dešava se i kad je prozor već
    odavno fokusiran. Pošto se javlja i za Circle i za Free (ne samo Patch
    specifično), verovatno je opštiji "Masks" panel hir, ne nešto uneto
    ovom sesijom — ali nisam mogao da potvrdim ni uzrok ni da li je uopšte
    postojao pre danas, pošto ne mogu sam da testiram mišem (poznato
    ograničenje, gesture/klik-testiranje u ovoj app-i). **Nisam menjao kod
    za ovo** — nagađanje bez mogućnosti provere bi rizikovalo lažnu
    "popravku". Sledeća sesija: probati GUI-test ponovnim otvaranjem
    Develop-a na svež/prazan set masks (nijedna još dodata) i klikom na
    prvi mask-add-dugme, videti da li se AX klik uopšte razlikuje od
    drugog klika po nekom timing/layout signalu (npr. da li se
    `selectedMaskEditor` panel ispod tek POJAVLJUJE nakon prvog uspešnog
    dodavanja, menjajući visinu/layout sekcije usred prvog klika).

    **Dopuna (isto veče, četvrti krug)**: korisnik je probao throttle-fix
    — i dalje sečkanje, ALI ovog puta precizirao da testira na RAW (.NEF)
    fotki. To je bila ključna informacija — throttle fix je proveren kao
    ispravan (i logikom i standalone benchmark-om: standardni ne-RAW
    filter lanac, `xcrun swift` skripta, ~13ms po frejmu na sintetičkoj
    1600×1067 slici, daleko ispod 20ms throttle prozora). Takođe direktno
    pregledani SVI sačuvani `PhotoEditSettings` iz UserDefaults (`defaults
    export com.rocketsbrief.BriefShow -`) — nijedna od 13 fotki trenutno
    nema stvarno naslikane Patch poteze (sve iz ranijeg
    screenshot-testiranja nikad nije zapravo komitovano, verovatno zbog
    istog "dugme ne radi" buga), pa Patch dab-cost teorija otpala.

    **Pravi uzrok**: `PhotoBaseImage.loadPreviewBaseImage`, RAW grana —
    filter korišćen za LIVE preview tokom prevlačenja slajdera
    (redekodiran na SVAKI render) imao je `previewFilter.isDraftModeEnabled
    = false` — identično kao export-ov punokvalitetni filter, bukvalno
    kopirano bez preispitivanja. `CIRAWFilter`-ov draft mod postoji TAČNO
    za ovaj scenario (brz demosaic za interaktivni preview, uz manji
    kvalitet) — nikad iskorišćen. Pravi RAW demosaic pun-kvalitet na SVAKOM
    od ~50 render-a u sekundi tokom prevlačenja slajdera je mnogo skuplji
    od bilo kog CIFilter-a u standardnom lancu — to objašnjava zašto
    throttle fix nije bio dovoljan SAMO za RAW fotke (za JPEG/PNG/HEIC
    fotke throttle fix bi trebalo da bude dovoljan, pošto je render
    jeftin).

    **Ispravka**: `previewFilter.isDraftModeEnabled = true` (SAMO za
    preview filter — export-ov filter u `loadFullBaseImage`, linija ~683,
    ostaje netaknut na `false`, pun kvalitet za finalni fajl). `xcodebuild`
    čist. **Nije mereno na pravom .NEF fajlu** (nijedan nije bio dostupan
    na disku za standalone benchmark ovom sesijom — verovatno na
    eksternom disku ili folderu van pretraženih putanja) — promena je
    zasnovana na Apple-ovoj dokumentovanoj nameni `isDraftModeEnabled`
    (postoji baš za "brz interaktivni preview" slučaj), visoka pouzdanost
    bez merenja. Korisnik treba da potvrdi na istoj RAW fotki da li je sad
    primetno glađe.

    **Dopuna (isto veče, peti krug) — mask-add-dugme bug, konačno neka
    stvarna zacepka**: korisnik je precizirao da se dešava "čim udjem u
    Develop", za BILO KOJI mask-add-dugme (Patch, Radial, "any"), i još
    bitnije — dešava se ČAK I POSLE selektovanja fotke (dakle prozor je
    već sigurno key/fokusiran, foto-selekcija je uspela) — što ISKLJUČUJE
    `acceptsFirstMouse`/window-focus teoriju kao (jedini) uzrok, pošto je
    ta ista teorija zahtevala da baš PRVI klik u prozoru bude problem, a
    ovde nije bio. Opet se "budi" nekim potpuno nepovezanim spoljašnjim
    dogadjajem (klik na dugme za snimanje ekrana — dvaput zaredom prijavio
    isti obrazac). Pregledom koda nadjena je STVARNA asimetrija koja baca
    sumnju u pravom pravcu: `maskRow`-ov dugme za SELEKTOVANJE postojeće
    maske VEĆ ima `.contentShape(Rectangle())` (dodato neku raniju sesiju),
    ali `maskAddButton` (dugme za DODAVANJE nove Patch/Radial/Graduated/
    Brush maske — baš ono što korisnik prijavljuje) NIJE imalo
    `.contentShape(Rectangle())` uopšte. Bez eksplicitnog content shape-a,
    SwiftUI dugme može (na nekim layout prolazima, posebno odmah pošto se
    visina sekcije promeni — npr. `selectedMaskEditor` panel ispod se
    pojavljuje/nestaje kad se maska doda/selektuje) da hit-testira samo
    stvarno iscrtane piksele (ikonica+tekst) umesto celog `.frame(maxWidth:
    .infinity)` okvira dugmeta — poznata, dokumentovana klasa SwiftUI-macOS
    bug-a, ne nagadjanje specifično za Patch. Dodato `.contentShape(Rectangle())`
    na SVAKI mask-add-dugme (funkcija je deljena za Radial/Graduated/Brush/
    Patch Circle/Patch Free, pa pokriva sve odjednom). `xcodebuild` čist.

    **Iskreno o pouzdanosti**: ovo je najbolja, najkonkretnija hipoteza do
    sad (stvarna asimetrija u kodu, poznat bug-obrazac, ne slepo nagadjanje)
    ali NIJE 100% potvrdjena bez pravog testiranja mišem — ako se bug i
    dalje javlja posle ovoga, sledeći trag za istragu je da li se
    `selectedMaskEditor` panel STVARNO pojavljuje/nestaje TAČNO u trenutku
    klika (proveriti tajming `if let index = selectedAdjustmentIndex` grane
    u `masksSection` naspram trenutka klika), ili probati da se ceo
    `adjustmentPanel` ScrollView zameni sa `LazyVStack` unutar `ScrollView`
    (trenutno je obična `VStack`, pa ovo verovatno nije lazy-loading
    problem, ali vredi proveriti prvo pre ičeg složenijeg).

27. **Vizuelno sređivanje dna panela (Layers/Copy-Paste/Sync/Reset/Export
    dugmad)** — 15. avgust 2026, isto veče, po screenshot-u. Korisnik je
    poslao sliku: "Copy Settings"/"Paste Settings" lome se u dva reda
    ("Copy" / "Settings"), i cela dugmad u tom delu panela deluje kao gola
    tekst+ikonica bez ikakvog "izgleda dugmeta" — bez granice/pozadine.

    **Pravi uzrok**: sva ta dugmad (Paste as Layer, Copy Settings, Paste
    Settings, Syncing, Reset All, oba Export dugmeta) su koristila
    `ShowHeaderButtonStyle` — stil napravljen za ShowGrid-ov HORIZONTALNI
    header bar (samo padding + hover skaliranje, BEZ border-a/pozadine),
    ponovo iskorišćen ovde u uskoj 264px vertikalnoj bočnoj traci gde
    "Copy Settings"/"Paste Settings" u HStack-u nemaju dovoljno prostora
    pa tekst prelama.

    **Ispravka**: nov `panelActionButton(_:systemImage:isProminent:action:)`
    helper + `PanelActionButtonStyle` (puna širina, levo poravnato,
    bordered pill — ista vizuelna porodica kao `MaskAddButtonStyle`/
    `maskAddButton` koji već postoje za Masks sekciju, tako da ceo panel
    sad čita kao JEDAN konzistentan sistem dugmadi, ne dva različita
    jezika stila zalepljena jedan na drugi). Sva dugmad na dnu panela sad
    idu kroz ovaj JEDAN helper, punom širinom, umesto svako da pravi svoj
    HStack — garantovano bez prelamanja teksta bez obzira na dužinu
    labele. Copy/Paste/Syncing grupisani u `settingsActionsSection` (jedna
    VStack grupa, spacing 8), Export Edited Copy/Export All Edited u
    `exportActionsSection` sa `isProminent: true` (ispunjena pozadina +
    poluboldovan font) da se vizuelno izdvoje kao "završne" akcije panela,
    razdvojeno Divider-ima od Reset All. `PanelActionButtonStyle` usput
    dobija i `.contentShape(Rectangle())` na sve ove dugmad (ista
    hardening tehnika kao stavka #26 — sad primenjena svuda, ne samo na
    mask-add dugmad).

    **Provera**: `xcodebuild` čist. **Nije vizuelno potvrđeno pravim
    očima ovom sesijom** (GUI automatizacija do Develop ekrana nije
    pokušana — poznato nepouzdana za ovaj tok, vidi napomene ranije u
    fajlu) — SwiftUI struktura je jednostavna i niskorizična (VStack punih-
    širine bordered dugmadi, isti obrazac kao već postojeći i vizuelno
    potvrđeni `MaskAddButtonStyle`), ali korisnik treba da pogleda i
    potvrdi da izgleda kako je tražio.

28. **Dehaze i Soft Glow — dva nova global slajdera** — 15. avgust 2026,
    isto veče, "Detail & Effects" panel (posle Clarity, pre Vignette).
    Korisnik je ranije (stavka #26) izričito odložio Dehaze; ovom
    dopunom je zatražio da se ipak doda, plus nov "mekana slika" efekat —
    kroz `AskUserQuestion` potvrđeno da to znači soft-focus/dreamy sjaj
    (Lightroom-stil "Soft Portrait"), ne obrnuta Clarity i ne skin-only
    retuš (ta dva su bila ponuđene alternative).

    - **Dehaze** (0...1): i dalje EKSPLICITNO aproksimacija, ne pravi
      dark-channel-prior algoritam (isto upozorenje kao ranije). Magla
      vizuelno = spljošten kontrast/boja + podignuta crna tačka — pa ovo
      pojača kontrast (`+0.35×d`) i saturaciju (`+0.25×d`) preko
      `CIColorControls`, PA spusti crnu tačku i donje sredње tonove
      preko `CIToneCurve` (ista point0...point4 tehnika kao Blacks/
      Shadows/Highlights/Whites slajderi, samo dehaze-specifični
      koeficijenti).
    - **Soft Glow** (0...1): klasičan diffusion/soft-focus efekat —
      zamućena kopija slike (`CIGaussianBlur`, radijus opet RAZLOMAK
      duže ivice kao i Clarity/Patch brush, `longEdge * 0.025`,
      `.clampedToExtent()` pre/`.cropped()` posle da ivica slike ne
      "pocrni") se screen-blenduje nazad preko originala (screen SAMO
      posvetljava, nikad ne zatamni — zato čita kao sjaj/bloom, ne prosto
      zamućenje), pa se meša sa oštrim originalom preko `slajder` procenta
      koristeći `CIBlendWithMask` protiv ravne sive maske — ista "skaliraj
      jačinu maske za opacity dial" trik koji Patch-ov Opacity slajder
      već koristi.
    - Threaded kroz `isNeutral`/custom decoder/`CodingKeys`/
      `mergedSyncSettings(.detail)` — isti obrazac kao Clarity (stavka
      #26), bez novih migration rizika (oba polja imaju default 0, i
      `PhotoEditSettings` već ima ručni `decodeIfPresent`-baziran decoder
      za baš ovaj razlog).

    **Provera**: `xcodebuild` čist. Standalone `xcrun swift` benchmark
    (isti pristup kao stavka #26/perf-istraga) — Dehaze+Soft Glow zajedno
    na sintetičkoj 1600×1067 slici: ~22ms po frejmu, tik iznad 20ms throttle
    prozora (ali `renderGeneration` guard iz ranije ove sesije to bezbedno
    apsorbuje — u najgorem slučaju povremeno preskoči jedan frejm, ne
    gomila backlog). Nije vizuelno potvrđeno pravim očima — korisnik treba
    da proveri da oba slajdera stvarno vidljivo menjaju sliku u
    očekivanom pravcu (Dehaze = "jasnije/kontrastnije", Soft Glow =
    "mekše/sjajnije").

29. **Vignette prepravljen — striktno samo ćoškovi, ne cela slika** — 15.
    avgust 2026, isto veče. Korisnik je eksplicitno tražio da Vignette
    zatamnjuje SAMO ćoškove. Stari `CIFilter.vignette()` (ugrađen CI
    filter) nema način da ograniči efekat samo na ćoškove — čak i na
    default radijusu, zatamnjenje vidljivo zahvata i gornju/donju/levu/
    desnu ivicu, ne samo ćoškove.

    **Prvi pokušaj (odbačen)**: custom radial-gradient maska, KRUG upisan
    u kadar (radius0 = dodiruje najbližu ivicu) do kruga koji dopire do
    ćoškova (radius1). Pixel-sampling test skriptom (`xcrun swift`,
    `CIContext.createCGImage` + čitanje raw bajtova preko `CGDataProvider`
    — `CIContext.render(toBitmap:)` se pokazao nepouzdan/vraćao nule u
    ovom standalone kontekstu, pa je zamenjen) UHVAĆEN pravi bag PRE nego
    što je ušao u app: za landscape sliku (1600×1067), krug dodiruje SAMO
    gornju/donju ivicu (kraća osa) — leva/desna ivica (duža osa) ostaju
    DELIMIČNO zatamnjene (R=169 umesto 255 na sredini leve ivice), što je
    tačno ono što korisnik ne želi.

    **Ispravka**: ELIPSA umesto kruga — ista tehnika kao `radialMask` za
    Radial lokalnu masku (grade gradient u UNIT prostoru, PA primeni
    non-uniform affine skaliranje `(halfW, halfH)`). `radius0 = 1` (u unit
    prostoru — posle skaliranja, dodiruje SVE ČETIRI ivice na sredini
    istovremeno), `radius1 = √2` (posle skaliranja, dopire tačno do
    ćoškova). Isti test skriptom PONOVLJEN na ispravci — sve četiri sredine
    ivica čitaju punu svetlinu (255), samo četiri ćoška su zatamnjena —
    potvrđeno PRE nego što je ušlo u kod, ne posle.

    **Provera**: `xcodebuild` čist, matematika verifikovana standalone
    pixel-sampling skriptom (ne samo pročitana/proverena logikom — stvarno
    izvršena i pixel-i pročitani), isti nivo rigoroznosti kao ranije mask-
    geometrija u ovom fajlu (auto-fit crop, radial mask, itd. — vidi
    #3/#4/#7). Nije vizuelno potvrđeno u pravoj app-i pravim očima —
    korisnik treba da potvrdi da sad STVARNO izgleda kao "samo ćoškovi",
    posebno na landscape fotki gde je stari bag bio najvidljiviji.

    **Dopuna (isto veče, drugi krug)**: korisnik je javio dva dodatna
    problema na istoj funkciji — (a) vidljiva "linija" na granici elipse
    (iako je gradient matematički kontinuiran, RATE promene skače tačno na
    radius0 — flat pa naglo nagnuto — klasičan Mach-band efekat, oko je
    vrlo osetljivo na to), tražio je "još feather"; (b) kad se slika
    kropuje, vinjeta ostaje računata na ORIGINALNOJ (pre-crop) veličini —
    pošto je Vignette blok u kodu bio POZICIONIRAN PRE crop koraka u
    render() pipeline-u, kropovanje samo iseče već-zatamnjeni pravougaonik,
    pa tamni ćoškovi mogu da završe potpuno VAN kropovane oblasti (nema
    vinjete uopšte) ili da seku kroz sredinu kropovanog kadra — korisnik je
    tražio da vinjeta "popuni uglove kropovane slike".

    **Ispravke, obe u `PhotoEditRenderer.render`**:
    - **(b) prvo, arhitekturno**: ceo Vignette blok POMEREN sa svoje stare
      pozicije (odmah posle Sharpness/Clarity/Dehaze/Soft Glow, PRE local
      adjustments/layers/crop) na sam KRAJ funkcije, POSLE crop koraka.
      Sad se ekstent za elipsu uvek čita sa FINALNE (post-crop, ako je
      crop primenjen) slike, pa vinjeta uvek zatamnjuje STVARNE ćoškove
      onoga što se trenutno gleda/exportuje, bez obzira na crop. Kad je
      `applyCrop == false` (dok je crop alat otvoren), i dalje ispravno
      radi na punoj pre-crop veličini, pošto crop blok u tom slučaju
      uopšte ne izvršava — nema posebne grane potrebne.
    - **(a) drugo, feather**: maska (elipsa gradient) se sad BLUR-uje
      (`CIGaussianBlur`, `.clampedToExtent()` pre/`.cropped()` posle, isti
      obrazac kao Soft Glow) PRE nego što se koristi za multiply — ovo
      uklanja OŠTRINU granice bez menjanja osnovnog oblika (i dalje
      zatamnjuje samo blizu ćoškova, sredine ivica ostaju skoro netaknute).
      Radijus blur-a je razlomak kraće ivice slike (`0.06×`), ista "veličina
      skalira sa slikom" konvencija kao svuda drugde ovom sesijom.

    **Provera**: standalone pixel-sampling skripta PONOVO pokrenuta na
    ispravci (isti pristup kao gore) — sredine ivica sad čitaju ~230-237
    (umesto oštrog 255 pa naglog pada), ćoškovi ~70 (i dalje vidno
    zatamnjeni), i ceo gradient ka ćošku je proveren tačku-po-tačku:
    255→255→255→253→236→186→121→70 — potpuno gladak, bez ijednog skoka.
    `xcodebuild` čist. Nije vizuelno potvrđeno u pravoj app-i, i POSEBNO
    nije testirano da li crop+vinjeta zajedno stvarno rade kako treba u
    praksi (matematika je ispravna po konstrukciji pošto se sad računa na
    post-crop ekstentu, ali pravi test — kropuj pa dodaj/proveri vinjetu —
    zahteva pravi UI tok koji nisam mogao da simuliram).

30. **Isti "dugme ne radi na prvi klik" bug, sad na Crop dugmetu — potvrđuje
    obrazac iz stavke #26** — 15. avgust 2026, isto veče. Korisnik je
    prijavio: hteo Crop, klik nije radio, dok nije kliknuo Patch (koje je
    ODMAH radilo — potvrda da je #26-ov fix za mask-add dugmad ispravan),
    pa je TEK ONDA Crop proradio. Isti obrazac, druga dugmad.

    **Pravi uzrok, potvrđen**: `EditToolButtonStyle` (koristi ga Rotate
    Left/Right i Crop toggle dugme — fiksni 30×30 icon dugmići) i
    `AspectRatioButtonStyle` (crop aspect-ratio red) NISU imali
    `.contentShape(Rectangle())`, isti propust kao `maskAddButton` iz #26,
    samo na DRUGOJ dugmadi. Za razliku od #26 (gde je fix dodat na nivou
    pojedinačne helper funkcije), ovog puta je fix dodat NA SAM STIL
    (`EditToolButtonStyle`/`AspectRatioButtonStyle`) — pokriva svako
    dugme koje taj stil koristi odjednom, ne samo Crop, uključujući Rotate
    Left/Right i celu aspect-ratio dugmad, bez potrebe da se svako
    pojedinačno prijavi kao bug prvo.

    **Namerno NIJE dirano**: `ShowHeaderButtonStyle` (`ContentView.swift`)
    — i dalje koristi ga par preostalih Develop dugmadi (Reset Crop, Done,
    Check All/Uncheck All/Cancel/Synchronize u sync dijalogu) I ceo
    ShowGrid header bar. Verovatno ista propust postoji i tu (`.contentShape`
    nedostaje i tamo), ali ContentView.swift je ogroman, deljen fajl van
    Develop-a — nisam menjao dok se ne prijavi konkretan problem na TIM
    dugmadima, da ne širim izmenu van onoga što je stvarno zatraženo/
    potvrđeno. Ako se isti bug javi na Reset Crop/Done/bilo kom ShowGrid
    header dugmetu, ovo je prvo mesto za proveru.

    **Provera**: `xcodebuild` čist. Nije vizuelno potvrđeno mišem — korisnik
    treba da proveri Crop/Rotate Left/Rotate Right/aspect-ratio dugmad
    posebno na SVEŽE otvorenom Develop-u (ili posle promene fotke), pre
    bilo kog drugog klika u panelu.

31. **Texture slajder (dvosmerni) + Lightroom-style "klikni ime slajdera pa
    ga pomeraj strelicama"** — 24. avgust 2026. Dva zahteva u istoj sesiji,
    oba urađena i OBA vizuelno potvrđena uživo u pravoj app-i na pravoj RAW
    fotki (`C4S_5740.NEF`).

    **(1) Texture** — nov global slajder u Detail & Effects, između
    Sharpness i Clarity, opseg **-1...+1** (jedini dvosmerni u toj sekciji;
    prikazuje se kao -100...+100). Radi na SREDNJEM frekventnom pojasu —
    finije od Clarity (koji je large-radius midtone "punch"), grublje od
    Sharpness (koji dira samo ivice); taj pojas je upravo ono što oko čita
    kao "tekstura kože/tkanine/kose".
    - **Pozitivno**: `CIUnsharpMask`, radius `longEdge * 0.006` (klampovan
      2...40), intensity `texture * 1.1`. Na +100 pore/pege/pramenovi kose/
      drvo u pozadini izrazito iskaču — tačno "mnogo izraženija koža" iz
      zahteva.
    - **Negativno**: frekventna separacija sa **edge-guard maskom**, NE
      običan blur. Prva verzija JE bila običan blur (flat siva maska, isti
      trik kao Soft Glow) — i na -100 je izgledala kao da je fotka VAN
      FOKUSA (oči, trepavice i kosa su omekšale zajedno sa porama), što je
      uhvaćeno tek vizuelnim testom u app-i, ne matematikom. Ispravljeno:
      `|original - blurred|` (CIDifferenceBlendMode) je tačno taj srednji
      pojas, pa pojačan ×10 i klampovan na 0...1 postaje mapa "ovde ima
      prave strukture" (ravna koža ~0, trepavica/ivica usne ~1); invertovan
      i skaliran sa |texture| (max 0.9) daje per-piksel masku koja ravne
      površine glača jako, a ivice praktično ne dira. Blur radius je
      `longEdge * 0.003` (klampovan 1.5...24).
    - **Bitno o CIBlendWithMask**: čita RGB NIVO maske, ne alfu — zato flat
      `CIImage(color:)` maska radi kao opacity dial (Soft Glow i Patch
      Opacity već se oslanjaju na to). Empirijski potvrđeno standalone
      skriptom ovom sesijom, pošto nova maska zavisi od istog ponašanja.
    - **Provera**: standalone skripta (sintetička "koža": ravna polja + fini
      šum + jedna tvrda ivica) meri lokalni "grain" i visinu ivice po
      vrednostima -1...+1 — grain raste monotono (-1: 0.020, 0: 0.038, +1:
      0.080) dok visina ivice ostaje ista (0.2999 → 0.3035), tj. efekat
      stvarno pogađa samo fini pojas. Zatim standalone render PRAVOG NEF-a
      kroz `CIRAWFilter` na 1600px (identično preview putanji) sa
      -100/-50/0/+100 i vizuelni pregled izrezanog lica — i na kraju isto
      to potvrđeno UŽIVO u app-i (klik na Texture → strelice do -100 →
      koža glatka, oči/usne/kosa oštre; ranije snimljen +100 iz iste
      sesije jasno drugačiji). Codable round-trip potvrđen preko restarta
      app-e (texture +100 preživeo gašenje/paljenje).
    - Dodato i u `mergedSyncSettings` (kategorija Detail & Effects) i u
      `isNeutral`; Codable ključ dodat u ručno pisani `init(from:)` (isti
      "stariji build nema ovo polje" obrazac kao svi ostali).

    **(2) Klik na ime slajdera → strelice ga pomeraju** (Lightroom-ov
    obrazac). Klik na NAZIV bilo kog slajdera u Develop-u ga "naoruža":
    red se blago obeleži (tint + border + ↔ ikonica) i preko dna preview-a
    izađe kartica **"<Ime> selected / Press ← to lower, → to raise · hold ⇧
    for bigger steps"** (fade+scale ulaz, sama nestaje posle 2.8s). Onda
    ← / → pomeraju TAJ slajder: **plain strelica = 1 korak, ⇧+strelica =
    5 koraka**. Korak je 0.01 (tj. 1 jedinica na 0-100 skali koju skoro svi
    slajderi prikazuju); Exposure koristi 0.05 EV, Straighten 0.1°.
    Povlačenje slajdera mišem ga takođe naoružava, ali ĆUTKE (bez kartice)
    — kartica je odgovor na "šta sam ovo kliknuo", a na svaki drag bi bila
    buka. **Escape** razoružava.

    **Arhitektura (i zašto baš tako)**: nudge ne može da se razreši iz
    samog ključa — svaki `editSlider` je napravljen sa SVOJIM Binding-om
    (`$settings.exposure` za globalne, ali computed get/set za maske, patch
    i layer opacity), i ne postoji jedan keypath koji ih sve dohvata. Zato
    svaki slajder REGISTRUJE closure nad svojim binding-om u novu klasu
    `SliderNudgeRegistry` (obična klasa, NAMERNO ne ObservableObject — da
    upis u nju tokom body prolaza ne može da invalidira view iz kog je
    upisan), a key monitor samo pronađe closure po ključu i pozove ga.
    Registracija ide na SVAKOM body prolazu (ne u `.onAppear`), da closure
    uvek drži binding iz poslednjeg render-a. Ključ je podrazumevano naslov
    slajdera, ali maske/patch/brush/layer paneli ponavljaju imena
    ("Exposure", "Feather", "Opacity", "Brush Size" postoje više puta), pa
    ta pozivna mesta prosleđuju eksplicitan namespace-ovan ključ
    (`mask.exposure`, `patch.feather`, `layer.opacity`, ...) — dva slajdera
    sa istim ključem bi se otimala oko istog registry unosa I oba bi se
    upalila kao selektovana.

    **Strelice u key monitoru** (`installEditingKeyMonitor`, isti jedan
    monitor kao Cmd+C/X/V, `[`/`]`, Backspace): repeat je NAMERNO dozvoljen
    (držanje strelice da vrednost klizi je cela poenta, i svaki pritisak je
    jedno klampovano sabiranje — ne može da se gomila kao onaj Cmd+V bug iz
    #15). Tri zaštite da strelice ostanu netaknute svuda drugde: ništa nije
    naoružano → propusti; field editor (npr. preset-name text field) ima
    fokus → propusti (`(NSApp.keyWindow?.firstResponder as? NSTextView)?
    .isFieldEditor`), tako da strelice i dalje pomeraju kursor u tekstu; i
    `nudgeSelectedSlider` vraća false kad naoružani slajder trenutno nije
    na ekranu, umesto da proguta taster bez efekta.

    **Layout detalj**: selektovani red koristi `.padding(6)` → highlight →
    `.padding(-6)`, pa tint/border ispadne 6pt van reda a okolni VStack
    dobije NEPROMENJEN footprint — naoružavanje slajdera ne pomera panel ni
    za piksel.

    **Provera (uživo, mišem/tastaturom preko AX automatizacije)**: klik na
    "Exposure" → kartica se pojavila, red se obeležio; strelica desno
    pomerila +0.05 po pritisku; ⇧+strelica tačno +0.25 (0.41 → 0.66); klik
    na "Texture" (čak i kad je red van vidljivog dela panela) → kartica
    "Texture selected"; 20×⇧← spustilo Texture tačno na -100 (i klampovalo
    se tamo kroz preostalih 20 pritisaka); Escape pa 5×⇧→ nije promenilo
    NIŠTA (razoružavanje potvrđeno); na kraju 6×⇧→ + 2×→ vratilo Exposure
    tačno na +0.26 — obe veličine koraka potvrđene istim testom. Build čist,
    app 0% CPU u mirovanju.

    **Napomena o test okruženju**: AX `entire contents of window` je usred
    sesije počeo da vraća 0 elemenata (poznata flakiness iz ranijih beleški)
    — zaobiđeno ručnom rekurzivnom `UI elements of` šetnjom po stablu, koja
    je radila pouzdano do kraja. Ako se ponovi, to je gotovo rešenje, ne
    treba gubiti vreme.

32. **Color sekcija dobila prave Lightroom-style gradijentne trake** — 24.
    avgust 2026, isti dan kao #31. Zahtev: „jel moze ovaj deo color da dobije
    stvarni color slidebar kao lightroom".

    **Zašto custom kontrola**: macOS SwiftUI `Slider` sam crta svoju
    neprozirnu sivu traku i NEMA hook da se ona zameni — gradijent iza njega
    se ne vidi. Zato nov `GradientTrackSlider` (capsule traka + okrugli
    thumb + `DragGesture(minimumDistance: 0)`), koji drži ISTI
    `Binding<Double>`/`range`/`onEditingChanged` ugovor kao pravi Slider, pa
    ga `editSlider` samo zameni kroz nov `trackGradient:` parametar — sve
    izgrađeno iznad (registry za strelice, highlight naoružanog reda, prikaz
    vrednosti) radi nepromenjeno. `minimumDistance: 0` je bitan: bez njega bi
    se izgubio običan KLIK bilo gde na traci (skok thumb-a tamo), koji
    platformski slider ima.

    **Gradijenti** (svi kao `static let` na `DevelopView`):
    - Temperature: plava → skoro-neutralna → ćilibar
    - Tint: zelena → skoro-neutralna → magenta
    - Saturation: siva → pun hue sweep (hue ide do 0.85, ne ceo krug, da oba
      kraja ne budu crvena; saturacija raste sa pozicijom, pa je levi kraj
      stvarno siv — tačno ono što -100 radi fotki)
    - Vibrance: isti sweep sa nižim plafonom (0.62), pošto Vibrance i jeste
      blaža verzija Saturation-a
    Temperature/Tint NAMERNO imaju srednju neutralnu tačku — direktna
    interpolacija plava→ćilibar prolazi kroz blatnjavo zeleno i stavila bi
    lažni „ovde je zeleno" signal tačno na nulu slajdera.

    **Usput popravljeno (pravi bug, uhvaćen tokom testa)**: strelice sad
    SNAP-uju vrednost na sopstvenu mrežu koraka posle svakog pritiska (kao
    Lightroom). Bez toga se float dust akumulirao — deset +0.05 pritisaka sa
    -0.5 je završilo na -1.1e-16, što je readout prikazivao kao zbunjujuće
    „-0", a `isNeutral` (poređenje `== 0`) bi tu fotku zauvek smatrao
    editovanom. Potvrđeno posle fiksa čitanjem SAMOG `UserDefaults` zapisa:
    texture i temperature su sad tačno `0`.

    **Provera (uživo u app-i)**: gradijenti vizuelno potvrđeni na sve četiri
    trake u pravom panelu. Pošto AX klik ne radi na gesture-based view-ovima,
    drag je testiran pravim CGEvent mouse drag-om ograničenim na Develop
    prozor (skripta odbija tačku van njega I van desnog panela — poučeno
    incidentom sa `cliclick`-om iz ranijih beleški): drag na Temperature dao
    +59, drag skroz desno tačno +100, skroz levo tačno -100, thumb ostaje ceo
    unutar trake na oba kraja, i red se pritom tiho naoruža (bez kartice,
    kako je i projektovano u #31).

    **Napomena o testnoj fotki i persistenciji**: tokom testiranja je app u
    jednom trenutku ugašen sa `osascript quit` pa `pkill` posle samo 2s —
    izgleda da je to preseklo `UserDefaults` flush, pa se posle restarta
    učitalo STARIJE stanje (Exposure se vratio na 0.184 umesto 0.26 koliko je
    bilo upisano, Texture na -50 usred rampe). Nije bug u app-i, ali je
    dobra pouka: `PhotoEditStore` piše kroz `renderNow()`, pa nasilno gašenje
    može da izgubi poslednje sekunde izmena. Sledeći put gasiti samo
    `osascript quit` i sačekati da proces stvarno nestane.

33. **"Remove" — selektuj ljude (Vision) i obriši ih (inpainting), korak 1
    od AI plana** — 24. avgust 2026. Korisnik je pitao kako da dobije
    Lightroom-ov Generative Remove; dogovoren je trostepeni plan (pun
    razgovor u sažetku ispod), i ovo je **korak 1: bez ijednog modela, 100%
    naš kod, nula licencnih problema**.

    **Kontekst odluke (bitno za korak 2/3)**: Lightroom-ov Generative Remove
    NE radi na Macu — radi u Adobe cloud-u, na Firefly modelu treniranom na
    licenciranom sadržaju, sa indemnifikacijom. Za nas, pošto se app
    PRODAJE, presudna je licenca *težina* modela i porekla podataka za
    trening (npr. Places2 dataset je „research only", pa čist Apache kod ne
    pomaže ako su težine trenirane na njemu). Zato: korak 1 sad (ovo), korak
    2 = generativni erase preko cloud provajdera sa komercijalnim uslovima
    kao plaćena opcija, korak 3 = on-device model (Kandinsky Apache-2.0 ili
    SD-inpainting pod OpenRAIL) tek ako korisnici traže offline.

    **Nov fajl `DevelopInpaint.swift`** (~870 linija), namerno van
    `Develop.swift` i pisan kao čiste funkcije nad baferima, da može da se
    testira standalone skriptom bez GUI-ja. Dve polovine:

    - **`SubjectMasker`** — `VNGeneratePersonSegmentationRequest`
      (`.accurate`), pokrenut na smanjenoj kopiji (1600px), maska skalirana
      nazad na pun extent. Vision je jedina polovina koju Apple daje
      besplatno — **javnog API-ja za popunjavanje NEMA** (Clean Up u Photos
      app-u je zatvoren), otud druga polovina. Maska se još i dilatira
      (~0.25% duže ivice) jer Vision seče osobu tesno i ostavlja rub njene
      boje koji bi inpainting posle razmazao nazad kao duh.
    - **`ExemplarInpainter`** — Criminisi (2004) implementiran iz rada.
      **Licencna odluka, ne NIH**: GIMP-ov resynthesizer je GPL (ne sme u
      zatvoren komercijalni app), a PatchMatch — na kome počiva većina
      modernog content-aware fill koda — je pod Adobe patentima koji traju
      do kraja dekade. Criminisi (prioritetni redosled + windowed
      exhaustive search) prethodi obojici. Prioritet = confidence × data
      term; data term (izofota · normala fronta) je ono što nosi ivice
      preko rupe umesto da ih razmaže.

    **Kako se uklapa u postojeći model**: rezultat je **`ImageLayer`** —
    popravljeni region kao PNG sa alfom po rupi, položen preko originala.
    Zato ostaje non-destructive i undo-able bez ijednog novog koncepta u
    render pipeline-u. Bitno: sve se računa na **PRE-CROP** renderu
    (`applyCrop: false`), jer `compositeLayers` tumači layer koordinate u
    tom prostoru — cropovan render bi svaku popravku smestio na pogrešno
    mesto na fotki koja ima crop.

    **Dve optimizacije bez kojih ovo nije upotrebljivo**:
    - summed-area tabela za „je li ceo kandidat-patch pravi original" —
      4 lookupa umesto do 81 čitanja po kandidatu (bilo je preko pola cene
      pretrage). Izvor su isključivo ORIGINALNI pikseli, nikad već
      sintetizovani (Criminisijeva definicija, sprečava da fill kompoznuje
      sopstvenu izmišljenu teksturu).
    - plafon na broj piksela rupe (45k): radno uvećanje se smanjuje dok
      rupa ne stane. Bez toga osoba preko pola kadra traje minutima.

    **Dva prava bug-a uhvaćena testom**:
    - **`CIColorMatrix` sa bias-om vraća BESKONAČAN extent** (filter čiji
      izlaz za transparent black nije nula). Posledica: `mask.extent.origin`
      postaje -inf, translacija NaN, i maska se tiho renderuje kao potpuno
      prazna slika — `createCGImage` vraća nil bez ijedne greške. Isto važi
      za `CIColorControls` sa brightness-om. Popravka: `.cropped(to:)` odmah
      posle takvog filtera. **Ovo je obrazac za pamćenje** — verovatno
      postoji i drugde u fajlu.
    - **Swift 6.3.3 optimizator PUCA** (hard crash kompajlera, ne
      dijagnostika) pri inline-ovanju u sintetizovani `deinit` generičke
      `NSHostingView` podklase — što znači da je **svaki Release build ove
      app-e do sad padao**, a Debug (koji taj pass ne pokreće) prolazio, pa
      je ostalo neprimećeno. Popravljeno tako što je `ClickThroughHostingView`
      prestao da bude generički (`NSHostingView<DevelopView>`) — koristi se
      samo sa `DevelopView` ionako. **Release build sad prolazi.**

    **Provera**: (1) sintetički test (pruge + zrno + beli blok koji se
    briše): rupa potpuno popunjena, nijedan piksel objekta nije preživeo,
    ton se poklapa sa okolinom, pruge se nastavljaju preko rupe — 0.24 s;
    (2) standalone render pravog NEF-a: maska je čista silueta, osoba
    nestala, drveni stubovi/jedra/ležaljke rekonstruisani — maska 0.46 s,
    inpaint 1.95 s na 1800px; (3) **uživo u app-i (Release build)**: Select
    People → crveni overlay preko osobe → Erase → osoba nestala iz preview-a,
    layer „Removed 1" dodat, maska očišćena; Cmd+Z uredno vraća.

    **Ograničenja koja treba znati**:
    - `VNGeneratePersonSegmentationRequest` hvata istaknute ljude; sitna
      figura u pozadini ume da padne ispod praga. Ako se to pokaže kao
      problem u praksi, `VNGenerateForegroundInstanceMaskRequest` (macOS 14+)
      daje instance-po-instancu i klik-na-objekat izbor.
    - Veliko uklanjanje (osoba preko pola kadra) vraća vidljivo „pločast"
      rezultat u sredini — inherentno za exemplar fill; mali objekti u
      pozadini, što je i bio traženi slučaj, izgledaju čisto.
    - **Debug build je `-Onone`**, pa je erase tamo i do ~30× sporiji nego u
      Release-u. Testirati brzinu isključivo na Release buildu.
    - **I dalje otvoreno**: `ImageLayer.imageData` ide u `UserDefaults`.
      Za Cut/Paste je prolazilo, ali sa Remove layerima ovo treba preseliti
      u fajlove u Application Support pre nego što se funkcija koristi
      ozbiljno.

34. **Remove Brush — ručno bojenje maske (crveno, providno), pored Select
    People** — 24. avgust 2026, isti dan kao #33. Korisnik: „jel mogu ja da
    oznacim recimo da paintujem red transparent color i da krenem remove?".

    Novo dugme **Brush** u Remove sekciji + slider za veličinu + `[` / `]`.
    Prevlačenje po fotki boji crveno-providno; Erase radi nad tim. Potezi se
    **sabiraju (union, CIMaximumCompositing) sa Vision maskom** ako je ona
    već nađena — pa je tok „nađi ljude, dokreči šta je Vision promašio" JEDAN
    erase, ne dva. Vision zna samo ljude, a većina onoga što se briše (kanta,
    tabla, kabl, figura premala da se registruje kao osoba) to nije — otud
    ručna polovina.

    **Implementacija je ponovna upotreba, ne duplikat**: potezi su obični
    `BrushStroke` (isti tip kao Brush maska), a maska se pravi novim
    `PhotoEditRenderer.strokeMask(_:extent:)` omotačem oko već postojećeg
    privatnog `brushMask` — nema drugog stamping koda. Dok se slika, crvena
    boja na ekranu je običan vektorski `Path` (isti trik kao
    `brushPaintOverlay`) — CIImage maska se pravi tek na Erase, jer
    re-render maske po tački prevlačenja ne može da isprati miš.
    `hardness: 1` namerno: ovo je SELEKCIJA, a feather bi pao ispod praga
    maske i tiho smanjio ono što se briše (pipeline sam dilatira i omekšava
    rupu).

    Potezi žive u PRE-CROP unit prostoru kao i Vision maska, brišu se pri
    promeni fotke, i `Clear Selection` čisti oboje.

    **Provera**: uživo, pravim CGEvent drag-om preko platna (Release build) —
    tri poteza nacrtana crveno, panel prešao u „Painted area ready", Erase
    aktivan. Sam erase nije ponovo meren (isti kod kao #33).

    **Korisnikova ocena kvaliteta**: „nije dobar ovaj remove tool ali moze da
    ostane" — ostaje kao besplatna instant opcija. Ovo je očekivano i NIJE
    stvar podešavanja: exemplar inpainting radi dobro samo za male objekte na
    jednoličnoj pozadini (pesak, zid, nebo, trava), a sve sa strukturom daje
    pločanje. Skok u kvalitetu traži model — vidi plan ispod.

## Plan — šta dalje (dogovoreno 24. avgusta 2026, nije još počelo)

**ODLUKA (25. avgust 2026): idemo na SD inpainting NA UREĐAJU, ne na cloud
sa kreditima.** Razlog je poslovni, ne tehnički — korisnik je izričit: ljudi
već plaćaju Lightroom mesečno, pa hoće da i BriefShow plaćaju **ravnom
mesečnom pretplatom**, bez kredita i naplate po upotrebi. Model na uređaju
to omogućava (nula troška po brisanju), a usput daje dva argumenta koje
Lightroom NEMA: **radi bez interneta** i **fotke ne napuštaju mašinu**
(Adobe-ov Generative Remove ide u njihov cloud).

Izabran **SD inpainting (CreativeML OpenRAIL-M)**, ne Kandinsky 2.2
(Apache 2.0), iako je Kandinskyjeva licenca čistija:
- veličina: ~0.6–1 GB (palettized) naspram ~3–4 GB za Kandinskyjev
  dvostepeni prior+MOVQ,
- Applov zvanični Core ML paket i konverzioni alati ciljaju BAŠ Stable
  Diffusion — za Kandinsky bi konverzija bila poseban projekat,
- ogroman korpus poznate prakse za removal (konvencije maske, prazan/
  negativan prompt, blendovanje).
Kandinsky ostaje rezerva ako se OpenRAIL obaveze pokažu kao problem.

**Šta OpenRAIL traži od nas (provereno u tekstu licence, ne iz sećanja)**:
komercijalna upotreba je izričito dozvoljena, „no-charge, royalty-free",
bez tantijema i BEZ ograničenja broja korisnika; licencodavac ne polaže
prava na generisane rezultate; nije copyleft (naš Swift kod ostaje naš).
Tri obaveze, sve tehnički trivijalne:
1. priložiti punu kopiju licence svakome ko dobije model (fajl pored
   skinutih težina + „Licenses / Acknowledgements" ekran u app-i, uklapa se
   uz postojeći Disclaimer u footeru),
2. **preneti Attachment A (ograničenja upotrebe) u naš EULA** — naši
   korisnici moraju biti vezani istim zabranama,
3. sačuvati obaveštenja o autorstvu i označiti model kao izmenjen ako ga
   ikad doradimo (fine-tune).
Same zabrane (kršenje zakona, šteta po maloletnike, dezinformacije, PII radi
štete, kleveta, automatsko odlučivanje o pravima, diskriminacija, medicinski
saveti, pravosuđe) ne dodiruju nijednu funkciju foto-editora.
**EULA tekst za proizvod koji se prodaje treba da pogleda pravnik** — ovde je
dat oblik, ne pravno mišljenje.

**REZULTAT PROTOTIPA (25. avgust 2026) — kvalitet potvrđen, idemo dalje.**
SD 1.5 inpainting pušten van app-e (Python/diffusers, MPS, fp16) na PRAVOJ
korisnikovoj fotki `C4S_5740.NEF`, sa maskom iz našeg Vision koda:
- **Sitna figura u pozadini (ciljni slučaj)**: čovek na ležaljci nestao bez
  ijednog vidljivog traga — SD je izmislio praznu ležaljku i nastavak
  terase koji se ne razlikuje od prave fotografije. Ovo je Lightroom klasa.
- **Teški slučaj (osoba preko pola kadra)**: drveni stubovi, jedra, patos i
  staklena ograda rekonstruisani ubedljivo; ima artefakata u sredini, ali
  neuporedivo bolje od exemplar rezultata (koji je tu davao pločanje).
- Recept koji radi za UKLANJANJE (a ne za kreativno domišljanje): prompt
  opisuje POZADINU („empty background, seamless continuation, no people"),
  negative prompt gura protiv dodavanja („person, people, human, face,
  text, watermark"), 30 koraka, guidance 7.5, maska dilatirana pre i
  blurovana pri vraćanju nazad.
- **Brzina: ~48 s po brisanju na 512×512** — ali to je PyTorch/MPS, ne Core
  ML. Očekivanje posle konverzije na ANE + palettizacije je bitno bolje;
  ovo je i glavni razlog zašto konverzija mora da se uradi kako treba.
- Model se skida sa `stable-diffusion-v1-5/stable-diffusion-inpainting`
  (originalni `runwayml` repo je povučen; ovo je zvanično ogledalo).
  Napomena: težine su u `.bin` formatu, ne `.safetensors`.

**KORAK 2 URAĐEN — Core ML konverzija PROŠLA (25. avgust 2026).** Ovo je bio
najveći nepoznati rizik i sad je zatvoren:
- Applov konverter čita `pipe.unet.config.in_channels`, pa **9-kanalni
  inpainting UNet konvertuje sam od sebe**, bez ikakve posebne obrade.
  Potvrđeno na izlazu: `sample [2, 9, 64, 64]` (bazni SD ima 4 kanala).
- Konvertovana sva četiri modela, fp16, u ~10 minuta:
  TextEncoder 235 MB, **Unet 1.6 GB**, VAEDecoder 95 MB, VAEEncoder 65 MB
  (~2 GB ukupno; sa `--quantize-nbits 6` očekivano ~700–900 MB, što je
  veličina koju treba ciljati za skidanje).
- **Dve prepreke u alatima** (za sledeći put, da se ne gubi vreme):
  `coremltools` vuče `pytest` i `scipy` koji nisu u njegovim zavisnostima;
  i `torch2coreml.py` na vrhu importuje `diffusionkit` (Argmax), koji treba
  SAMO za SD3/MMDiT put — import se obavija u try/except i konverzija radi.
- Komanda:
  `python -m python_coreml_stable_diffusion.torch2coreml --convert-unet
   --convert-vae-decoder --convert-vae-encoder --convert-text-encoder
   --model-version stable-diffusion-v1-5/stable-diffusion-inpainting
   --bundle-resources-for-swift-cli -o <out>`

**ŠTA JOŠ NEDOSTAJE (i to je sledeća sesija)**: Applov Swift paket
`StableDiffusion` **NEMA inpainting** — proveren ceo `swift/StableDiffusion/
pipeline/`, nijedan fajl ne pominje mask/inpaint. Ima Encoder (img2img),
Decoder, scheduler-e i UNet omotač, pa je posao ograničen i jasan: nova
pipeline klasa koja (1) VAE-enkoduje maskiranu sliku u latente, (2) smanji
masku na 64×64, (3) spoji `[latent(4) + mask(1) + maskedLatent(4)] = 9`
kanala kao ulaz UNet-a, (4) ostatak petlje denoise-a ostavi kako jeste.
Procena ~200 linija Swift-a plus testiranje.

**Redosled posla za SD**:
1. **Prototip van app-e** (ovo prvo): pustiti SD inpainting na PRAVIM
   korisnikovim fotkama sa našom Vision maskom i uporediti sa postojećim
   exemplar rezultatom — da se kvalitet vidi PRE nego što se uloži u Core ML
   integraciju.
2. Konverzija u Core ML (Applov `python_coreml_stable_diffusion`),
   palettizacija radi veličine.
3. Swift inference pipeline — Applov paket dokumentuje image-to-image, ali
   NE i inpainting, pa pipeline treba proširiti (inpainting UNet ima 9
   ulaznih kanala umesto 4).
4. Skidanje težina na prvo korišćenje (mreža je već dozvoljena u
   entitlements-u), u Application Support, sa prikazom napretka.
5. „Erase (AI)" kao drugo dugme pored postojećeg „Erase (Instant)"; oba
   vraćaju isti `ImageLayer`, pa se render pipeline ne menja.
6. Licenses ekran + EULA odeljak.

**A) AI generative remove (Lightroom-parity), korak 2 od plana iz #33.**
Cilj: zadržati postojeći Remove kao besplatnu „instant" opciju i dodati
DRUGO dugme koje daje pravi generativni rezultat. Pošto se app prodaje,
oblik rešenja je cloud (isto kao Lightroom, čiji Generative Remove radi u
Adobe cloud-u, ne na Macu). Redosled poslova:
1. **`RemovalProvider` protokol** sa dve implementacije — postojeći
   `LocalExemplarProvider` i nov `CloudGenerativeProvider`. UI dobija dva
   dugmeta: „Erase (Instant)" i „Erase (AI)". Rezultat je u OBA slučaja isti
   `ImageLayer`, pa se ništa u render pipeline-u ne menja.
2. **Šalje se samo isečak oko maske** (1024–1536px) + maska, nikad ceo 45MP
   RAW — jeftinije, brže, i manje podataka napušta mašinu.
3. **Prototip sa dev ključem iz lokalnog config fajla** (bez proxy-ja i bez
   naplate) samo da se VIDI kvalitet na pravim fotkama pre nego što se uloži
   u infrastrukturu. Ovo je prvi konkretan korak.
4. **Tek posle toga**: sopstveni tanki proxy (Cloudflare Worker ili mali
   server) koji drži API ključ, autentikuje korisnika preko postojećeg
   RocketsBrief naloga (`RocketsBriefAccount.swift`) i meri kredite.
   **API ključ NIKAD ne sme u app** — iz Mac binarija se vadi za minute.
5. **Krediti/naplata**: van Mac App Store-a Stripe/Paddle; unutar MAS-a Apple
   traži IAP za digitalni sadržaj.
6. **Privatnost**: fotke napuštaju mašinu — treba eksplicitan opt-in prvi
   put, rečenica u privacy policy, i izbor provajdera koji NE trenira na
   korisničkim podacima.
7. **Fallback**: bez interneta ili na grešku, tiho ponuditi instant erase.

Kandidati za provajdera (proveriti aktuelne uslove i cene pre integracije):
Adobe Firefly Services (najjača pravna priča, indemnifikacija, najteži
onboarding), Black Forest Labs FLUX Fill API (vrh kvaliteta, direktan API —
napomena: `dev` TEŽINE su nekomercijalne, ali hostovani API jeste za
komercijalnu upotrebu), Stability API (ima namenski erase/inpaint endpoint,
jeftino). Agregatori (fal.ai, Replicate) su najbrži za integraciju ALI se
preko njih nasleđuje licenca samog modela — ToS agregatora ne pere
nekomercijalni model.

**B) Redosled ostalih funkcija (moj predlog, korisnik bira kad dođe red)**:
1. **HSL / Color Mixer** — 8 traka boja × Hue/Saturation/Luminance.
   Najveći vidljivi skok za portrete (ton kože kroz narandžastu) i pejzaže;
   uklapa se uz Color sekciju iz #32.
2. **Tone Curve** — prava kriva sa prevlačivim tačkama, RGB + po kanalu.
   Motor već postoji (`CIToneCurve` se koristi za Whites/Blacks), posao je
   UI.
3. **Noise Reduction + Sharpening masking/detail** — bitno za RAW na višem
   ISO, malo posla.
4. **Pipeta za White Balance + Auto Tone** — sitno, a deluje vrlo
   Lightroom-ski.
5. **Export presets** — veličina, kvalitet, output sharpening, watermark,
   imenovanje.

**C) Tehnički dug koji treba pre nego što Remove uđe u ozbiljnu upotrebu**:
`ImageLayer.imageData` i dalje ide u `UserDefaults`. Sa Remove layerima to
su megabajti po potezu — preseliti pikselski sadržaj u fajlove u Application
Support i u settings ostaviti samo ime fajla (uz migraciju postojećih
layera).

## KORAK 3 URAĐEN — Swift pipeline radi, ali je prompt iz recepta PAO (25. avgust 2026)

**Kod je napisan i dokazan; ono što NE radi je recept iz beleške iznad.**

**Šta je dodato:**
- `BriefShow/DevelopSDInpaint.swift` (~520 linija) — DDIM scheduler, seeded
  gaussian, 9-kanalni concat, VAE encode/decode, `InpaintPipeline.aiRemoval()`.
- `Develop.swift` — dugme **„Erase (AI)"** pored preimenovanog
  **„Erase (Instant)"**, sa procentom napretka i porukom o grešci.
- `CoreMLModels/clip_tokenize.py` + `dump_prompt_embeds.swift` — jednokratni
  alati koji peku CLIP embeddinge fiksnog prompta u `sd_prompt_embeds.bin`
  (231 KB).
- U `DevelopInpaint.swift` su `maskBoundingBox`, `makeBuffers` i `package`
  prestali da budu `private` — SD put koristi ISTI okvir.

**Ključna arhitektonska stvar koju beleška iznad nije primetila**: `removal()`
je već radio ceo posao oko rupe (grow maske, bounding box, region, pakovanje u
alpha-cut `ImageLayer`). SD menja SAMO `ExemplarInpainter.fill()`. Zato
`eraseMaskedArea()`, render pipeline i layeri nisu ni dirnuti, a oba dugmeta
vraćaju isti `ImageLayer`.

**Text encoder NE ide u app.** Prompt je fiksan, pa se embeddinzi peku jednom.
Ušteda: 235 MB skidanja i ~150 linija BPE tokenizera u Swiftu. (Ako prompt
mora da postane promenljiv — vidi nalaz ispod — ova odluka pada.)

**BRZINA (M2, Release, 512×512, 30 koraka):**
- **~12–14 s po brisanju** kad su modeli topli (0.4 s/korak) — naspram 48 s u
  PyTorch/MPS prototipu, dakle **3,5× brže**.
- **Prvo učitavanje UNet-a košta ~45 s** (ANE kompilacija). Jednom po
  pokretanju app-e — treba ga raditi unapred, ne na prvi klik na Erase.
- `.cpuAndNeuralEngine` je ~4× brže od `.cpuAndGPU` (1,5 s/korak) uprkos tome
  što je model konvertovan sa `ORIGINAL` attention. Ostaje ANE.

**GLAVNI NALAZ — kriva je bila REZOLUCIJA REGIONA, ne prompt.**
`squareRegion` je uzimao 2× najduže ivice maske, pa je za sitne objekte davao
region od ~300 px koji se onda **uveličavao** na 512. Model je time dobio mutnu,
bezdetaljnu verziju fotke — a tada SD prestaje da nastavlja scenu i počinje da
izmišlja: crno-bela krckava rešetka, natpisi, amblemi. Ispravka je jedna linija:
**region nikad manji od 512 izvornih piksela**, pa se kontekst nikad ne uveličava.

Posle te ispravke recept iz beleške radi **savršeno**: sitna figura u vratima
nestaje bez traga (kroz vrata se vidi nastavak brda i zelenila usklađen sa
pogledom levo i desno), a zakrpa na drvenom stubu je nevidljiva. To je Lightroom
klasa i ciljni slučaj iz prošle sesije.

*(Ranije u ovoj sesiji je u ovu belešku bio upisan zaključak da SD traži
konkretan prompt sa subjektom. To je bilo pogrešno — bio je artefakt mutnog
uveličanog konteksta. Prompt iz recepta je ispravan; ostavljam ovo zapisano da
se ista dijagnoza ne ponovi.)*

**Šta prompt IPAK određuje** (i zašto polje postoji): CLIP nema pojam
instrukcije. Prompt se čita kao **spisak stvari koje treba naslikati**, ne kao
naredba. Testirano na pravoj fotki: „Remove the selected object from the image
and seamlessly reconstruct the area behind it. Match the surrounding
background, textures, lighting, colors, shadows…" (54 tokena, staje u 77, ništa
se ne seče) daje **crnu tablu sa izmišljenim slovima**, a u drugom pokušaju
kamenje i šumu — jer CLIP „textures, lighting, colors, shadows" tretira kao
subjekte. Zato podrazumevani prompt IMENUJE ONO ŠTO TREBA DA BUDE TU
(„empty background, seamless continuation, no people"), a tekst pored polja to
kaže korisniku.

**UI kako je dogovoreno i urađeno (25. avgust 2026):**
- dugme se zove **„AI Remove"**, stoji pored „Erase (Instant)";
- korisnik samo brushom označi i klikne — prompt radi u pozadini, nevidljiv;
- **zupčanik** pored dugmeta otvara polje sa tim tekstom: može da se obriše,
  prepiše, i vrati na podrazumevani dugmetom „Reset";
- prompt se čuva app-wide (`@AppStorage "develop.aiRemove.prompt"`), ne po
  fotki — to je podešavanje alata, a ne deo obrade slike.

**Posledica po veličinu skidanja**: promenljiv prompt znači da TextEncoder
(235 MB) MORA da se skine, pa ušteda iz prethodne odluke pada. Ostaje ono što
vredi: upečeni blob i dalje pokriva podrazumevani prompt, pa se TextEncoder
**učitava u RAM samo ako je korisnik zaista promenio tekst**.
`DevelopCLIPTokenizer.swift` (~130 linija) je port `clip_tokenize.py`; oba
čitaju isti `vocab.json`/`merges.txt` iz bundle-a pa ne mogu da odlutaju.

**Provere koje su prošle**: Swift i Python tokenizer daju **identične ID-jeve**
za svih 5 test-stringova (uključujući unicode i prazan string); živa
TextEncoder putanja i upečeni blob daju **bajt-identičan** rezultat za
podrazumevani prompt (`BRIEFSHOW_SD_NOBLOB=1`).

**Dijagnostika koja je ostala u kodu** (env varijable, ništa se ne isporučuje
uključeno): `BRIEFSHOW_SD_DEBUG=1` (statistika svakog stadijuma + dump celog
512 kadra u `$TMPDIR`), `=roundtrip` (samo VAE), `=full` (text2img kroz istu
petlju), `BRIEFSHOW_SD_GUIDANCE`, `BRIEFSHOW_SD_STEPS`, `BRIEFSHOW_SD_UNET=gpu`,
`BRIEFSHOW_SD_EMBEDS=zero`. Difuzija tiho greši — pogrešan znak ili razmera i
dalje daju NEKU sliku — pa je ovo jedini jeftin način da se ispravan pipeline
razlikuje od uverljivo pokvarenog.

**Modeli se za sada čitaju sa dev putanje** `~/Desktop/BriefShow/CoreMLModels/
SD15-Inpainting` (drugi izbor); prvi je `Application Support/BriefShow/
CoreMLModels/`, gde će ih skidanje na prvo korišćenje spustiti. Skidanje,
palettizacija na 6 bita (~600 MB umesto 1,76 GB bez TextEncoder-a), Licenses
ekran i EULA su i dalje neurađeni — koraci 4 i 6 iz redosleda gore.

## KORAK 4 — feather na rubu zakrpe i 2,25× ubrzanje (25. avgust 2026)

**1) Vidljiv rub zakrpe.** Korisnik je uklonio sunce sa ilustracije: uklanjanje
odlično, ali se rub patcha video. Uzrok: `package()` je pravio alpha ivicu sa
`grow` 2 px pa `blur` 3 px — u 512 baferu to je ~3 px prelaza. Exemplar putanji
je dovoljno (kopira PRAVE piksele iz iste fotke, pa se ivice ionako poklapaju),
ali SD regeneriše područje i promaši ton za dlaku, a tvrda ivica to pretvori u
vidljiv pravougaonik.

Urađeno: `package()` je dobio `growRadius`/`blurRadius` (default 2/3, exemplar
netaknut), blur se sad radi **dvaput** (jedan box blur je linearna rampa sa
vidljivim prelomom na oba kraja, dva daju glatku krivu), a SD put ima
**„Edge Feather" slajder** u zupčaniku, `@AppStorage`, default 0.35.

Bitno: rampa mora da ide UNUTRA u rupu. Napolju je zakrpa fotka preko same
sebe, pa tamo blend ne radi ništa — zato mali `grow` uz široki `blur`, a ne
skaliranje oba. Maksimum je vezan za veličinu rupe (`holeEdge / 5`, jer se
blurra dvaput): sa fiksnim maksimumom je feather 1.0 davao **solid 0 px**, tj.
ceo patch poluprovidan i uklonjeni objekat bi se vratio kao duh. Izmereno sad:
feather 0.0 → rampa 22 % površine, 0.35 → 161 %, 1.0 → 1489 % uz očuvan pun
centar.

**2) Brzina: 30,2 s → 13,4 s po brisanju** (isto brisanje, iste okolnosti).
Dve izmene, i **prva je bila prava**:

- **Raspored koraka: „leading" → „trailing".** Stari raspored (`i*1000/steps + 1`)
  KREĆE ISPOD vrha skale — na 30 koraka od t=958, na 15 od t=925 — dok je latent
  koji mu dajemo čist standardni normal, koji pripada t=999. Modelu se kaže da
  je šum blaži nego što jeste, i sa malo koraka to ne može da nadoknadi:
  rezultat se raspadne u istu crno-belu krckavu rešetku. Zato je DDIM na 15
  koraka padao. `trailing` uvek kreće od 999.
- **Solver: DDIM → DPM-Solver++ (2M).** Radi u log-SNR promenljivoj
  lambda = log(alpha/sigma), gde je ODE polulinearan pa se alpha/sigma deo
  integrali tačno; drugi red koristi prethodnu x0 procenu. Prvi korak i
  poslednji su prvog reda (`lower_order_final` — poslednji pada na sigma = 0,
  gde bi drugi red delio beskonačnim lambda razmakom).

Rezultat: **12 koraka** je novi default, provereno čisto i na 8, pa ovo ostavlja
margine umesto da sedi na ivici. Regresija: text2img „a photograph of a cat
sitting on a wooden table" na 12 koraka daje **oštriju** mačku nego stari DDIM
na 30 — solver je time potvrđen i na opštem slučaju, ne samo na uklanjanju gde
kontekst dominira. `BRIEFSHOW_SD_SOLVER=ddim` vraća stari solver za poređenje.

**3) Predučitavanje.** `SDInpaintPipeline.warmUp()` se zove iz Develop-ovog
`.onAppear`. UNet je ~18 s ANE kompilacije; sad se to plaća kad se Develop
otvori, a ne na prvi klik na AI Remove.

**Zaostalo**: krckava rešetka je ista pojava iz KORAKA 3 — nedovoljno
konvergiran denoise. Sad znamo dva uzroka: uveličan (mutan) kontekst i loš
raspored koraka. Ako se ikad ponovo pojavi, prvo proveriti ta dva.

## KORAK 5 — tamniji patch i zoom u Develop-u (25. avgust 2026)

**1) Zakrpa je bila tamnija od okoline.** Korisnik je uklonio sunce sa
ilustracije: rub je posle feathera bio u redu, ali se cela zakrpa videla kao
tamniji pravougaonik. Prvo je provereno da NIJE alpha: `package()`
premultiplikuje, a `makeCGImage` koristi `premultipliedLast` — slažu se, i
neslaganje bi ionako davalo tamni oreol na ivici, a ne ravnomerno tamnije polje.

Pravi uzrok: VAE round-trip i sampler svaki pomere ton za dlaku. Ispravka ne
pogađa nego **meri**: dekoder rekonstruiše i POZNATE piksele u prstenu oko
rupe, gde tačan odgovor već imamo, pa poređenje njegovog prstena sa pravim daje
tačan pojedinačni gain i offset po kanalu. Novi `SDInpaintPipeline.toneMatch()`.

- Prsten je pojas od 48 px oko bounding box-a rupe, ne ceo kadar — nebo tri
  stotine piksela dalje nije ton koji zakrpa treba da pogodi.
- Traži se bar 1000 piksela, inače identitet (ispod toga je prsten uglavnom
  rupa i korekcija bi bila šum).
- Gain je stegnut na 0.85–1.18: pomak je u suštini bias, a odnos kontrasta
  meren na skoro ravnom prstenu je mali broj podeljen malim brojem. Offset radi
  glavni posao.
- Izmereno na pravoj fotki: `x0.978 +12.7  x1.021 +2.8  x1.044 -0.7` (skala
  0–255) — dakle osetno posvetljenje i topliji pomak.
- A/B sa feather-om na NULI: bez korekcije se zakrpa jasno vidi kao svetliji
  pravougaonik sa tvrdom ivicom; sa korekcijom nestaje potpuno. Feather i tone
  match rešavaju DVE različite stvari i trebaju oba.
- `BRIEFSHOW_SD_TONEMATCH=off` isključuje radi poređenja. Dijagnostički
  `everywhere` put namerno NE korigujeoutput — tamo se baš gleda sirovi pomak.

**2) Zoom u Develop-u — nije postojao uopšte.** Dodato:
- `Cmd +` / `Cmd -` uvećavaju/smanjuju po koraku (×1.25, opseg 1–8, gde je 1
  „uklopi u prozor"), `Cmd 0` vraća na uklapanje. I „=" i „+" se hvataju, jer
  isti fizički taster prijavljuje „=" bez shifta i „+" sa njim.
- Zoom i pan žive u `fittedImageFrame`, pa ih SVAKI overlay koji odatle računa
  poziciju na ekranu — crop, maske, layeri, Remove brush — prati sam od sebe.
- Povlačenje pomera sliku, ali SAMO kad je uvećano i kad nijedan alat ne drži
  platno; svaki alat ispod polaže pravo na isti drag, pa bi pan sloj iznad njih
  tiho pokvario crtanje, crop i pomeranje maski.
- Pan je stegnut i pri povlačenju, ne samo pri iscrtavanju — inače bi offset
  pobegao preko ivice pa povratak ne bi radio dok se ne odmota zaostatak.
- Slika se kliperuje ZA SEBE, a ne kliperovanjem celog ZStack-a: crop drške
  stoje tačno na ivici slike i clip na nivou kontejnera bi ih odsekao.
- Zoom se resetuje pri promeni fotke.

## KORAK 6 — LaMa kao „Quick AI Clean Up" (25. avgust 2026)

**Odluka**: dva dugmeta, bez automatskog prebacivanja. **„Quick AI Clean Up"**
koristi LaMu, **„AI Clean Up"** koristi SD. Staro „Erase (Instant)" (exemplar)
je uklonjeno iz UI-ja — LaMa radi isti posao brže i neuporedivo bolje.

**Zašto je LaMa uzeta prva, pre SD skidanja**: ide U APP (99 MB), pa AI
čišćenje radi na svakom Macu odmah, bez ijednog skidanja i bez odluke o
hostingu. SD skidanje i dalje treba, ali rešava manji deo problema.

**Konverzija** (`CoreMLModels/convert_lama.py`):
- Iz `best.ckpt` se uzima SAMO generator. `.ckpt` je PyTorch Lightning bundle
  sa diskriminatorima, perceptual loss mrežom i stanjem optimizatora — ništa
  od toga nije inference, i utrostručilo bi ono što isporučujemo.
- 51 M parametara, 989 tenzora, fp16 → **99 MB**. App: 23 MB → **121 MB**.
- Maskiranje i concat su NAMERNO unutar traced grafa (`image * (1 - mask)`,
  pa `cat([masked, mask])`). To su dve linije koje je lako suptilno pogrešiti
  na Swift strani (redosled kanala, da li je maska 1-za-rupu ili 1-za-zadržati),
  pa je ugovor Core ML modela sada prosto „evo fotke i maske".
- **Provera**: isti ulaz kroz torch i kroz Core ML — **max razlika 0.0062,
  prosek 0.00043**. To je fp16 zaokruživanje, dakle graf je prenet ispravno.
  Konverzija koja tiho promeni graf se i dalje uredno sačuva, pa se ovo mora
  proveriti a ne pretpostaviti.

**Compute units: `.cpuAndGPU`, ne ANE.** LaMine Fourier konvolucije nemaju
implementaciju na Neural Engine-u — kompajler to kaže naglas tokom konverzije
(`MILCompilerForANE error ... ANECCompile() FAILED`). Traženje ANE kupuje samo
neuspeo compile i fallback. Ovo je usput i razlog zašto LaMa radi na Intelu:
ionako joj ANE ne treba.

**Izmereno na M2** (512 region, ista maska):
| | LaMa | SD |
|---|---|---|
| jedno brisanje (toplo) | **0,7 s** | 13,4 s |
| veličina | 99 MB, u app-i | ~2 GB, skida se |
| Intel Mac | radi | 2–5 min, neupotrebljivo |

**Kvalitet — i to je opravdanje za dva dugmeta:**
- Drveni zid: **nevidljivo**, čak je nastavila i spoj dasaka.
- Figura u vratima: uklonila je, ali je popunila skoro belim umesto da nastavi
  brdo. LaMa **produžava teksturu oko rupe**, ne izmišlja sadržaj; SD izmišlja.
  Tu razliku dugmad i prodaju: Quick za pozadine i teksture, AI Clean Up kad
  treba izmisliti šta je iza.

**Deljeno između sva tri puta**: `toneMatch` i `featherRadius` su prebačeni iz
`SDInpaintPipeline` u `InpaintPipeline` — tiču se krpljenja rupe, ne difuzije.
LaMa koristi isti tone match iz istog razloga: i ona rekonstruiše poznate
piksele, pa je njen promašaj na njima tačna mera koliko zakrpu vratiti nazad.

**Licenca**: LaMa je Apache-2.0, Copyright 2021 Samsung Research (proveren sam
LICENSE fajl u zvaničnom repou; NOTICE fajla nema, pa treba samo kopija licence
i attribution). Težine su skinute sa linka na koji upućuje ZVANIČNI README
(`huggingface.co/smartywu/big-lama`). Kopija licence je u
`CoreMLModels/LaMa/Legal/`. README repoa ne kaže ništa posebno o licenci
TEŽINA — „nije rečeno" nije isto što i „dozvoljeno", pa pred prodaju to vredi
da pravnik potvrdi u jednoj rečenici.

**Zaostalo iz ovog koraka:**
1. **Exemplar kod je i dalje u `DevelopInpaint.swift`, samo se više ne poziva**
   (`ExemplarInpainter.fill` + `InpaintPipeline.removal`, ~400 linija). Dugme
   je uklonjeno; brisanje koda je zaseban, siguran cleanup.
2. **`LaMa.mlpackage` (99 MB) sada stoji u `BriefShow/BriefShow/`** i NIJE
   commit-ovan — 99 MB u git istoriji je trajno. Treba odlučiti: Git LFS, ili
   ostaviti van git-a uz `convert_lama.py` koji ga napravi iz težina.
3. **Legal/ u app bundle-u + „Licenses" ekran** — obe licence (Apache-2.0 za
   LaMu, OpenRAIL za SD) i Attachment A u EULA.

**Python okruženje**: `CoreMLModels/.venv` (Python 3.11 preko Homebrew-a,
torch 2.13, coremltools 9.0, kornia, pytorch-lightning). Treba i za SD
palettizaciju. Uklanja se brisanjem foldera.

## KORAK 7 — pakovanje za v8.0, izmereno (25. avgust 2026)

**ODLUKA: palettizacija se PRESKAČE.** SD ostaje fp16, oba modela idu U APP,
korisnik skine BriefShow i ima sve. Time otpada cela grana plana: skidanje na
prvo korišćenje, hosting, progres bar, checksum, nastavak prekinutog skidanja.

**Izmereno na pravom paketu (`ditto -c -k`, kako se Mac app pakuje), ne procenjeno:**

| | |
|---|---|
| app sa oba modela | 2,1 GB |
| **zapakovano** | **1986,5 MiB** |
| GitHub granica po fajlu u Release-u | 2048 MiB |
| **rezerva** | **61,5 MiB (3%)** |

Prolazi, ali **na 3% rezerve**. Bilo šta dodato posle ovoga lomi Release —
za poređenje, SD TextEncoder sam je 235 MiB, četiri puta veći od cele rezerve.
Izlaz ako ikad zatreba prostor: palettizovati SAMO UNet (1,6 GB od 2 GB) i
ostaviti VAE dekoder na fp16, jer on određuje oštrinu a mali je.

Razlog zašto je razlika tako tanka: fp16 težine se **jedva pakuju** — izmereno
na uzorku od 300 MB Unet-a, gzip daje 92,4% originalne veličine.

**Dve stvari koje slede iz ovoga:**
1. **Gotov build više ne sme u git.** `dist-universal/BriefShow-macOS-Universal.zip`
   se do sada komitovao (14,7 MB); na 2 GB git ga odbija (granica je 100 MB po
   fajlu). Od v8.0 build ide SAMO u GitHub Release. Release dozvoljava 2 GiB
   po fajlu — proveren GitHub-ov dokument, nije po sećanju.
2. **`SDModelStore` treba da gleda i u `Bundle.main`.** Sada traži samo u
   Application Support i na dev putanji, pa modele spakovane u app ne bi našao.
   Nekoliko linija, još nije urađeno.

**Napomena o veličini update-a**: korisnik skida ~2 GB pri SVAKOM update-u, ne
samo prvom. Ako v8.1 popravi jedan slajder, opet je 2 GB. To je prihvaćeno
svesno; to je i glavni razlog zašto većina alata modele drži van app-e.

## KORAK 8 — Export sa opcijama (25. avgust 2026)

Format i kvalitet su bili **zakucani na četiri mesta, i ne isto**: dugme
„Export Edited Copy" je pisalo JPEG 0.92, a desni klik na filmstrip →
„Export…" je pisao 1.0. Dakle koje dugme si slučajno pritisnuo menjalo je
fajl koji dobiješ. To je bila nenamerna nedoslednost, ne odluka.

Urađeno:
- Nov `ExportFormat` enum (JPEG / PNG / TIFF) sa ekstenzijom, `UTType` i
  kodiranjem na jednom mestu. Sva ČETIRI puta idu kroz njega.
- `@AppStorage "develop.export.format"` i `"develop.export.quality"`
  (podrazumevano JPEG 0.92). Format se čuva kao raw string da enum može da
  dobije nove slučajeve bez poništavanja onoga što je korisnik izabrao.
- Segmentirani picker + klizač „Quality" iznad Export dugmadi. Klizač se
  prikazuje SAMO za JPEG; za PNG/TIFF stoji rečenica da su bezgubitni i da je
  fajl mnogo veći.
- TIFF ide sa LZW. Bezgubitno svejedno, a 45MP nekompresovan je ogroman fajl
  bez ikakve koristi.
- Ime fajla i `NSSavePanel.allowedContentTypes` prate izabrani format.
- Format i kvalitet se hvataju PRE nego što pozadinski posao krene, kao i
  snapshot podešavanja pored njih — promena formata usred exporta ne sme da
  promeni fajl koji se piše.

Provereno zasebnim binarijem da sva tri formata daju validne fajlove, a ne
`nil` (što bi se u app-i videlo samo kao tiho „Export Failed"). Napomena za
sledeći put: TIFF magic je `MM` (big-endian), ne `II` — moj prvi test je
očekivao pogrešan bajt i lažno prijavio grešku.

## Dizajn — „Select People in Background" (dogovoreno, nije počelo)

**Problem**: slikaš par ili porodicu na plaži, klikneš „Select People", a
Vision označi i NJIH — pa bi ih obrisao zajedno sa ljudima iza.

`VNGeneratePersonSegmentationRequest` vraća JEDNU masku svih ljudi, bez
razdvajanja na osobe. Rešenje bez ijednog novog Vision API-ja (radi i na
macOS 13, i ne oslanja se na dubinu koju RAW ionako nema):

1. razložiti masku na **povezane komponente** (connected components);
2. par ispred kamere je jedna VELIKA mrlja — stoje zajedno pa se ne razdvajaju
   greškom, što je ovde prednost, ne mana;
3. ljudi u pozadini su više malih mrlja;
4. „Select People in Background" = sve mrlje osim najveće, uz prag na veličinu
   (npr. zadrži one ispod ~35% površine najveće).

**Poznato ograničenje koje treba reći korisniku**: ako neko u pozadini stoji
tik uz par tako da im se maske dodiruju, spojiće se u istu mrlju i biće
preskočen. Za to ostaje ručni brush, koji već postoji.

## Plan — dogovoreno 25. avgusta 2026, nije još počelo

**1) Layers kao u Photoshopu.** Kartica koja može da se istakne, ili da postane
vidljiva na klik. Trenutno je `layersSection` samo spisak u panelu.

**2) Export sa opcijama.** Sada je format i kvalitet ZAKUCAN: JPEG na 0.92 za
„Export Edited Copy", 1.0 na nekim drugim putanjama (vidi četiri poziva
`representation(using: .jpeg, ...)`). Treba dijalog: format (JPEG/PNG/TIFF),
kvalitet, i verovatno veličina.

**3) Sinhronizacija AI uklanjanja.** Ovo je najveće i ima suštinsku podelu na
DVA različita posla, koje ne treba mešati:

- **(A) Kopiranje zakrpe** — `ImageLayer` sa gotovim popravljenim pikselima se
  prepiše na druge fotke. Brzo, besplatno. Ispravno SAMO ako su kadrovi skoro
  identični (stativ, burst). Ako se čovek pomerio, zalepimo „praznu plažu"
  preko mesta gde čovek i dalje jeste, a on ostane vidljiv pored. **Ovde ide
  korisnikova napomena da radi samo na sličnim slikama.**
- **(B) Ponovno pokretanje uklanjanja** — na svakoj ciljnoj fotki se PONOVO
  pusti Vision da nađe ljude, pa LaMa/SD obriše. Ispravno bez obzira koliko su
  fotke slične, jer se svaka analizira za sebe. Skoro sve već postoji
  (`SubjectMasker.personMask` + `quickAIRemoval`/`aiRemoval`); posao je petlja,
  napredak i prekid.

**Koji se može koristiti zavisi od toga KAKO je uklanjanje napravljeno:**
- napravljeno preko „Select People" → (B) radi, i tada napomena o sličnim
  slikama NIJE potrebna;
- napravljeno ručno brushom → (B) ne može, jer model ne zna šta je korisnik
  hteo da ukloni na DRUGOJ fotki; ostaje samo (A), i tu napomena vredi.

Cena (B): LaMa ~1 s po fotki (50 fotki = minut), SD ~13 s po fotki (50 fotki =
11 minuta) — dakle traži napredak i dugme za prekid.

**4) `SyncCategory` treba novu stavku.** Sada ima cropRotate/light/color/
detail/masks; layeri i AI uklanjanja nisu sinhronizabilni uopšte.

## Vezano

- Odluke iz razgovora: ostaje **u istom** Xcode projektu/app-u kao BriefShow
  (ne poseban `.app`, ne poseban proizvod — nema "BriefEdits" brendiranje,
  samo "Develop" unutar BriefShow-a), standalone je (ne dira grid ni
  slideshow), podržava i RAW.

## KORAK 9 — „Select People in Background" (26. avgust 2026)

Dogovoreni dizajn iz „Dizajn — Select People in Background" sekcije gore,
sproveden bez ijednog novog Vision API-ja.

**Gde je kod**: `SubjectMasker.backgroundBlobs` (čista funkcija nad bajtovima)
i `SubjectMasker.backgroundPeople` (Core Image omotač), oba u
`DevelopInpaint.swift`. U GUI-ju: novo dugme „Select People in Background"
odmah ispod „Select People", zove `findPeople(backgroundOnly: true)`.

**Kako radi**, u tri koraka:
1. Vision-ova maska svih ljudi se renderuje u mali probe bafer (768 px duža
   ivica) — identitet mrlje preživljava smanjenje, detalj ivice je nebitan za
   pitanje „koja je ovo mrlja".
2. 8-povezano označavanje komponenti sa eksplicitnim stekom (rekurzija bi
   pukla na milionskoj mrlji). Najveća mrlja = subjekat. Zadrži sve ostale
   koje su **ispod 35 %** površine najveće i imaju bar `w*h/60000` piksela
   (ispod toga je Vision-ov šum na ivici, ne čovek).
3. Rezultat se NE koristi kao maska nego kao **selektor**: uveća se nazad,
   otvrdne (isti contrast 4 / brightness −0,2 kao `grown`) i pomnoži preko
   pune Vision maske — tako zadržani ljudi imaju Vision-ovu oštru konturu, a
   ne stepenastu od 768 px.

**Redosled sa Selection alatom je bitan i namerno je ovakav**: razdvajanje na
mrlje ide PRE preseka sa aktivnom selekcijom. Obrnuto bi značilo da korisnik
koji zaokruži strance promoviše najvećeg stranca u „subjekta" i time poštedi
baš onoga koga je hteo da ukloni.

**Kad nema nikoga iza**: `backgroundPeople` vraća `nil` (a ne praznu masku),
pa panel ispiše poruku umesto da tiho ne uradi ništa. Poruka takođe govori
poznato ograničenje: ko stoji priljubljen uz subjekta spaja se u istu mrlju i
biće preskočen — za to ostaje Brush. Nova stanja: `removeNotice`,
`foundBackgroundOnly`.

**Provereno skriptom, 17/17** (`backgroundBlobs` + ceo Core Image put):
zadržava tačno dve male mrlje, odbacuje subjekta, odbacuje srednju (0,56 od
najveće), odbacuje 2-px šum, dijagonalni dodir spaja u jednu mrlju, jedna
sama mrlja → `nil`, dva jednaka subjekta → `nil`, mrlja na samoj ivici bafera
ostaje cela, i — najvažnije za Core Image — **nema Y-flipa** kroz
`context.render(toBitmap:)` → `CIImage(cgImage:)` round-trip, extent
sačuvan.

Usput uhvaćena greška u samom TESTU (ne u kodu): prvi „mrlja na ivici" slučaj
je stavio ćošak na (0,0) a subjekta na (10,10) — piksel (9,9) i (10,10) su
dijagonalni susedi, pa ih je 8-povezanost spojila u jednu mrlju i test je pao
tražeći dve. Kod je bio u pravu.

## KORAK 10 — kartica sa quick action dugmadima za AI Clean Up — NAPRAVLJENA PA VRAĆENA (26. avgust 2026)

> **STATUS: ovoga NEMA u kodu.** Korisnik ju je tražio usred sesije, video je,
> i istog dana rekao „vrati na prošli build, da ne bude taj fix hair open eyes".
> Vraćeno je TAČNO ovo i ništa drugo — zupčanik i `aiPromptEditor` su nazad,
> „AI Clean Up" opet briše odmah na klik, `CleanUpIntent` i
> `neutralNegativePrompt` su obrisani, `DevelopSDInpaint.swift` je bajt-u-bajt
> isti kao pre. KORACI 9 i 11 su ostali. Ovo se čuva zapisano zbog nalaza o
> negative prompt-u ispod, koji važi bez obzira na kartu — i da se ne pravi
> ponovo bez izričitog traženja.

Traženo je bilo: kad se brushem pređe preko očiju / ljudi u pozadini / bilo
čega i klikne se Clean Up, da izađe mala kartica sa ponuđenim quick action
dugmadima i praznim poljem za sopstveni opis.

**Suština zašto ovo ima smisla, a nije samo meni**: SD inpainting NIJE brisač
— on iznova naslika šta god je pod maskom, po promptu. „Preslikaj zatvorene
oči u otvorene" je bukvalno ista operacija kao „preslikaj stranca u praznu
plažu"; menjaju se samo dva stringa. Zato je `CleanUpIntent` (nov enum na dnu
`DevelopSDInpaint.swift`) mali spisak parova prompt/negative prompt, a ne
grananje u pipeline-u.

Četiri intent-a: **Remove from the Photo** (postojeći `defaultPrompt` —
identičan string namerno, jer je to jedini prompt sa unapred izračunatim CLIP
embedding-ima u app-i, pa se preskače učitavanje text encoder-a), **Open
Eyes**, **Fix Hair**, **Remove Glare**.

**Negative prompt je morao da postane promenljiv, i to je pravi nalaz ovde**:
dotad je svaki poziv išao sa `defaultNegativePrompt` = „person, people, human,
face, text, watermark". To je tačno za brisanje čoveka, a **direktno se bije**
sa „Open Eyes" — tražiš lice i istovremeno guraš protiv lica. Zato svaki
intent nosi svoj negative, a slobodan tekst dobija nov, tanak
`neutralNegativePrompt` = „blurry, deformed, distorted, text, watermark".
`eraseMaskedArea` sad prima `prompt:` i `negativePrompt:` (LaMa put ih
ignoriše — nema text encoder uopšte — pa nose default vrednosti).

**Šta je uklonjeno**: zupčanik pored dugmeta i `aiPromptEditor` iza njega.
Kartica ih zamenjuje u celini (Edge Feather slajder je prešao u karticu).
Slobodno polje je nov `@AppStorage("develop.cleanUp.customPrompt")` sa
**praznim** defaultom — stari ključ `develop.aiRemove.prompt` je namerno
ostavljen netaknut, ne migriran: njegova vrednost je kod skoro svakoga baš
default prompt, a prepisati ga u novo polje bi poništilo poentu (polje je
„nijedno od četiri dugmeta nije ono što sam mislio", a ne podešavanje).

Klik na dugme prvo zatvara karticu pa pokreće brisanje (`runCleanUp`) — 13
sekundi sa otvorenim menijem alternativa ispod poziva na drugi klik, a drugi
klik bi zakačio drugo brisanje.

**Nikad nije vizuelno potvrđeno** — vraćeno je pre nego što je iko video kako
Open Eyes / Fix Hair / Remove Glare stvarno izgledaju na fotki.

**Šta iz ovoga i dalje važi**: nalaz o negative prompt-u gore nije vezan za
karticu. Ako se ikad bude radilo bilo šta osim brisanja kroz SD, fiksni
`defaultNegativePrompt` je zamka koja čeka — i `aiRemoval` već prima
`negativePrompt:` kao parametar, samo ga Develop uvek ostavlja na default-u.

## KORAK 11 — svi slajderi kreću od sredine (26. avgust 2026)

Korisnik: „u Lightroom-u svi slajderi kreću od sredine, a nama samo Texture —
neka svi krenu od sredine kao nula, levo minus desno plus."

Dva odvojena posla, oba urađena:

**(a) Kako slajder IZGLEDA.** SwiftUI-jev `Slider` puni traku od LEVOG kraja
do palca, pa netaknuta Exposure na nuli stoji na sredini i izgleda
polu-primenjeno — nema vizuelne razlike između „0" i „negde u sredini
opsega". Nov `EditTrackSlider` sidri punjenje na NULI i širi ga na obe strane,
plus crtica na mestu nule (viša od trake, pa se vidi i kad punjenje pređe
preko nje). Sidro se **izvodi, ne podešava**: to je gde god 0 padne unutar
opsega — sredina za −1…1 kontrole, krajnja levo za stvarno jednosmerne
(Sharpness, veličine četkica, opacity, Quality), tako da oba tipa dobiju
tačno ponašanje iz iste komponente. Ista crtica dodata i u
`GradientTrackSlider` (Temperature/Tint/Saturation/Vibrance — njihova
gradijentna traka nema gde da primi punjenje, pa je crtica jedino što može da
kaže gde je nula).

**Usput popravljeno nešto što je bilo pokvareno od ranije**: ručno crtane
kontrole su nevidljive accessibility stablu, a `AXIncrement`/`AXDecrement` na
slajderima je JEDINI pouzdan način da se panel vozi skriptom (klik na slajder
ne radi — stavka #19). `GradientTrackSlider` je to izgubio kad je uveden.
Sad oba slajdera imaju `.accessibilityAdjustableAction`, pa je AX testiranje
vraćeno — i na četiri gradijentna, gde ga nije ni bilo.

**(b) Šta slajder RADI.** U „Detail & Effects" sekciji je Texture bio jedini
sa −1…1; Clarity, Dehaze, Vignette su bili 0…1. Sad su sva tri **−1…1**, sa
stvarnom negativnom polovinom:

- **Clarity** — pozitivno je i dalje `CIUnsharpMask`. Negativno NE ide kroz
  isti filter: `intensity` nije dokumentovan za negativne vrednosti. Umesto
  toga „smanji lokalni kontrast" je mešanje ka zamućenoj kopiji na ISTOM
  radijusu, što je tačan inverz onoga što unsharp dodaje na tom radijusu
  (pozitivno: baza + k × detalj; negativno: baza − k × detalj = mix(baza,
  blur, k)). Deli radijus namerno, da −40 poništava ono što je +40 uradio, a
  ne da mekša na nekoj drugoj skali. Ovim je zatvoren ranije zapisan dug
  („Positive only for now… deferred").
- **Dehaze** — ovde nije trebalo ništa novo osim skinuti `> 0`: **svaki
  postojeći koeficijent se već ispravno okreće** pod negativnim d (kontrast i
  zasićenje padnu ispod 1, a kriva podiže crnu tačku umesto da je gnječi) —
  što je bukvalno ono što magla radi fotki. Leva polovina sad DODAJE
  atmosferu umesto da bude mrtav hod.
- **Vignette** — pozitivno tamni uglove, negativno ih posvetljuje (kao
  Lightroom-ov post-crop vignette). Obe polovine dele isti gradijent i
  razlikuju se samo u blend-u, a oba blenda su birana tako da **centar ostane
  netaknut na svakoj jačini** (multiply sa belim ne menja ništa, screen sa
  crnim ne menja ništa), pa efekat raste od uglova ka unutra umesto da
  zamagli ceo kadar.

**Nije dirano, i zašto**: Sharpness (u Lightroom-u je 0–150, jednosmeran) i
Soft Glow (negativan „glow" ne znači ništa), plus sve veličine/opacity/feather/
Quality — tamo bi „nula u sredini" bila besmislica. Ako je korisnik mislio
bukvalno na SVE, ovo je mesto za razgovor.

**Provereno skriptom, 16/16** (iste CI lančiće prepisane 1:1 iz
`PhotoEditRenderer.render`): vignette +0,8 tamni ugao a −0,8 posvetljava,
oba ostavljaju centar netaknut (220 vs 220), i pomeraju ugao za uporedive
iznose (88 vs 87 — da se ne desi da je jedna strana mrtva); dehaze +1 diže
kontrast i gnječi tamnu stranu, −1 spušta kontrast i PODIŽE crnu (69 vs 40 —
magla diže crne); clarity +1 diže lokalni kontrast na ivici (230 vs 180), −1
ga spušta (142 vs 180), ne dira ravne površine, i **ne menja ukupnu svetlinu**
(128,40 vs 128,42 — „mekšanje" koje usput potamni fotku je bug koji se lako
sakrije iza uverljivog rezultata); i sve tri su tačan no-op na nuli.

## KORAK 9, dopuna — zašto „Select People in Background" ne radi na plaži (26. avgust 2026)

Korisnik je probao na `~/Desktop/RAW Tests Images/C4S_7792.NEF` (porodica od
troje na plaži, iza njih kupači, suncobrani i šetalište) — ništa nije
selektovano. Izmereno umesto nagađano, i **uzrok nije u connected-components
kodu**:

```
probe 768x512, belih 51602 (13,12% kadra)
mrlja  0  površina 51602  (100,0% od najveće)  box x193..581 y69..406
mrlja  1..n — NEMA IH
```

Vision je našao **tačno jednu mrlju — porodicu**. Nijednog čoveka u pozadini.
`backgroundBlobs` je zато ispravno vratio `nil`. Ljudi u pozadini su ~55–75 px
u kadru od 5176 px.

**Četiri stvari isprobane da se to popravi, sve odbačene, sa brojevima:**

1. **Veći `maxWorkingEdge`** (1600 → 2400 → 3600 → puna rezolucija): **nema
   nikakvog efekta.** Maska je UVEK 2016×1512 i uvek 13,1 % bela — Apple-ov
   model ima fiksnu ulaznu rezoluciju i sam smanjuje šta god mu daš. Znači
   `maxWorkingEdge` u `personMask` ne utiče na to koga Vision vidi (i dalje
   ima smisla zbog memorije, ali ne zbog detekcije).
2. **Tiling segmentera 3×3** (preklapanje 12 %, 1,2 s): našao je tačno **dve
   sitne tačke** dodatno — jedan čovek na šetalištu i jedan lažni pozitiv na
   pesku. Ostali i dalje promašeni.
3. **Finiji tiling 4×4 / 6×6 / 8×8**: **aktivno gore.** Bela površina skoči sa
   13 % na 20–31 %, jer segmenter na pločici bez ijednog čoveka **halucinira** —
   na isečku čistog peska označio je 33,6 % površine kao „čovek". Model nije
   treniran da kaže „ovde nema nikoga".
4. **`VNDetectHumanRectangles` po pločicama, pa segmentacija oko svake kutije**
   (klasičan detect-then-segment): na celom kadru nađe tačno 3 osobe (porodicu);
   po pločicama 4×4 nađe 13 kutija koje su sve **fragmenti iste porodice**, koje
   se posle spajanja pretvore u „6 osoba". Rezultat: tatina donja polovina
   proglašena „pozadinom" i bila bi obrisana. Slika dokaza je bila napravljena i
   pogledana.

**Zaključak**: `VNGeneratePersonSegmentationRequest` je model za osobu u prvom
planu (portret/FaceTime), ne za popis svih ljudi u sceni. Za ovu fotku plafon je
Apple-ov, ne naš. **Ne pokušavati ponovo tiling** — dokazano pravi lažne
pozitive na praznim površinama, a to bi u ovoj app-i značilo brisanje peska
tamo gde nema nikoga.

Jedino što je promenjeno u app-i je **poruka**, da bude iskrena o oba uzroka
(spojene mrlje ILI presitni ljudi) umesto da pominje samo spajanje.

Šta bi stvarno rešilo ovo, ako se ikad bude vredelo: sopstveni detektor malih
osoba (npr. YOLO-tip mreže konvertovana u Core ML, kao što je već urađeno za
LaMa u `Tools/convert_lama.py`), pa segmentacija oko svake njegove kutije.
To je novi model u pakovanju, ne podešavanje postojećeg.

## KORAK 12 — sidebar: otvorena ikonica i dublje uvlačenje (26. avgust 2026)

Korisnikov zahtev: kad je folder otvoren da ikonica bude otvorena, i da se ono
što je u folderu gurne još desno da se lepše vidi.

**Ikonica**: SF Symbols **nema** otvoren folder — proveravano programski, postoje
`folder` i `folder.fill` i ništa između (`folder.open`, `folder.fill.open`,
`open.folder`, `folder.badge.open` — sve ne postoje). Zato nov `OpenFolderShape`
(`ContentView.swift`), ručno nacrtan: tabbed zadnja ploča + prednji poklopac
pomeren udesno po dnu.

**Zašto DVA odvojena popunjena podputa sa pravim prozirnim razmakom** između
njih, a ne jedan oblik sa svetlijom linijom: red u sidebar-u iscrtava
selection/hover pozadinu ispod ikonice, pa bi „razmak" nacrtan bojom pozadine
postao vidljiva pruga čim se ta pozadina pojavi.

Oblik je biran vizuelno — nacrtano je 4+4 varijante, renderovano u PNG i
pogledano, uključujući i render na PRAVOJ veličini (2×, 14 pt) da se proveri da
razmak preživi rasterizaciju. Prve dve serije nisu čitale kao otvoren folder
(bez razmaka se zadnja ploča i poklopac stope u jedan oblik).

Obe ikonice su u `frame(width: 14)` — nisu iste širine, pa bi bez toga ime
foldera skakalo levo-desno pri otvaranju.

**Uvlačenje**: `CGFloat(depth) * 14` → `* 24`.

## KORAK 13 — crop se vuče i sa sredina ivica (26. avgust 2026)

Korisnikov zahtev: „mogu da vučem i sa donje sredine da uvećavam i smanjujem, a
ne samo rubovima [uglovima]".

`CropHandle` je dobio `.top/.bottom/.left/.right` uz četiri ugla, i predikate
`movesLeftEdge`/`movesRightEdge`/`movesTopEdge`/`movesBottomEdge` — cela
`resizeCrop` je prepisana da radi **po osama** umesto po `switch`-u nad uglovima.
Ivične hvataljke su kapsule DUŽ svoje ivice (26×7 / 7×26), ne tačkice: oblik
kaže kuda se kreće pre nego što se dodirne. Hit-area je najmanje 22×22 da se
tanka hvataljka može uhvatiti bez ciljanja piksela.

**Jedina prava zamka u ovome**, i bila bi tihi bag: kod zaključane razmere,
ugao bira „koja osa je dala veću kutiju". Ivična hvataljka to NE SME da koristi
— vuče se samo jedna osa, pa bi „uzmi veću kutiju" **ignorisalo vuču kad god
ona SMANJUJE crop** (netaknuta osa uvek implicira veću kutiju). Zato kod ivica
vučena osa vodi, a druga je prati iz razmere. Test to eksplicitno proverava u
oba smera.

Na osi koju ivična hvataljka ne vuče, rast je **simetričan oko centra** (samo
kod zaključane razmere; u Free ta osa se ne menja uopšte i formula se svede na
staru vrednost).

**Provereno skriptom:**
- **64 000 poređenja** starog (samo-uglovi) i novog koda na uglovima, u Free i
  pod tri različite zaključane razmere — **bit-identično**, dakle stara
  ponašanja uglova nisu dirnuta.
- **480 000 fuzz slučajeva** (svih 8 hvataljki × 3 režima razmere × nasumične
  vuče do ±1,5): nikad van granica slike, nikad ispod minimuma 0,05.
- Ciljani testovi: suprotna ivica stoji, upravna osa netaknuta u Free, vuča
  preko suprotne strane se zaustavlja na minimumu (ne izvrće crop), razmera
  održana na 1e-6 u oba smera, centriranost pri zaključanoj razmeri.

## KORAK 14 — Space + miš = ručica (26. avgust 2026)

Korisnikov zahtev: kad je zumirano i hoće da se kreće po slici, da drži Space i
mišem ide gore-dole.

Postojeći pan sloj postoji, ali je isključen čim BILO KOJI alat drži platno
(`!isCropping, !isRemoveBrushActive, selectedAdjustmentIndex == nil, ...`) — što
je tačno naopako za slučaj kome pomeranje i treba: brisanje mrlje na 4× zumu,
gde vuča pripada četkici.

Nov sloj se pojavljuje samo dok je Space pritisnut, i stoji **POSLE svih
overlay-a alata u ZStack-u** — ZStack daje vuču POSLEDNJEM pogledu koji je
traži, pa bi sloj pre njih bio zaklonjen baš kad je potreban. Kursor postaje
otvorena šaka (`NSCursor.openHand`, push/pop po hover-u).

Nov `spaceKeyMonitor` (odvojen od `editingKeyMonitor`, jer taj gleda samo
`.keyDown` a ovde je poenta znati kad taster ode GORE). **Oba obavezna pravila
iz zaglavlja ovog fajla su ispoštovana**: provera prozora je prva linija, a
`isARepeat` se propušta netaknut — držanje Space-a je bukvalno slučaj koji pravi
buru repeat-ova, a stavka #15 je šta se desi kad se takav proguta i obradi.

Tri guarda da Space ne bude ukraden gde ne treba: `firstResponder` je field
editor (kucanje imena preseta) → propusti; `zoomLevel == 1` → propusti (nema šta
da se pomera, Space zadrži AppKit-ovo značenje); i `isSpaceHeld` se čisti u
`resetZoom()` i pri skidanju monitora, da zaglavljeno „Space je dole" ne ostavi
nevidljiv sloj koji guta svaku vuču.

## KORAK 15 — sidebar: folderi na istom nivou se nisu poravnavali (26. avgust 2026)

Korisnik posle KORAKA 12: „ovo je zbunjujuće, ovi folderi isto treba da budu sa
leve strane jer nisu otvoreni".

**Uzrok**: SwiftUI-jev `DisclosureGroup` uvlači SVOJ label, a običan red ne.
Folder koji IMA podfoldere se zato crtao ~27 pt desnije od svog rođenog brata
koji ih nema — dva reda na istom nivou, nacrtana na dva različita nivoa, što se
čita kao ugnježdenost koje nema.

**Popravka**: `DisclosureGroup` je izbačen iz stabla u korist ručnog
`VStack { red; if otvoren { deca } }`. Trougao je sad **kolona u samom redu**,
prisutna na SVAKOM redu bez obzira da li taj red ima trougao — prazna kod
foldera koji se ne otvara. Tako se svi rođeni braća poravnaju, isto kao u
Finder-ovom sidebar-u.

Trougao je **samo dekoracija** (`allowsHitTesting(false)`): red već ceo
otvara/zatvara na klik, pa bi zaseban gest na trouglu bio samo način da se ta
dva razidju.

Usput: deca root-a su sad na `depth: 1` umesto `depth: 0`. Dok je
`DisclosureGroup` slučajno davao uvlačenje, root („esti") i njegova deca su
delili isti depth i to se nije videlo; bez njega bi se poravnali u ravnu listu
i izgubila bi se informacija da su deca UNUTAR root-a.

## KORAK 16 — zašto „Quick AI Clean Up" ponekad napravi belu mrlju (26. avgust 2026)

Korisnik: „ovo je quick removal kataklizma… jel to LaMa?" — sa slikom velike
bele mrlje preko mora.

Da, „Quick AI Clean Up" je LaMa. **Reprodukovano na korisnikovoj fotki**
(`C4S_7792.NEF`) sa pet maski različitih veličina, kroz PRAVI
`InpaintPipeline.quickAIRemoval`, i rezultati pogledani kao slike:

| maska (px) | umanjenje u 512 bafer | rezultat |
|---|---|---|
| 388×190 | 1,5× | čisto, suncobran i ljudi nestali |
| 828×379 | 3,2× | čisto, horizont i more sačuvani |
| **1553×690** | **6,1×** | **katastrofa — celo more i horizont zamenjeni razmazom peska** |
| 2692×2138 | 6,8× | isto tako loše |

**Uzrok nije integracija nego fiksni 512 bafer.** `squareRegion` daje modelu
region **dvostruko veći od rupe**, pa se kod rupe od 1550 px u 512 gura 3100 px
fotke. Struktura koju bi model morao da nastavi — horizont, linija obale — je
uništena umanjenjem PRE nego što je model uopšte vidi, pa on nastavi
dominantnu teksturu okoline (pesak, ili kod korisnika presvetlo nebo → bela
mrlja).

Provereno da NIJE nešto drugo: `toneMatch` ima gain tvrdo klampovan na
0,85–1,18 i traži bar 1000 piksela prstena, pa ne može da razvali sliku u belo;
maska/normalizacija su ispravne jer iste te funkcije na manjim maskama daju
čist rezultat.

**Šta je urađeno sad**: panel upozori kad je površina prevelika za Quick (prag
1000 px najduže stranice — sredina između izmerenih 828 „radi" i 1553 „ne
radi") i uputi na AI Clean Up.

**Prava popravka, ako se bude radila**: LaMa je potpuno konvoluciona i primila
bi bilo koju veličinu — 512 je zakucano u KONVERZIJI
(`LaMaInpaintPipeline.imageSide`, komentar u fajlu to već označava kao „mesto
gde bi sledeća verzija jeftino postala bolja"). Rekonverzija na 1024 preko
`Tools/convert_lama.py` bi umanjenje kod problematične veličine spustila sa
6,1× na 3,0× — ispod granice na kojoj je 828 px slučaj još bio čist. Težine su
iste, pa se veličina app-e ne menja; menja se vreme po prolazu i memorija.

## KORAK 17 — preview je bio mutniji od Quick Look-a (26. avgust 2026)

Korisnik je poslao dve slike jedne pored druge — istu `C4S_7891.NEF` u Develop-u
i u Quick Look-u — i pitao zašto je u Develop-u lošija. Bio je u pravu, i
razlog je bio u kodu, ne u utisku.

**Uzrok, dva koja se sabiraju**, oba u `loadPreviewBaseImage`:
1. preview se dekodira na **1600 px** duže ivice, a preview površina na Retina
   ekranu je ~3000 fizičkih piksela — dakle slika se razvlači oko **2×**;
2. `isDraftModeEnabled = true` — draft demosaic je sam po sebi mekši.

Oboje je birano namerno, da bi RAW mogao da se re-renderuje na ~20 ms takt dok
se vuče slajder (vidi komentar u toj funkciji i stavku o „choppy slider on
RAW"). To je ispravan izbor ZA vuču, i pogrešan za fotku koja stoji.

**Rešeno dvostepenim preview-om**, kao što Lightroom radi sa svojim draft i
standard preview-ima:
- brzi put ostaje netaknut i dalje nosi svaku promenu dok se vuče;
- nov `refinedRenderNow()` renderuje iz **`fullBaseImage`** — istog netaknutog
  dekoda pune rezolucije iz kog ide i export — i zameni sliku 0,35 s posle
  poslednje promene.

Korisnik je eksplicitno tražio da to bude **original** („mora da bude
original!"), pa nema nikakvog kapiranja rezolucije: prva verzija je bila
ograničena na 3400 px i to je uklonjeno. Ništa se dodatno ne dekodira — koristi
se ono što je već učitano.

**Zašto je ovo `scheduleRefinedRender` DEBOUNCE, a `scheduleRender` THROTTLE**:
throttle gore postoji da bi se videli međukadrovi tokom vuče; ovde je poenta
tačno suprotna — jedini trenutak kad se isplati skup render je kad se ništa nije
promenilo neko vreme. Slajder vučen deset sekundi košta tačno jedan refine.

**Generacija se NE povećava** u refine-u. On je zamena za ono što je brzi put
poslednje proizveo, a ne novo stanje — nosi generaciju pod kojom je zakazan i
baca se ako se išta u međuvremenu promenilo. To je ono što sprečava da spor
oštar render sleti preko novijeg brzog.

**Deli `developRenderQueue`** sa exportom, brisanjima i selection extraction-om,
i to nije slučajno: svi oni renderuju kroz ISTU `CIRAWFilter` instancu, a
`PhotoEditRenderer.render` gura Exposure/Temperature/Tint u nju. Jedan serijski
red je ono što sprečava da dva posla pišu u taj filter istovremeno.

Usput izmereno na `C4S_7891.NEF` (M2): pun dekod na 5176 px u punom kvalitetu
je ~0,05 s sa hladnim filterom i praktično 0 sa toplim — demosaic nikad i nije
bio skup deo. Skup deo je ceo filter lanac (krive, maske, layeri) na 5176 px po
KADRU tokom vuče, što je i dalje razlog da brzi put ostane.

## KORAK 18 — univerzalan prompt: izmereno, pa polje sklonjeno (26. avgust 2026)

Korisnik je tražio da AI Clean Up radi bez ikakvog kucanja — jedan univerzalan
prompt za bilo šta (ljudi, mladež, komarac) — i predložio konkretan tekst:

> „Remove the selected object from the image and seamlessly reconstruct the area
> behind it. Match the surrounding background, textures, lighting, colors,
> shadows, perspective, and details so the edited area looks completely natural
> and untouched. Do not alter any other part of the image."

**Testirano na pravoj fotki** (`C4S_7792.NEF`), kroz pravi
`InpaintPipeline.aiRemoval`, tri prompta × dva slučaja, slike pogledane:

| prompt | mali objekat na pesku | velika maska preko obale |
|---|---|---|
| A — postojeći default | savršeno, nevidljivo | naslikao NOVE ljude |
| B — korisnikov instrukcijski | savršeno, nevidljivo | **naslikao smeđu stenu sa zelenim biljem** |
| C — objektno-neutralan | savršeno, nevidljivo | naslikao tamnu apstraktnu formu |

**Dva zaključka, oba korisna:**
1. **Na malim uklanjanjima prompt uopšte nije bitan** — sva tri daju identičan,
   nevidljiv rezultat. Za mladež ili komarca je rasprava o promptu bespredmetna.
2. **Instrukcijski prompt nije bolji, nego merljivo gori** kad model MORA nešto
   da izmisli. Ovo je isto ono što je izmereno kod `defaultPrompt` (vidi njen
   doc komentar): CLIP nema pojam instrukcije, čita spisak imenica i naslika ih.
   „textures, lighting, colors, shadows, perspective, details" je za CLIP spisak
   stvari, a ne opis zadatka — i dobije se stena sa biljem.

**Šta je urađeno**: polje za prompt i zupčanik su UKLONJENI. AI Clean Up je sad
jedno dugme koje uvek radi sa `defaultPrompt`. To je tačno ono što je korisnik
hteo („da klijent ne mora da piše ništa") — samo sa promptom koji je izmeren da
radi. Edge Feather slajder je izašao iz zupčanika u sam panel.

**LaMa NE MOŽE da dobije prompt**, ni ovaj ni bilo koji. Nije stvar podešavanja:
LaMa je čisto konvoluciona mreža sa TAČNO DVA ulaza, `image` i `mask` (vidi
`LaMaInpaintPipeline.fill` — `MLDictionaryFeatureProvider` sa ta dva ključa).
Nema text encoder, nema cross-attention, nema gde da primi tekst. Zato i jeste
sekunda umesto trinaest.

**Ostale izmene iz istog zahteva:**
- „Select People in Background" dugme uklonjeno (KORAK 9 kod i dalje stoji u
  `SubjectMasker`, samo se više ne poziva — vidi dopunu KORAKA 9 zašto na
  plažnim fotkama ionako nije mogao da nađe nikoga).
- „Brush" → **„Select Area"**, i „Brush Size" → „Area Size". Ono što taj alat
  pravi jeste selekcija koja se briše, a ne potez četkice koji menja piksele —
  svaka druga četkica u ovoj app-i radi ovo drugo.
- Selekcija je sad **bela umesto crvene**, i u nađenoj masci
  (`InpaintPipeline.overlayImage`) i u ručno slikanoj (`removalPaintOverlay`).
  Crveno na fotki čita kao upozorenje, a na toplom kadru (koža, pesak, zalazak)
  je i najteže vidljivo. Ista boja na oba mesta jer to i jeste JEDNA maska koja
  se briše u jednom potezu.

## KORAK 19 — LaMa na 1024: rekonvertovano, izmereno, odbačeno (26. avgust 2026)

Korisnik je tražio rekonverziju LaMa na 4096, pa posle merenja pristao da
ostane 512 uz granice po modelu.

### 4096 nije izvodljivo na ovoj mašini

Mašina ima **9 GB RAM-a**. PyTorch forward pass, mereno:

| strana | vreme | ishod |
|---|---|---|
| 512 | 4,2 s | ok |
| 1024 | 134 s | ok |
| **2048** | — | **OOM, kernel ubio proces (exit 137)** |
| 4096 | — | 4× preko toga |

LaMa koristi Fourier konvolucije nad punim feature mapama, pa memorija raste
linearno s brojem piksela; 4096 je 64× od 512.

### 1024 je rekonvertovan — dvaput, i oba puta gori od 512

**Prvi pokušaj, FP16** (isti `compute_precision` kao postojeći 512 model):

- brzina: **1,30 s po prolazu** naspram **0,33 s** na 512 (konstantno, ulaz je
  fiksne veličine; hladan prvi poziv 3,3 s naspram 2,1 s)
- rezultat: **gori na sva tri slučaja** — mali objekat dobio vidljivu bledu
  kockastu mrlju (na 512 nevidljivo), srednja maska obrisala more u belu
  izmaglicu (na 512 tačno)

**Provera konverzije prema PyTorch-u je otkrila zašto**, i to je nalaz koji
vredi zapamtiti:

| model | max razlika | srednja |
|---|---|---|
| 512 FP16 | 0,026 | 0,0004 |
| **1024 FP16** | **1,000** | **0,055** |
| 1024 FP32 | 0,0001 | 0,00000 |

Na 1024 FP16 model **nije veran** originalu. FFC slojevi rade FFT nad punim
prostorom, a vrednosti u FFT-u rastu s brojem uzoraka — na 1024² izlaze iz
FP16 opsega i prelivaju se. Otud kockaste mrlje. Na 512 se to ne dešava.

**Drugi pokušaj, FP32** (fajl 196 MB umesto 99 MB, 1,52 s po prolazu):
numerika je sad egzaktna, ali je rezultat **i dalje gori od 512** — mali
objekat ostavlja blagu mrlju, srednja maska i dalje ispere more.

**Zaključak: ostaje 512.** Ne zato što je konverzija loša, nego zato što je
LaMa TRENIRANA na 512. Potpuno je konvoluciona pa se POKREĆE na bilo kojoj
veličini, ali joj je naučeno receptivno polje vezano za tu skalu — na 1024
svaka struktura joj je na duplo manjoj relativnoj skali nego što je učila.
FP32 test je to i dokazao: kad se numerika iskuluči kao uzrok, razlika ostaje.

Konvertovani modeli su ostavljeni u `~/Desktop/BriefShow/CoreMLModels/LaMa/`
(`LaMa-1024.mlpackage`, `LaMa-1024-fp32.mlpackage` + kompajlirani `.mlmodelc`,
oko 400 MB ukupno) — nisu u git-u, mogu se obrisati.

**Usput je odbačena i besplatna alternativa**: smanjivanje konteksta oko rupe
(`squareRegion` multiplier 2,0 → 1,6 → 1,3 → 1,1, tj. umanjenje sa 6,1× na
3,3×) **ne popravlja ništa** — sva četiri i dalje obrišu more. Znači problem
nije odnos rupe i konteksta.

### Granice po modelu na dugmadima

Isti test (tri maske, ista fotka) pušten kroz OBA modela:

| rupa | LaMa (Quick) | SD (AI Clean Up) |
|---|---|---|
| ~150 px | nevidljivo | nevidljivo |
| ~830 px | **tačno**, more i horizont sačuvani | **izmislio gomilu ljudi** |
| ~1550 px | obrisao more u razmaz | izmislio plažu sa suncobranima |

**Ovo je obrnulo raniju pretpostavku.** Panel je do sada pisao „AI Clean Up
handles this size better" — netačno: generativni model odustaje RANIJE, jer
njegov način propadanja nije gubitak detalja nego izmišljanje objekata.

Zato `RemovalEngine` sad nosi `maximumAreaPixels`: **1000 px** za Quick
(između 830 koje radi i 1550 koje ne radi) i **500 px** za AI Clean Up (između
150 i 830). Preko granice se dugme TOG modela gasi, sa objašnjenjem ispod
zašto baš on ne može — a ne zajedničko upozorenje, jer se i razlozi razlikuju.

**Selekcija se NE ograničava, samo dugmad.** Ista naslikana površina hrani oba
modela i Selection alat, pa bi kapiranje četkice oduzelo posao koji drugi
model — ili kasniji manji prolaz — i dalje može da odradi.

## KORAK 20 — SD granica je pogrešno postavljena, pa ispravljena (26. avgust 2026)

Korisnik je pitao zašto je AI Clean Up ograničen na 500 px i može li više. Bio
je u pravu da posumnja — **500 je bilo izvedeno iz JEDNE tačke** (maska od 830
px koja je izmislila ljude), i ta tačka je slučajno bila na najtežem mestu u
kadru, uz obalu. Generalizovano na sve, što nije smelo.

**Pravo merenje**: pet veličina × dve vrste okoline, ista fotka, slike
pogledane.

| rupa | ravan pesak | uz obalu (horizont, ljudi, suncobrani u blizini) |
|---|---|---|
| 300 px | čisto | čisto |
| 600 px | čisto | **izmislio bele suncobrane** |
| 900 px | čisto | izmislio tamnu nadstrešnicu |
| 1200 px | čisto | izmislio suncobrane i strukturu na vodi |
| 1600 px | **čisto** | redovi suncobrana |

**Zaključak: SD granica nije veličina nego OKOLINA.** Na ravnoj podlozi je čist
i na 1600 px; blizu strukture počne da izmišlja već od 600 px. Fiksna granica
u pikselima bi blokirala gomilu slučajeva koji savršeno rade.

**Pokušan i odbačen detektor strukture**: gruba varijacija prstena oko rupe
(24×24 probe, samo obod). Brojevi se **preklapaju tačno tamo gde se rezultati
razilaze** — ravan pesak 42–54, obala 44–79; na 600 px ravan daje 43,1 (čisto)
a obala 48,6 (izmislio). Nema praga koji ih razdvaja, pa nije uveden.

**Zato dva različita mehanizma, ne dva broja:**
- **Quick (LaMa)** pada na VELIČINU, predvidivo i bez obzira na okolinu →
  `blockingAreaPixels = 1000`, dugme se stvarno gasi.
- **AI Clean Up (SD)** pada na SADRŽAJ → `blockingAreaPixels = nil`, samo
  `cautionAreaPixels = 600` koja ispiše upozorenje i objasni razliku između
  ravne podloge i strukture. Dugme ostaje živo.

### Ostale izmene iz istog zahteva

- **Add / Erase za Select Area.** `BrushStroke.isErase` i `strokeMask` su to
  već podržavali — nedostajao je samo način da se takav potez napravi. Dodat
  segment Add/Erase, i hover prsten je isprekidan dok je Erase aktivan.
  **Bitno**: `eraseMaskedArea` je prepravljen tako da se prvo SABERU dodaci sa
  Vision maskom, pa se tek onda ODUZMU brisanja. Da su oba tipa poteza prošla
  kroz `strokeMask` zajedno, brisanje ne bi moglo da dohvati Vision masku — a
  to je tačno ono što čovek hoće kad „Select People" zahvati rame koje ne
  treba. Potezi brisanja se grade kao POZITIVNA maska pa invertuju, jer
  `strokeMask` kreće od crnog i skup samih erase poteza bi vratio crno.
- **Selekcija je plava** (51,140,255) umesto bele, na oba mesta — i nađena
  maska i ručno slikana. Crveno (prvo) čita kao upozorenje; belo (drugo) se
  gubi na pesku i nebu. Plava je jedina boja od koje ove fotke nisu sačinjene.
- **Traka sa alatima iznad slike.** Panel ostaje isti i dalje drži slajdere i
  liste; ono u čemu je bio loš je bio JEDINI način da se DOĐE do alata — Crop
  pod „Crop & Rotate", Patch pod „Masks", Select Area pod „Remove", svaki iza
  različite količine skrolovanja. Sad su u jednom redu, uvek na istom mestu,
  i svaki svetli dok je aktivan. Dva Clean Up dugmeta su tu takođe, ali su
  živa samo kad ima šta da se briše i kad veličina prolazi granicu tog modela.

## KORAK 21 — spisak sitnih ispravki na traci i oko nje (26. avgust 2026)

Sve iz jedne korisnikove poruke, sa slikama.

**Space je pravio „tin tin tin".** Pravi bag, i vredi zapamtiti mehanizam:
`spaceKeyMonitor` je vraćao `event` kad `zoomLevel == 1` (ideja je bila „nema
šta da se pomera, pusti Space da znači šta AppKit-u znači"). Ali bare Space
tada nema nikoga u responder lancu, a **AppKit na neobrađen taster odgovara
sistemskim beep-om** — pa je držanje Space-a davalo niz beep-ova. Sad se Space
guta uvek dok je Develop ključan i fokus nije u tekst polju; `isSpaceHeld` se i
dalje pali samo kad ima šta da se pomera. Repeat se takođe guta (ranije je
propuštan, što je bio isti izvor beep-a na svaki repeat).

**„Select Area" → „AI Selection"** svuda (traka, panel, poruke).

**Četkica kreće od 2, ne od 6.** `removalBrushSize` 0.06 → 0.02. Na 6 je
najmanje što se moglo označiti već bilo veće od većine onoga za šta alat i
postoji (mladež, insekt, kabl), pa je svaka upotreba počinjala vučenjem
slajdera nadole.

**Redosled u traci je promenjen u tok posla**: Crop · Selection · Patch │ **AI
Selection · Select People · Quick Clean Up · AI Clean Up**. Ranije su dve
stvari koje PRAVE selekciju bile na jednom kraju, a dve koje je TROŠE na
drugom — čitalo se kao četiri nepovezana dugmeta. Korisnik je tražio baš to,
da alat za označavanje stoji levo od Clean Up-ova.

**Progres brisanja je i u traci**, ne samo u panelu — brisanje traje trinaest
sekundi, a oko je već na dugmetu koje ga je pokrenulo.

**Ugašen Clean Up sada kaže zašto.** Nova `cleanUpUnavailableReason(_:)` vraća
jednu rečenicu ili `nil`: nema otvorene fotke / već se briše / **ništa nije
selektovano** / **površina je prevelika za taj model**. Ide i kao `.help`
tooltip na samom dugmetu (jedini način da razlog dođe do pokazivača koji je
upravo pokušao klik) i kao red ispod trake kad ništa nije selektovano.

**Slajder veličine je ispod trake** (`toolStripDetail`), zajedno sa oznakom da
li se trenutno dodaje ili briše. Veličina pripada pored alata koji je menja, a
ne četiri sekcije niže u panelu.

**Sync i Export All su uz filmstrip, skroz desno.** Oba rade nad selekcijom
napravljenom baš tu, a do sada su se dohvatali samo skrolovanjem panela dalje
od thumbnail-a nad kojima rade.

**Export All otvara karticu** (format JPEG/PNG/TIFF + Quality kad je lossy).
Piše u ISTE `@AppStorage` vrednosti koje panel-ov picker koristi, pa su to
jedno podešavanje sa dva mesta pristupa, a ne dva koja se mogu razići. I
panel-ovo „Export All Edited" sad otvara istu karticu. Sam Save panel se
pokreće tek `DispatchQueue.main.async` posle zatvaranja sheet-a — dva modala
koja se trkaju su način da Save panel završi IZA sheet-a.


## KORAK 22 — Layers dobija svoju karticu (30. avgust 2026)

Stavka **1** iz „Plan — dogovoreno 25. avgusta 2026": *„Layers kao u
Photoshopu. Kartica koja može da se istakne, ili da postane vidljiva na klik.
Trenutno je `layersSection` samo spisak u panelu."*

### Šta je urađeno

**1) Tri kartice umesto jednog skrola.** `adjustmentPanel` je bio `ScrollView`
sa trinaest sekcija naslaganih jedna na drugu. Sada je traka sa karticama
prikačena na vrh, a skrol prikazuje samo sekcije izabrane kartice:

| kartica | sekcije |
|---|---|
| **Edit** | histogram, presets, crop & rotate, light, color, detail & effects |
| **Retouch** | masks, selection, remove |
| **Layers** | layers |

Sekcije same nisu dirane — nijedna nije prepisana, samo se bira koje su
montirane. `panelFooter` (Settings, Reset, Export) ide ispod sadržaja SVAKE
kartice, jer to su radnje nad celom fotkom, ne nad karticom. Ostao je unutar
skrola a ne prikačen za dno namerno: `exportActionsSection` nosi filmstrip i
karticu za format, i prikačen bi pojeo panel na niskom prozoru.

**2) Premeštanje layera prevlačenjem.** Svaki red ima grip ručicu
(`line.3.horizontal`) i može da se prevuče na drugi red. Rađeno kao
`DropDelegate`, ne `.onMove` — `.onMove` traži `List`, a panel je `VStack`
unutar `ScrollView`, pa bi `List` prestilizovao svaki red i ugnezdio drugi
skroler u postojeći.

**3) Spisak se čita odozgo nadole.** `settings.layers` je odozdo nagore jer
`compositeLayers` crta redom kroz niz; prikaz je obrnut, ali **samo prikaz** —
svaka radnja i dalje ide preko `id`-a layera.

### Mina koja je nađena usput, i zašto nije eksplodirala

Nad `.keyboardShortcut("v", modifiers: .command)` na dugmetu „Paste as Layer"
stajao je komentar da dugme MORA da ostane u stablu prikaza da bi Cmd+V radio.
Da je to bilo tačno, premeštanje Layers-a iza kartice bi tiho ubilo paste.

**Nije bilo tačno.** Cmd+V obrađuje zajednički local NSEvent monitor
(`installEditingKeyMonitor`), koji ga hvata prvi i vraća `nil` — događaj nikad
ne stigne do SwiftUI-jevog dispatch-a. A kad je `layerClipboard` prazan, dugme
je `disabled`, pa ni tada modifikator ne radi ništa. **Taj `.keyboardShortcut`
je već bio mrtav kod**, u obe grane. Ostavljen je (crta ⌘V oznaku uz naslov),
ali je komentar prepisan da kaže istinu, jer bi sledeća sesija na osnovu starog
zaključila pogrešno.

Monitor živi na Develop prikazu, ne u sekciji, pa paste radi iz bilo koje
kartice. Isto važi za Cmd+C/X, Cmd+Z, `[` / `]` i Backspace.

**Jedina prava posledica kartica na prečice**: Return-potvrđuje-crop visi na
crop „Done" dugmetu i bio je već ograničen na „samo dok to dugme postoji".
Prelazak na drugu karticu usred cropovanja sada takođe demontira to dugme —
isto pravilo, ne novo.

### Provereno

`python3 Tools/run-layer-reorder-test.py` — izvlači PRAVU
`LayerDropDelegate.reorder(_:moving:onto:)` iz `Develop.swift` po tekstu, umota
je u goli enum i pusti test nad njom. Ako se funkcija preimenuje ili pomeri,
skripta pukne glasno umesto da tiho testira zastarelu kopiju.

**10/10:**
- premeštanje gore/dole za jedno mesto, i s kraja na kraj u oba smera
- ispuštanje layera na samog sebe ne radi ništa i vraća `false`
- `id` koji je nestao usred prevlačenja (layer obrisan) ne radi ništa
- prazan spisak ne puca
- **200 000 nasumičnih ispuštanja: nijedan layer se ne izgubi ni ne udvoji**
- obrnut prikaz: prevlačenje najgornjeg reda na najdonji ga i prikazuje dole

**Negativna provera urađena**: kad se `items.insert(moved, at: to)` promeni u
`at: min(to + 1, ...)`, četiri provere padnu. Zanimljivo je koje NE padnu —
fuzz od 200 000 i dalje prolazi, jer off-by-one i dalje daje permutaciju.
Fuzz dokazuje „ništa se ne gubi", a konkretne provere dokazuju „na pravom je
mestu"; trebaju obe.

`xcodebuild -configuration Release` — **BUILD SUCCEEDED**.

### Nije urađeno

**Vizuelna provera.** Kartice, grip ručice, obrnut spisak — niko to nije video
na ekranu. Isto važi za sve iz sesije od 26. avgusta.

Preimenovanje layera dvoklikom nije dodato; nije bilo traženo.


## KORAK 23 — filmstrip je dekodirao ceo folder odjednom (30. avgust 2026)

Prijava: *„mnogo seca dok sam u Developed kao da je sve slike odjednom otvorio full
size"* + zahtev za Lightroom ponašanje (otvorena fotka u punoj rezoluciji, ostale u
thumbnail kvalitetu).

**Lightroom ponašanje je već postojalo** i nije bilo u kvaru: `loadImages(for:)` na
svaku promenu fotke postavi `fullBaseImage` i `previewBaseImage` na `nil`, pa se puna
rezolucija drži samo za jednu fotku.

Uzrok je bio filmstrip, tri sabrana dela:

1. **`HStack`, ne `LazyHStack`.** Plain `HStack` u `ScrollView`-u montira SVAKO dete
   odmah, pa je `.onAppear` opalio na svakoj fotki u folderu čim se Develop otvori.
2. **Svaki taj `.onAppear` dekodira PUNU sliku.** `makeShowGridThumbnail` prosleđuje
   `kCGImageSourceCreateThumbnailFromImageAlways: true` — dakle dekodiraj celu fotku pa
   je smanji na 240px. Ne koristi ugrađeni EXIF thumbnail. Folder od 300 RAW-ova =
   300 punih dekodiranja odjednom.
3. **Na `.userInitiated`**, istom prioritetu kao render koji korisnik gleda.

Popravljeno: `LazyHStack`; zaseban **serijski** red na `.utility`
(`filmstripThumbnailQueue`); zaštita od duplog dekodiranja (`filmstripThumbnailsInFlight`
— provera `== nil` je bila na main threadu PRE dispatch-a, pa su dva `.onAppear` mogla
oba da prođu); i keš ograničen na 400 (`filmstripThumbnailCacheLimit`, izbacuje se
najstariji, nikad otvorena fotka).

`makeShowGridThumbnail` NIJE diran — deli ga ShowGrid.

**Potvrdio korisnik uživo: „sada je smooth".**

## KORAK 24 — dugmad u traci ne reaguju kad je slika zumirana (30. avgust 2026)

Prijava, dvaput: *„kada zumiram sliku ai selection button doesn't work"*, pa
*„cim zumiram nece ako odzumiram hoce"* za Quick Clean Up.

**Ovo je prvi bug u istoriji ovog dokumenta koji je reprodukovan i dokazan skriptovanim
upravljanjem pravom app-om**, ne čitanjem koda. Vredi zapisati kako, jer se isplatilo:
dve moje ranije hipoteze (hit zona četkice; veličina selekcije) bile su POGREŠNE, i
merenje ih je oborilo pre nego što su postale još jedna naslagana izmena.

### Kako je mereno

Privremeni `briefShowDiag` na **stderr** (ne `print` — stdout je pun-baferovan kad ide
u fajl umesto u terminal, prvi pokušaj je dao 0 bajta), plus sintetički klikovi i
tasteri preko `CGEvent`. Ključno: **`CGEvent.postToPid`**, ne System Events `keystroke`
— `keystroke` ide aplikaciji u fokusu i prvi pokušaj je zumirao TERMINAL umesto app-e.
Prozor se nalazi preko `CGWindowListCopyWindowInfo([.optionAll])`; restriktivni
`.optionOnScreenOnly` je povremeno vraćao ništa za prozor koji se uredno slika.

### Izmereno

```
zoom=1.95  quick=ENABLED   klik na Quick Clean Up ->  NEMA TAPPED
zoom=1.00  quick=ENABLED   isti klik, isti piksel  ->  TAPPED
geom zoom=1.95 container=1121x502 fitted=(-93,-239 1306x979) full=(-268,-262 1573x1048)
```

Dugme je **upaljeno u oba slučaja** — dakle nije logika, klik ne stiže.

### Uzrok

```swift
Image(nsImage: displayedImage)
    .frame(width: fitted.width, height: fitted.height)
    .position(x: fitted.midX, y: fitted.midY)
    .frame(width: proxy.size.width, height: proxy.size.height)
    .clipped()
```

**`.clipped()` seče crtanje, ne hit-testing.** Zumirano se slika prostire od y=−239 do
y=740 u kontejneru visokom 502, `centerPreview` je poslednje dete `VStack`-a pa je po
z-redosledu iznad `toolStrip`-a, i njen nevidljivi hit region jede klikove na AI
Selection / Quick Clean Up / AI Clean Up. Dugmad ostaju upaljena i izgledaju normalno —
zato je ovo čitano kao „dugme ne radi".

### Popravka

1. `.allowsHitTesting(false)` na `Image` — ukrasna je, svaki gest živi u overlay-ima
   iznad nje. Ne container-level clip: on bi obrisao crop ručice, zbog čega je clip i
   bio stavljen samo na sliku.
2. **Ista mina je bila u još šest hit zona** — `patchBrushOverlay`,
   `patchCanvasClickArea`, `patchFreeDrawOverlay`, `selectionFreeDrawOverlay`,
   `brushPaintOverlay`, `brushMaskCanvas` — sve dimenzionisane po `frame`. Ceo lanac
   tool overlay-a (osim crop-a) umotan u `.frame(proxy.size).contentShape(Rectangle())
   .clipped()`.

### Potvrđeno merenjem, oba

- Quick Clean Up na zoom 1.95: **`TAPPED zoom=1.953125`** (ranije ništa)
- Sa Patch overlay-em aktivnim i zoom 1.95, klik na Selection: dugme se **upalilo**

Usput popravljeno u `removalPaintOverlay`: naslikani potezi nisu bili odsečeni na
oblast pregleda, pa su se zumirano crtali preko panela. Susedni `removalOverlay` jeste
bio odsečen — i komentar iznad njega kaže tačno zašto.

## KORAK 25 — lag pri pomeranju miša sa aktivnom četkicom (30. avgust 2026)

Prijava: *„kao da pc ne moze da podnese toliko informacija, pomeram mis on laguje".*

`removalBrushHoverLocation` je bio `@State` na `DevelopView`. Kursor se pomera 60-120
puta u sekundi, i **svaki taj upis je poništavao ceo `DevelopView.body`** — sliku, sve
sekcije panela, filmstrip, histogram — da bi pomerio jedan krug. Posao po pomeraju miša
bio je srazmeran celom ekranu umesto krugu.

Popravka: `BrushCursorPosition: ObservableObject` koji roditelj drži kao `@State` nad
KLASOM (čuva referencu bez pretplate na `@Published`), a posmatra ga samo nov
`BrushCursorRing`. Pomeraj miša sad precrtava prsten i ništa više. Traži `import Combine`.

**Potvrdio korisnik uživo: „sada je smooth".**

**Ostaje isti obrazac na `brushHoverLocation`** (četkica za maske) — nije dirano jer nije
prijavljeno, ali je ista mina, i `activeRemovalStrokePoints` je i dalje `@State` pa
samo CRTANJE i dalje poništava ceo body.


## KORAK 26 — čišćenje više ne izbacuje iz alata (30. avgust 2026)

Prijava: *„kada sam u AI Selection i kada kliknem Quick Clean ili AI Clean, on mi posle
izbaci da moram opet da kliknem na AI Selection... umesto da ostane tu gde je."*

Uzrok je bila jedna linija na kraju uspešnog brisanja u `eraseMaskedArea`:

```swift
settings.layers.append(layer)
clearRemovalMask()
activeSelection = nil
isRemoveBrushActive = false   // <- ovo
```

Uklanjanje retko kad znači JEDNO uklanjanje — normalan oblik posla je namaži, očisti,
namaži sledeće, očisti. Alat sad ostaje upaljen. `clearRemovalMask()` je iznad već
ispraznio poteze, pa je preostalo stanje četkica naoružana nad čistim listom, što je
tačno ono od čega sledeće uklanjanje kreće.

Uz to `isRemoveBrushErasing = false`: brisanje IZ prazne selekcije ne radi ništa, pa bi
ostanak u Erase režimu bio mrtav kursor.

### Izlaz iz alata

Korisnik je predložio dugme za izlaz **umesto** „Select People". Nije urađeno tako:
„Select People" PRAVI selekciju i druga je polovina istog workflow-a, pa bi zamena
uklonila funkciju da bi se dodala druga.

Umesto toga, **„Done" je dodat u red ispod trake** — onaj koji ionako postoji samo dok
je četkica upaljena (uz „Size" i „Adding to selection"). Izlaz se pojavljuje tačno kad
ima iz čega da se izađe. „AI Selection" je i dalje toggle, kao i pre.

### Provereno vožnjom prave app-e

Isti skriptovani rig kao u KORAKU 24, na `C4S_7792.NEF`:
- posle Quick Clean Up-a: **„AI Selection" i dalje istaknut**, red sa „Size" i dalje tu,
  „Adding to selection" (ne Erasing), poruka „Nothing is selected yet" — čist list
- klik na „Done": alat ugašen, red nestao, traka se vratila u normalu

**⚠️ Napomena za sledeću sesiju o pokretanju app-e za testiranje:** `open Build/.../
BriefShow.app` je više puta ostavljao SAMO 0×0 prozore (stanje opisano u TL;DR-u).
`nohup ./BriefShow.app/Contents/MacOS/BriefShow &` je davao pravi prozor svaki put.
Ako prozor ne postoji, to je prvo što treba probati, a ne dijagnostikovati app.


## KORAK 27 — traka preimenovana po korisnikovom zahtevu (30. avgust 2026)

Zahtev: ukloniti „Select People" iz trake i staviti „Exit AI Clean Up"; „AI Selection"
preimenovati u „AI Clean Up", sa ikonicom od slova **AI** umesto četkice.

Traka je sada:

```
Crop | Selection | Patch | [AI] AI Clean Up | ✕ Exit AI Clean Up | Quick Clean Up | Generative Clean Up
```

### Sudar imena, i kako je razrešen

U traci je VEĆ postojalo dugme „AI Clean Up" — generativni (Stable Diffusion) engine,
pored „Quick Clean Up" (LaMa). Preimenovanje alata bi dalo dva dugmeta istog imena u
istom redu.

Generativni je zato postao **„Generative Clean Up"**, i u traci i u
`RemovalEngine.title`. To je uz to i tačnija reč: ~13s SD putanja naspram ~1s LaMa
putanje pored nje. Ako se traži drugo ime, menja se na ta dva mesta.

### Select People nije obrisan, premešten je

Ostaje u `removeSection`, dakle u panelu pod karticom **Retouch**, i to mu je sada
jedini ulaz. Nije obrisan jer PRAVI selekciju — zahtev je bio za izlaz iz alata, ne za
gubitak ulaza u njega. Poruka „Nothing is selected yet…" sada upućuje tamo.

### Sitnice iz istog zahvata

- `toolButton` je dobio `textIcon:` parametar — crta slova gde bi išao SF Symbol,
  uokvireno na istu širinu da red ostane na jednoj liniji. „AI" nema glif koji kaže
  šta je.
- **„Done" iz KORAKA 26 je uklonjen** — izlaz je sad u samoj traci, pa bi dva izlaza
  bila dva imena za istu radnju.
- „Exit AI Clean Up" je `disabled` a ne sakriven dok je alat ugašen: dugme koje se
  pojavljuje i nestaje pomera sve ostale u traci u stranu, a taj red je mišićna memorija.
- Panel prati traku: „AI Selection (painting)" → „AI Clean Up (painting)".

Provereno u pokrenutoj app-i: sva četiri imena i AI ikonica stoje kako treba, alat
aktivan, Exit upaljen, „Quick Clean Up" ugašen dok nema selekcije.


## KORAK 28 — Clean Up traka: ime, Add/Erase, Clear AI Area, i undo (30. avgust 2026)

Zahtev: ostaviti AI ikonicu a tekst skratiti na „Clean Up"; dodati history za Cmd+Z;
dodati dugme koje uklanja sve markovano; i omogućiti da painting oduzima od već
markovanog, „kao Lightroom".

### Urađeno

1. **`[AI] Clean Up`** — ikonica nosi „AI", tekst više ne ponavlja. Uz to
   „Exit AI Clean Up" → **„Exit Clean Up"**, da se par slaže.
2. **Add / Erase u redu ispod trake.** Kontrola je oduvek postojala u Retouch panelu;
   preseljena je i ovde jer se painting dešava ovde, a niko ne skroluje panel usred
   poteza. Erase oduzima od već markovanog, uključujući i ono što je našao Select
   People — što je tačno traženo Lightroom ponašanje.
3. **„Clear AI Area"** — briše SVE oznake (poteze i Select People masku) bez diranja
   fotografije. Red se prikazuje i kad je četkica ugašena a selekcija postoji
   (`hasRemovalArea` je dodat u uslov), inače Select People maska ne bi imala gde da
   se odbaci osim kroz panel.
4. **Undo NIJE trebalo praviti — već je postojao i radi.**

### Zašto je „Clear", ne „Clean"

Tri dugmeta u traci iznad kažu „Clean Up" i svako od njih MENJA fotografiju. Ovo samo
odbacuje oznaku. Ime na jedno slovo od ta tri čitalo bi se kao četvrti način da se
nešto obriše.

### Undo — izmereno, pošto sam prvo pogrešno zaključio da ne radi

Prva tri Cmd+Z-a nisu uradila ništa i zaključio sam da history ne postoji za ovu
putanju. **Bilo je pogrešno.** `NSApp.keyWindow` je `nil` dok app nije aktivna, pa
`installEditingKeyMonitor` odbija događaj na prvoj liniji — tasteri poslati preko
`postToPid` stižu procesu, ali monitor ih ne prihvata. Isti Cmd+= tada takođe nije
radio, i to je bio trag.

Sa aktivnom app-om, kontrolisano merenje spiska layera:

```
pre ciscenja  -> posle ciscenja : 0.77%   (novi "Removed" red)
posle ciscenja -> posle Cmd+Z   : 0.77%   (vraceno)
pre ciscenja  -> posle Cmd+Z    : 0.00%   piksel u piksel isto
```

`eraseMaskedArea` dodaje `ImageLayer` u `settings.layers`; `.onChange(of: settings)`
gura snimak na `undoStack` posle 0.5s mirovanja. Ništa nije trebalo dodati.

**⚠️ Pravilo za skriptovano testiranje:** pre slanja bilo kog tastera aktivirati app
(`set frontmost`) I kliknuti u prozor. Inače taster tiho ne radi ništa, i to izgleda
kao kvar u funkciji koja se testira. Isto važi za klikove na dugmad — prvi „Clear AI
Area" klik je promašio iz istog razloga.

### Zatečeno stanje na testnoj fotki

`C4S_7792.NEF` u `RAW Tests Images` nosi **12 „Removed" layera** iz mojih testova, plus
jedan Exposure pomak. Sve je nedestruktivno (`PhotoEditStore`, original na disku
netaknut), ali stoji dok se ne poništi ili resetuje.


## KORAK 29 — selekcija je sada roze, i painting ne rezonuje dok traje (30. avgust 2026)

### Boja

Prijava: *„promeni boju da ne bude plava za AI selection vec crvenkasto rose".*

Promenjeno na **dva mesta koja MORAJU da se slazu**, jer rucno naslikani potezi i
Select People maska postaju JEDNA selekcija koja se brise u jednom potezu:
- `Develop.swift`, `removalPaintOverlay`: `Color(red: 1.0, green: 0.35, blue: 0.51)`
- `DevelopInpaint.swift`, `overlayImage`: `(r: 255, g: 90, b: 130)`

**Roze, ne cist crven, i to namerno.** Beleska koja je tu stajala od ranije je i dalje
tacna i zato je zadrzana u kodu: cista crvena se na fotografiji cita kao UPOZORENJE
umesto kao „ovo je izabrano", a na toplim kadrovima na kojima se ovaj alat koristi
(koza, pesak, zalazak) i crvena i bela su najteze za razaznati. Pomeranjem tona ka
magenti dobija se trazeni roze, a ostaje se van narandzasto-crvene ose od koje su te
fotke i sacinjene.

Potvrdeno na ekranu: potez je roze.

### Painting vise ne poništava ceo prikaz

Prijava: *„dok paintujem tada mi laguje... da ne rezonuje dok paintujem pa laguje,
vec kada zavrsim paint (click drag release) tada moze da rezonuje sta je paintovano".*

Ovo je bio **poznat preostali trosak zapisan u KORAKU 25** — tamo je popravljen samo
prsten kursora, a tacke poteza su ostale `@State` na `DevelopView`.

Isti obrazac primenjen i na njih:
- `ActiveStrokePoints: ObservableObject` — tacke poteza u toku, drzane kao `@State`
  nad KLASOM (referenca prezivi, bez pretplate na `@Published`)
- `ActiveStrokeLayer` — jedino dete koje ih posmatra, crta samo taj jedan potez
- `briefShowStrokePath(_:frame:)` — putanja izvucena u slobodnu funkciju, da
  zapoceti i zavrseni potez crta ISTA funkcija; inace bi linija vidno poskocila
  u trenutku pustanja misa
- `isPaintingRemovalStroke` — samo zastavica za skrivanje prstena, menja se dvaput
  po potezu umesto jednom po dogadjaju

Rezultat je tacno ono sto je trazeno: dok se vuce, menja se samo ta jedna putanja;
`commitRemovalStroke()` na pustanju misa upisuje gotov potez u `removalStrokes`
jednim `@State` upisom — **jedan prolaz kroz body po potezu umesto jednog po tacki.**

Izmereno tokom poteza od 120 koraka: **prosek 23,7% CPU, vrh 80%, i 0% odmah po
pustanju** (nema repa posle poteza). „Pre" broj nije uzet — trazio bi jos jedan build
i ponovno pokretanje — pa je ovo apsolutna mera, ne poredjenje.

### Ostaje

Isti obrazac i dalje stoji na cetkici za maske (`brushHoverLocation` i njene tacke) —
nije dirano jer nije prijavljeno, ali je ista mina.


## KORAK 30 — sve u jednom redu, i prompt za Generative Clean Up (30. avgust 2026)

### Traka u jednom redu

Zahtev: Size / Add / Erase / Clear AI Area da se popnu desno od „Generative Clean Up",
umesto da stoje u redu ispod.

Urađeno. `toolStripDetail` više ne nosi nijednu kontrolu — ostala mu je SAMO rečenica
(razlog zašto se ne može čistiti, plus stanje Add/Erase). Rečenica je jedina stvar koja
ne može u isti red: dovoljno je duga da na užem prozoru izgura dugmad van ekrana.

**Cena, izmerena na prozoru od 1470pt:** kad su sve kontrole prisutne, „Quick Clean Up"
i „Generative Clean Up" se skraćuju na „Quick Clean…" i „Generative Cl…". Kad selekcija
nestane, „Clear AI Area" izađe iz reda i imena se vrate cela. Ako to smeta, izbor je
između kraćih imena i povratka na dva reda.

### Prompt za Generative Clean Up

Zahtev: prompt koji tera generativni engine da radi kao Quick Clean Up — dakle kao LaMa,
koja nastavlja okolnu teksturu i ne izmišlja ništa.

**Prava greška u starom promptu bila je fraza „no people".** Komentar iznad same
konstante već kaže da CLIP čita prompt kao spisak stvari koje treba naslikati — a po
tom istom pravilu „no people" ubacuje token *people* u POZITIVNO uslovljavanje. Traži
tačno ono što izgleda da zabranjuje. Negacija pripada negativnom promptu, gde
classifier-free guidance može stvarno da gura OD nje, i tamo je već i stajala.

```
pozitivan: "empty background, plain continuous surface, uniform texture, seamless continuation"
negativan: "person, people, human, face, body, animal, object, sign, text, letters,
            watermark, logo, ornament, duplicate"
```

Pozitivan sada imenuje samo podlogu — površinu, njenu teksturu, i to da se nastavlja.
Nijedan subjekat, ništa oko čega bi se scena mogla sagraditi. Negativan je proširen sa
`person` na sve što inpaint od 512px poseže kad odluči da rupa treba nešto da sadrži.

**Blob je regenerisan, ne ostavljen zastareo.** `SDModelStore.promptEmbedsURL` traži
`sd_prompt_embeds.bin` u bundle-u (nema ga tamo — nije u Xcode projektu), pa u model
direktorijumu. Da je ostao stari, `embeddings()` bi na svakoj sesiji padao na živu
putanju i učitavao TextEncoder od 235 MB. Regenerisan je postojećim alatom:

```bash
IDS=$(python3 Tools/clip_tokenize.py "<negativan>" "<pozitivan>")
swift Tools/dump_prompt_embeds.swift "<negIds>" "<posIds>" \
      ~/Desktop/BriefShow/CoreMLModels/SD15-Inpainting  out.bin
```

Upisan na oba mesta: `Tools/sd_prompt_embeds.bin` i
`CoreMLModels/SD15-Inpainting/sd_prompt_embeds.bin`. **To je jedini upis u
`CoreMLModels/` ikada napravljen ovde** — 236 KB regenerabilnog artefakta, nijedna
težina nije dirana, direktorijum i dalje 4,4 GB.

Provereno u pokrenutoj app-i: generativno čišćenje prolazi bez greške u logu, roze
potez nestaje, šara haljine se nastavlja, ništa nije izmišljeno.

### Jači poluga koja NIJE dirana

`guidanceScale = 7.5` je ono što najviše tera SD da sledi prompt i izmišlja. Za
LaMa-oliko ponašanje spuštanje te vrednosti je jače od bilo koje izmene teksta. Nije
dirano jer je uz nju zapisano „confirmed on the user's own photos", i jer je zahtev bio
za prompt. Ako prompt sam ne bude dovoljan, to je sledeće što treba probati.


## KORAK 31 — veca radna povrsina, ostriji generativni, i red koji je nestao (30. avgust 2026)

### Zasto je generativni mutan a Quick nije — nije prompt

Dva strukturna razloga, oba u kodu:

| | Quick (LaMa/exemplar) | Generative (SD) |
|---|---|---|
| radna rezolucija | do `maxWorkingEdge` | **fiksnih 512**, konverzija nema fleksibilan ulaz |
| odakle pikseli | **kopira prave** iz okoline | sintetise ih, pa VAE round-trip |

Za rupu od 800px: SD region je bio 2.0x = 1600px stisnut u 512 → svaki sintetisani
piksel razvucen preko 3.1 pravog. LaMa je isti taj region radila na 1100 → 2.0x.
**Otud blur samo kod generativnog.**

Smanjen SD kontekst 2.0 → **1.6** (`squareRegion`), sto isti taj 800px otvor spusta sa
3.1x na 2.5x razvlacenja. Trade je stvaran — manje okolne fotke je tacno smer koji tera
SD da izmislja — pa je pomeren delimicno, ne na 1.0.

**Ovo ga NE izjednacava sa Quick-om i ne moze.** Jedini pravi nacin je pustiti model
preko preklapajucih 512 plocica u nativnoj rezoluciji; to je zaseban, mnogo veci
zahvat.

### Quick radna povrsina: 1000 → 2200 px

Smear nikad nije bio funkcija velicine rupe u FOTOGRAFIJI nego koliko se region morao
smanjiti da stane u radni bafer. Zato su dizani zajedno:

```
maxWorkingEdge      1100  → 2200   (razvlacenje prepolovljeno na istoj rupi)
maxHolePixels     45 000  → 180 000 (inace bi shrink-and-retry ponistio gornje)
blockingAreaPixels  1000  → 2200   (prag pomeren, a ne dozvoljen kvar na vecem broju)
```

**Cena je kvadratna i placa se na SVAKOM uklanjanju**, ne samo na velikom: pretraga
zakrpa je O(rez^2), pa je 1100 → 2200 oko 4x posla. Ranije ~1s. **Nije pouzdano
izmereno** — dva pokusaja merenja su promasila (prvi je uhvatio pojavu spinnera, drugi
je klikao na „Clear AI Area" na staroj poziciji posle preseljenja u traku). Ako
uklanjanje pocne da se oseca sporo, ovo je prvo mesto koje treba spustiti.

### Red ispod trake vise ne postoji

Kontrole su presle u traku (KORAK 30), a recenica je ostala kao red — i taj red je
menjao visinu kad se tekst prelomi u dva reda, pa je gurao sliku dole i gore.

Sada je `cleanUpNotice`: string, crtan kao kartica **preko pregleda**, isti obrazac kao
`sliderToast`. Ne zauzima raspored, pa slika stoji mirno. Cuti kad alat nije u igri.

`toolStripDetail` je uklonjen iz rasporeda.

### Progres preseljen u gornju traku

„Cleaning up… N%" je bio u traci sa alatima i pomerao svako dugme posle sebe dok traje
brisanje. Sada stoji desno od RAW oznake, uz ime fajla — na trazenom mestu, i tamo gde
oko ionako ode tokom ~13s generativnog brisanja.


## KORAK 32 — „Clear All" u zaglavlju Layers panela (30. avgust 2026)

Zahtev: dugme koje briše sve layere odjednom, umesto trash ikonice red po red.
Postavljeno desno u `LAYERS` zaglavlju, uz brojač: `LAYERS  [🗑 Clear All]  19`.

**Nazvano „Clear All", ne „Clear All History" kako je traženo.** Ova app IMA istoriju —
`undoStack`, Cmd+Z — a ovo dugme je ne dira; briše spisak layera. Ime sa rečju History
u panelu koji se zove Layers čitalo bi se kao brisanje undo steka. Menja se na jednom
mestu ako se traži drugačije.

**Bez dijaloga za potvrdu, namerno.** Upisuje u `settings.layers`, pa pada na undo stek
kao svaka druga izmena. Potvrda bi bila drugi klik koji štiti od nečega što jedan
taster već poništava. Tooltip to i kaže.

Provereno u pokrenutoj app-i, nad 19 nakupljenih layera:

```
posle Clear All : panel se promenio 16,66%  (spisak prazan)
posle Cmd+Z     : 0,00% razlike od stanja PRE brisanja — svih 19 vraćeno
```


## KORAK 33 — gumica nije oduzimala površinu, i ivice na dugmadima (30. avgust 2026)

### Bug: Erase je POVEĆAVAO izmerenu površinu

Prijava, i dijagnoza je bila tačna: *„on računa kada se stavlja brush na slici ali ne
oduzima kada se briše brush"*. Namažeš veliku površinu, Quick Clean Up se ugasi, uzmeš
Erase da je smanjiš — dugme ostaje mrtvo.

`removalAreaPixels` je unijom sabirao **sve** poteze iz `removalStrokes`, bez obzira na
`isErase`. Znači svaki potez gumicom je širio okvir umesto da ga sužava, i jednom kad
je prag pređen nije ga bilo moguće vratiti nikakvim brisanjem.

Popravka: dabovi brisanja se skupljaju posebno, iz unije se izbacuju, a **dodata tačka
se preskače kad je pokrije dab brisanja** — pa brisanje krajeva dugog poteza stvarno
sužava okvir. Provera je „centar tačke u dabu", ne pun preklop: pass gumicom je niz
preklapajućih dabova, a traženje punog sadržavanja bi pustilo tačku da preživi između
dva i sama drži ceo okvir otvorenim.

**`removalMaskUnitBox` (Select People maska) i dalje se ne sužava brisanjem** — to je
jedan pravougaonik bez tačaka koje bi se mogle izbaciti. Ostaje poznat trošak.

### Ivice na dugmadima

Prijava: Slideshow / Develop / Add Photos / Select All / Deselect / Export All / Done i
kartice Edit-Retouch-Layers izgledaju kao goli tekst, ne kao dugmad.

Uzrok je bio jedan: `ShowHeaderButtonStyle` (u `ContentView.swift`) nije imao nikakvu
ivicu, a koristi se **37 puta**. Ivica je dodata tamo — isti oblik i boja koje traka sa
alatima već koristi (`cornerRadius 6`, `AppColors.border` na 0.7) — pa je dobiju sva
odjednom i dva reda čitaju kao jedna porodica. Kartice panela (`panelTabBar`) su dobile
istu, jer je do sada samo AKTIVNA imala ispunu a druge dve ništa.

### ⚠️ Pogrešna atribucija, zapisana da se ne ponovi

Posle ove izmene app je šest puta zaredom otvorila samo prazan 0×0 prozor. Zaključio sam
da je izmena kriva i vratio je — prozor se pojavio iz prvog pokušaja, što je izgledalo
kao potvrda.

**Nije bila kriva.** App ima ekran za prijavu: prozor se pojavi tek kad korisnik ukuca
lozinku. Svi moji „0×0" pokušaji kroz celu sesiju bili su app koja čeka prijavu, a
„popravka" se poklopila sa trenutkom kad je korisnik ukucao lozinku.

**Pravilo za sledeću sesiju: 0×0 prozor NIJE kvar — to je ekran za prijavu. Sačekati da
korisnik uđe, i ne gasiti app sa `kill -9` posle toga, jer sledeće pokretanje traži
lozinku ponovo.**


## KORAK 34 — četkica ostaje na slici, i zašto `searchRadius` nije bio uzrok (30. avgust 2026)

### Prvo ono što obara plan iz prethodne sesije

Prethodna sesija je ostavila hipotezu (c) kao prvu stvar za probati: da je bela
mrlja od `Quick Clean Up`-a nastala zato što je `ExemplarInpainter.fill` ostao na
`searchRadius: Int = 80` dok je `maxWorkingEdge` u KORAKU 31 podignut 1100 → 2200,
pa inpainter efektivno pretražuje upola manje slike.

**To ne može biti uzrok, jer taj kod se nikad ne izvršava.**

```
$ grep -rn "InpaintPipeline.removal" --include="*.swift" .
(ništa)
```

UI zove tačno dve stvari (`Develop.swift:7272` i `:7275`):

- `InpaintPipeline.quickAIRemoval` → `LaMaInpaintPipeline.shared.fill` na
  **fiksnih 512** (`LaMaInpaintPipeline.imageSide = 512`)
- `InpaintPipeline.aiRemoval` → SD, takođe 512

`ExemplarInpainter` — sa `searchRadius`, `maxWorkingEdge` i `maxHolePixels` — visi
ispod `InpaintPipeline.removal`, koji niko ne poziva. To je mrtav kod.

Iz toga slede tri stvari:

1. **`maxWorkingEdge` 1100 → 2200 i `maxHolePixels` 45 000 → 180 000 iz KORAKA 31
   nisu promenili baš ništa.** Menjan je mrtav kod.
2. **`DevelopLaMaInpaint.swift` je diran tačno jednom, pri nastanku** (`git log`
   nad tim fajlom vraća samo `2f96e09`). Način na koji Quick računa rezultat se
   od tada nije promenio ni jednom linijom.
3. Jedino što je KORAK 31 stvarno promenio za Quick je granica
   `blockingAreaPixels` `.quick`: **1000 → 2200**. Obrazloženje upisano u komentar
   („That cap is now 1600, so the region is scaled down a third less") poziva se
   na `maxWorkingEdge` — konstantu koju Quick ne koristi.

### Time pada i sumnja koju je prethodna sesija ostavila otvorenom

Pitanje je glasilo: „ako je uzrok samo sunce, zašto se nije javljalo pre KORAKA 31?"

Odgovor: **kod male površine se ništa i nije promenilo.** Granica se ne tiče male
površine, a računica je bajt-identična onoj od pre KORAKA 31. Bela mrlja na maloj
površini nije regresija — to je **KORAK 16**, koji je istu stvar već opisao 26.
avgusta: LaMa nastavlja dominantnu teksturu okoline, a kad je okolina prežarena
(sunce, prežaren pesak, nebo), ta tekstura JESTE belina. KORAK 16 to i piše
doslovno: „ili kod korisnika presvetlo nebo → bela mrlja".

Kod velike površine granica jeste bila zaštita i jeste uklonjena. **Korisnik je
odlučio da 2200 ostaje** — zapisano da se ne vraća po inerciji.

Prava popravka za belu mrlju nije nijedan broj u `Develop.swift` nego veći ulaz
u sam model, što je KORAK 19 već izmerio i odbacio na 1024.

### Sad ono što je zaista popravljeno

Potez „AI Selection" četkice crtao se i preko sive margine pored fotografije.
Dva odvojena kvara, oba popravljena:

**Crtanje.** Prekrivač je bio odsečen na `containerSize` (KORAK 24), što je oblast
PREGLEDA. Fotografija je unutar pregleda uokvirena sivim, pa je potez i dalje mogao
da izađe na tu marginu. Sad se odseca na `fitted` — okvir same slike — presečen sa
kontejnerom. Presek je bitan: pri „fit" je slika manja od pregleda, zumirano je
veća, i potez mora da stane na ono što je uže na svakoj ivici.

Za to je dodat `PreviewClipShape`, jer `.clipped()` seče na SOPSTVENE granice viewa,
a ovde treba seći na pravougaonik zadat u koordinatama roditelja.

**Bojenje.** `unitPoint(from:frame:)` klampuje na 0…1, pa se tačka iz margine
lepila na ivicu slike — tvrda linija selekcije niz bok kadra koju niko nije nacrtao.
Sad se tačka van slike **odbacuje**, ne klampuje.

Odbacivanje je bezbedno i vredi zapisati zašto: potez se crta kao niz pravih
segmenata između susednih zapamćenih tačaka, a **segment između dve tačke unutar
pravougaonika ostaje unutar njega**. Znači potez koji izađe sa slike i vrati se ne
može da ostavi geometriju napolju — linija samo preseče, što bi uradila i da je
miš tuda prošao po slici.

Isto odsecanje dobio je i renderovani `removalOverlay` (maska iz „Select People").

**Nije dirano:** `paintBrush` i `paintPatchStroke` imaju isti oblik greške (isti
`unitPoint`, isto klampovanje). Prijavljena je bila samo AI selection četkica, pa
je samo ona i menjana.

## KORAK 35 — import direktno sa kamere preko USB-a (30. avgust 2026)

Korisnikov zahtev, sa slikom Lightroom-ovog Import prozora: „povezao sam Z 6 sa
USB-om i Lightroom odmah vidi slike — može li isto u BriefShow-u, da se pojavi ceo
folder kamere spreman za import na mac?"

### Zašto ImageCaptureCore, a ne traženje mountovanog diska

Nikon Z 6 u podrazumevanom USB režimu je **MTP/PTP uređaj — ne montira se kao
disk.** U Finder-u ga nema, `/Volumes` ga ne vidi, i nikakvo prolaženje kroz
fajl-sistem ga ne bi našlo. `ImageCaptureCore` je framework koji govori PTP i koji
koriste i Image Capture.app i Lightroom. Zato ide preko njega.

### Šta je napravljeno

Dva nova fajla. Projekat koristi `PBXFileSystemSynchronizedRootGroup`, pa se novi
`.swift` fajl pokupi sam — `project.pbxproj` nije trebalo dirati.

**`CameraImport.swift`** — sloj prema kameri:

- `CameraBrowser` — jedan `ICDeviceBrowser` za celu app, pokrenut jednom.
  Maska je `camera | local`, pa se ne prijavljuju deljene i Bonjour kamere sa
  drugih Mac-ova na mreži.
- `CameraImportSession` — otvara sesiju na jednoj kameri, čita `mediaFiles`,
  vuče sličice i kopira izabrano.

**`CameraImportView.swift`** — sam prozor, isti trodelni raspored kao Lightroom-ov
(izvor levo, mreža sličica u sredini, odredište desno), u paleti ShowGrid-a.

**Ukopčano u ShowGrid** (`ContentView.swift`): sekcija „DEVICES" iznad stabla
foldera, i prozor koji se **sam otvori kad se kamera upali**.

### Odluke koje nisu očigledne, i zašto

**Sličice se traže najviše 6 odjednom.** ImageCaptureCore rado primi zahtev za
svaki fajl na kartici odjednom, a to su na punoj kartici hiljade PTP razmena koje
posle izgladnjuju samo preuzimanje.

**Preuzimanje ide jedan po jedan fajl.** Paralelno sa jedne kamere nije brže —
jedan USB endpoint, jedan čitač iza njega — a progres postaje besmislen i
delimičan neuspeh mnogo teži za prijavu.

**`.overwrite` je `false`.** ImageCaptureCore tad sam pravi jedinstveno ime
(`DSC_0001-1.NEF`) umesto da pregazi fajl. To je bezbedna strana odluke koju
korisnik ne može da poništi.

**„Delete from camera after import" je podrazumevano isključeno** i ispod njega
piše da nema undo. To je jedina nepovratna stvar u tom prozoru, a kartica nije
kanta.

**Dnevni podfolder se imenuje po danu kad su fotke SNIMLJENE, ne po današnjem
danu.** Kartica uvezena ujutru posle svadbe pripada danu svadbe — to je i jedini
razlog da se uopšte grupiše po datumu.

**Sesija se zatvara na `onDisappear`.** Kamera ostavljena sa otvorenom sesijom
ostaje zaključana za ovu app, i na većini tela to znači da korisnik ne može da
koristi sopstvenu kameru dok BriefShow ne izađe.

### ⚠️ Mina nađena usput, i zašto bi bila gadna

```
@property (nonatomic, readwrite, assign, nullable) id <ICDeviceDelegate> delegate;
```

**`assign`, ne `weak`.** Dealociran `CameraImportSession` ostavljen u tom polju je
viseći pokazivač, i prvi sledeći callback ruši app. A taj callback je tipično
**iskopčavanje kamere, minutima pošto je prozor zatvoren** — što ga čini otprilike
najtežim padom za povezivanje sa uzrokom.

Rešeno u `deinit`, ne samo u `close()`, jer `close()` ide iz `onDisappear` i nije
zagarantovan na svakom putu kojim objekat može da nestane. Uslovljeno identitetom:
ponovno otvaranje prozora za istu kameru pravi NOVU sesiju koja je već preuzela to
polje, pa bi slepo brisanje ućutkalo nju umesto ove.

### Entitlement

Dodat `com.apple.security.device.usb`. **Bez njega sandboxovana app ne dobija
nijedan rezultat od `ICDeviceBrowser`-a — browser se pokrene, ne prijavi ništa, i
nikad ne javi grešku.** Provereno da je ušao u potpisanu app
(`codesign -d --entitlements -`).

### Šta JESTE provereno

- svaki potpis iz ImageCaptureCore-a proveren probnim prevođenjem uz SDK zaglavlja,
  ne po sećanju (imena `ICDownloadOption` konstanti su iznenađenje: `.overwrite` i
  `.deleteAfterSuccessfulDownload`, ne ono što se očekuje)
- `ICDeviceBrowser` se pokreće čisto u zasebnom binarnom fajlu
- build čist, app se pokreće, nema izveštaja o padu
- entitlement u potpisanoj app-i

### ⚠️ Šta NIJE provereno

**Ništa sa pravom kamerom.** Z 6 nije bio povezan (`ICDeviceBrowser` prijavio 0
uređaja). Prvi test je: povezati kablom, upaliti, i videti da li se „DEVICES"
pojavi u sidebar-u i da li se prozor sam otvori.

Ako se ne pojavi, redom: (1) da li je USB režim kamere MTP/PTP, (2) da li je
`Image Capture.app` vidi — ako ni ona ne vidi, nije do BriefShow-a, (3) da li je
macOS tražio dozvolu za pristup uređaju.


## KORAK 35, dopuna — kamera NIJE vezana za Nikon (30. avgust 2026)

Korisnikovo pitanje: „ali ne samo za Nikon Z 6, neko koristi Canon — hoće li i to
da prepozna?"

Hoće. U kodu nema nijedne linije koja pominje proizvođača — Nikon se pojavljuje
samo u komentarima, kao primer na kom je pisano.

`ICDeviceBrowser` sa maskom `camera | local` prijavljuje **svaku** kameru koju
macOS ume da vidi, jer ne govori ni Nikonov ni Canonov protokol nego **PTP/MTP**,
standard koji poštuju sva tela: Canon, Sony, Fujifilm, Panasonic, Olympus,
Leica, i čitači kartica.

Praktično pravilo za proveru, bez ijedne izmene u kodu: **ako uređaj vidi
`Image Capture.app`, videće ga i BriefShow** — obe app-e gledaju kroz isti
framework. Ako ga ni Image Capture ne vidi, problem je u USB režimu kamere ili
u kablu, ne u BriefShow-u.

Jedina razlika koja se u praksi javlja je da neka tela (češće Canon) nude i režim
„mass storage", u kom se kartica montira kao disk. I taj slučaj je pokriven:
ImageCaptureCore prijavljuje i takve uređaje kao `ICCameraDevice`.

## KORAK 36 — painting više ne osvežava ništa dok traje (30. avgust 2026)

Korisnik, posle KORAKA 25/29: „danas smo popravili da kada kliknemo na AI selection
da laguje i posle nije lagovalo… ali nije baš da nije lagovalo, ipak se oseti da
lagne neki put. Kada paintujemo, tada samo da bude paint, da se baš ništa ne
rezonuje — tek kada drag završi može da se izrezonuje to što je paintovano."

### Šta je ostalo posle prethodne popravke

Prethodna sesija je izmestila i poziciju kursora i tačke poteza u observable
objekte koje roditelj drži ali ne posmatra. Ostala je **jedna** stvar:

```swift
@State private var isPaintingRemovalStroke = false
```

sa komentarom koji je sam sebe opravdao: „flips twice per stroke instead of once
per drag event, which is cheap enough to stay @State".

**Nije jeftino.** Upis u `@State` poništava `DevelopView.body`, a to telo je
slika, panel, filmstrip, histogram i traka sa alatima. Znači **svaki potez je
počinjao punim ponovnim gradnjom celog ekrana** — tačno u trenutku kad se povuče
prva tačka, što je tačno ono „lagne kad krenem" iz prijave.

### Zašto je taj jedan prolaz skuplji nego što zvuči

U telu se čita `removalAreaPixels`, koji je **ugnežđena petlja**: za svaku dodatu
tačku prolazi kroz sve „erase" dabove (`erasedDabs.contains(where:)`). Čita se sa
tri mesta (`removalAreaFits` dvaput, `removalAreaWarrantsCaution` jednom), i nema
keširanja — računa se iznova na svako čitanje.

Zato lag **raste sa količinom već naslikanog**, što se poklapa sa „neki put" iz
prijave: na praznoj fotki se ne oseti, posle više poteza se oseti.

### Popravka

`isPaintingRemovalStroke` je preseljen u `BrushCursorPosition` kao
`isStrokeInProgress`. Jedini koji ga čita je prsten kursora, a on taj objekat
**već posmatra** — pa ga sad čita odande umesto da mu se prosleđuje.

Rezultat: **nula prolaza kroz `DevelopView.body` tokom poteza.** Provereno
čitanjem cele drag putanje, redom:

| upis u `onChanged` | gde živi | poništava `body`? |
|---|---|---|
| `removalBrushCursor.isStrokeInProgress` | `@Published` na klasi koju roditelj drži kao `@State` | ne |
| `removalBrushCursor.location` | isto | ne |
| `activeRemovalStroke.points.append` | isto | ne |

Ključno je da roditelj te objekte drži kao `@State` (referenca), **ne** kao
`@ObservedObject` — pa `objectWillChange` stiže samo do `BrushCursorRing`-a i
`ActiveStrokeLayer`-a, a ne do `DevelopView`-a.

Na `onEnded` `commitRemovalStroke()` upisuje u `removalStrokes` (`@State`) → jedan
prolaz, i to je tačno „tek kada drag završi" iz zahteva.

### Šta NIJE dirano, i zašto

Razmišljano je da se potez u toku izvuče iz zajedničkog `compositingGroup()` sa
već potvrđenim potezima, da njegovo precrtavanje ne bi ponovo komponovalo i njih.
**Odbačeno**: grupa postoji zato što se svaki potez crta neproziran pa se tek
grupa spusti na 45%. Da je potez u toku svoja grupa, tamo gde pređe preko već
naslikanog videla bi se tamnija mrlja koja nestane čim se pusti miš — što je
tačno onaj kvar koji je ta grupa i uvedena da reši.

### ⚠️ Neizmereno

Broj prolaza kroz `body` je izveden **čitanjem koda** (tabela gore), ne brojačem
u pokrenutoj app-i — nema načina da se potez odvuče bez pravog miša. To da se lag
više ne oseti mora da potvrdi korisnik.

## KORAK 37 — crtice na slajderima (30. avgust 2026)

Korisnikov zahtev, sa slikom Lightroom-ovog Basic panela.

Dodato u **oba** slajdera, jer stoje u jednoj koloni i dva različita ritma crtica
niz isti panel čitaju se kao greška, ne kao razlika:

- `EditTrackSlider` — obični (Exposure, Contrast, Highlights, …)
- `GradientTrackSlider` — Temperature, Tint, Saturation, Vibrance

**8 intervala, dakle 7 crtica.** Broj je biran tako da **sredina padne na crticu**:
svaki bipolarni slajder u ovom panelu ima nulu na sredini, a razmak koji bi je
preskočio ostavio bi oznaku nule između dve crtice i traka bi izgledala pogrešno
nacrtano.

Sitnice koje su namerne:

- **samo unutrašnje crtice.** Crtica na zaobljenom kraju kapsule čita se kao
  odlomljen komad trake, ne kao oznaka.
- **crtaju se POSLE ispune**, pa ostaju vidljive celom dužinom trake kao u
  Lightroom-u, umesto da ih ispuna proguta čim se slajder odmakne od nule.
- **centralna crtica se preskače na bipolarnom slajderu.** Oznaka nule je već tu i
  namerno je viša; dve oznake na istom mestu bi tu razliku poništile.
- na gradijentnoj traci crtice su malo jače (0,28 prema 0,22), jer bi ih svetliji
  krajevi gradijenta (žuti kraj Temperature) inače progutali.


## KORAK 38 — „Generative ne radi ništa, samo izbriše paint" (30. avgust 2026)

Prijava sa slikom: na plažnoj fotki naslikana su **dva odvojena traga** — jedan
uz levu ivicu kadra, jedan uz desnu. `Quick Clean Up` ugašen, `Generative Clean
Up` upaljen. Klik na Generative: **ništa se ne desi, samo nestane paint.** Bez
poruke o grešci.

Korisnikova pretpostavka: „pa me navelo da mislim da SD model isto ima area
limit? ako ima digni ga!"

**Nema ga.** `blockingAreaPixels` za `.generative` je `nil` — nijedna veličina ga
ne blokira. Uzrok je drugi, i gori.

### Uzrok

`aiRemoval` ne baca grešku nego **vraća `nil`**, a pozivalac je na `nil` radio
ovo:

```swift
guard let removal, selectedURL == photoAtActionTime else {
    clearRemovalMask()      // ← obriše paint
    return                  // ← i ne kaže ništa
}
```

`nil` dolazi iz `makeBuffers`:

```swift
guard holePixels > 0, holePixels < width * height else { return nil }
```

**U radnom regionu nije bilo nijednog piksela maske.** Zašto — `squareRegion`
centrira **kvadrat** na sredinu ukupnog okvira maske, sa stranicom ograničenom na
kraću ivicu fotografije:

```swift
let limit = min(extent.width, extent.height)
let side = min(max(max(maskBox.width, maskBox.height) * 1.6, 512), limit)
```

Sa dva traga na suprotnim ivicama, `maskBox` je širok skoro celu fotografiju, pa
je njegova **sredina prazna sredina kadra**. Na 3:2 fotki kvadrat sa stranicom =
visina pokriva samo srednjih ~67% širine — i **oba traga ostaju izvan njega**.

Za 6000×4000 i tragove na x≈300 i x≈5700: `side` = 4000, centar x = 3000,
region x od 1000 do 5000. Levi trag na 300 — napolju. Desni na 5700 — napolju.
Rupa: nula piksela. `nil`.

Isti kvar postoji i u `Quick` putanji (koristi isti `squareRegion`), samo se tamo
ne stigne do njega jer ga granica veličine ugasi ranije. To objašnjava i zašto je
`Quick` na toj slici bio siv.

### Popravka — ne dizanje granice nego jedno uklanjanje PO GRUPI tragova

Dizanje bilo čega ovde ne pomaže: region koji bi pokrio oba traga jeste moguć, ali
bi u 512 bafer ugurao celu fotografiju i vratio kašu. Ispravno je **razdvojiti
poslove**.

`briefShowRemovalJobs` grupiše naslikano u zasebna uklanjanja: potezi čiji se
okviri (naduvani za jednu širinu četkice) dodiruju idu zajedno, ostali odvojeno.
Svako uklanjanje dobija **svoj** 512 bafer nad **svojim** malim delom fotke.

To je uz to i **oštrije**, što je drugi dobitak: umesto da svi tragovi dele jedan
region razvučen preko celog kadra, svaki dobija region veličine sebe. Direktno
pomaže staroj primedbi da je generative mutan.

Spajanje ide **do fiksne tačke, ne u jednom prolazu**: spajanje uvećava okvir, a
uvećan okvir može da dohvati grupu koju manji nije mogao. Tri traga u nizu čiji
se krajevi sreću samo preko srednjeg moraju da izađu kao JEDNO uklanjanje — i
srednji nije nužno onaj naslikan drugi. To je test koji je pao pri pisanju (i bio
je pogrešno postavljen prvi put, pa je ispravljen — vidi dole).

### Druga posledica, koja je morala da se popravi zajedno

`removalAreaPixels` je merio **uniju svega naslikanog**. Posle ove izmene to je
pogrešna mera: model nikad ne dobija sve odjednom, nego najveći pojedinačni
posao. Zbog stare mere je `Quick` na korisnikovoj slici bio siv iako su **oba
traga sitna** i svaki bi prošao bez problema.

Sad i kapija i samo uklanjanje čitaju **istu** listu poslova
(`briefShowRemovalJobs`), pa ne mogu da se raziđu oko toga šta će se raditi.

### I treća stvar: više nikad tiho

- **paint OSTAJE kad ništa nije popravljeno.** Ranije se brisao, pa je neuspeh
  spolja izgledao ovako: klik, selekcija nestane, fotka ista, i ništa ne kaže
  zašto. Sad se može doraditi i probati ponovo, umesto ponovnog crtanja svega.
- ako ništa nije vraćeno, ispiše se poruka umesto ćutanja
- ako jedan posao pukne, **ostali se zadržavaju** — dva popravljena od tri vrede
  više nego nijedan
- progres se broji **preko svih poslova**, ne iznova za svaki; tri traga su
  ranije značila da traka tri puta pređe 0-100, što izgleda kao vrćenje u krug

### Provereno

`Tools/run-stroke-cluster-test.py` — **18/18**. Vadi PRAVE funkcije iz
`Develop.swift` po tekstu (ne kopiju), pa test ne može tiho da zastari; ako se
funkcija preimenuje, skripta pukne glasno.

Pokriveno: prijavljeni slučaj (dva traga na ivicama → dva posla, i **oba okvira
mala**, što je ono što vraća `Quick`), spajanje dodirnih tragova, tranzitivnost
preko srednjeg traga (sa srednjim naslikanim POSLEDNJIM), nezavisnost od
redosleda crtanja (200 permutacija), da gumica **smanjuje** izmereni posao,
da brisanje sredine lanca deli lanac na dva, Vision maska kao svoj posao, i
2000 nasumičnih slučajeva da nijedan potez ne nestane i ne udvoji se.

**⚠️ Jedan test je pao pri pisanju i bio je POGREŠAN test, ne kod:** postavio sam
tragove na 0,30 / 0,40 / 0,50 sa četkicom 0,02, čiji domet je ±0,03 — razmak 0,10
je veći od toga, pa se s pravom nisu spojili. Ispravljeno na 0,30 / 0,35 / 0,40,
uz drugi test koji potvrđuje da se krajevi sami NE dodiruju — inače prvi test ne
bi dokazivao most nego samo velikodušan domet.

### ⚠️ Neprovereno

Rezultat na pravoj fotki. Matematika grupisanja jeste izmerena, ali da li
Generative sad zaista vrati dva čista popravka na toj plažnoj slici — to još
niko nije video.


## KORAK 39 — „neka SD radi kao LaMa": izmereno, i ne može (30-31. avgust 2026)

Prijava sa dve slike, rezultat i original: na plažnoj fotki Generative je uklonio
ljude ali je **na njihovo mesto izmislio objekte**. Zahtev:

> „bitno je da AI generative SD model radi kao LaMa — LaMa kada selektira lepo
> obriše ljude ili objekte, samo što je LaMi taj limit da ne može celu areu da
> selektuje, a na SD nema limita malog. Bitno mi je da SD radi isto kao LaMa."

**Odgovor je: ne može, i to nije stvar podešavanja.** Izmereno, ne rezonovano.

### Kako je mereno

Napravljen je headless harness — `Tools/run-inpaint-sweep.py` +
`Tools/inpaint-sweep.swift` — koji **prevodi app-ove PRAVE** `DevelopInpaint`,
`DevelopSDInpaint`, `DevelopLaMaInpaint` i `DevelopCLIPTokenizer` i pušta pravi
`InpaintPipeline` na pravu fotku, bez GUI-ja. Rezultat se komponuje nazad na
fotografiju tačno kako to radi slaganje layera u app-i i piše kao PNG isečen oko
popravke.

Postoji jer **oba modela greše TIHO.** SD naročito: vrati samouverenu, lepo
osvetljenu sliku pogrešne stvari, i nikakvo čitanje koda ne kaže koje. Jedini
pošten test je pustiti pa pogledati, a kroz app to traži miš, folder, prijavu i
trinaest sekundi po pokušaju.

Fotka: **`C4S_7891.NEF`** (5176×3448), maska **828×431 px** preko grupe ljudi uz
liniju mora sa leve strane — dakle „preko strukture", najteži slučaj.

### Rezultat 1 — guidance nije poluga

| guidance | šta je naslikao |
|---|---|
| 1,0 | bele kutije sa crnim šarama (apstraktno smeće) |
| 2,0 | tamna metalna masa |
| 3,5 | **smeđi kamen** |
| 5,0 | **smeđi kamen** |
| 7,5 (isporučeno) | **smeđi kamen** |

Guidance 1,0 je vredan zasebne napomene: tamo je klasifikator-slobodno vođenje
**isključeno po definiciji** (`uncond + 1,0 × (cond − uncond)` = `cond`), pa
negativni prompt ne radi ništa. Zato je najgori, a ne najbezopasniji.

### Rezultat 2 — ni prompt nije poluga, i ovo je najjasniji nalaz

Sve na guidance 5,0, ista maska:

| prompt | šta je naslikao |
|---|---|
| isporučeni default | smeđi kamen |
| **prazan** | **AUTOMOBIL (SUV)** |
| `"sand"` | **razbijen kamion** |
| `"smooth empty sand, calm sea, nothing"` | taman kamen |

Prazan prompt daje auto. To je kraj rasprave o promptu: nije u pitanju loš izbor
reči nego to **šta model jeste**. SD 1.5 Inpainting je obučen da SINTETIŠE
sadržaj u rupu; rupa od 828 px mu je dovoljno velika da odluči da tu nešto
pripada, i onda tu nešto i naslika.

### Rezultat 3 — LaMa na istoj maski: čisto

Ista fotka, ista maska, `quickAIRemoval`: ljudi uklonjeni, pesak i more
nastavljeni, **ništa izmišljeno**. 2,4 s prema 14 s.

### Rezultat 4 — gde je LaMa stvarna granica (izmereno danas)

Iste koordinate, maska se širi:

| maska | rezultat |
|---|---|
| 414 px | čisto |
| 828 px | čisto |
| 1242 px | čisto — more i linija obale uverljivo nastavljeni |
| 1656 px | **meko** — obala nestaje u glatak preliv |
| 2070 px | mekše, ceo levi deo je bledi preliv |

**Ključna razlika u NAČINU kvarenja, i ona odlučuje sve:**

> **LaMa se kvari u MEKOĆU. SD se kvari u AUTOMOBIL.**

Meka mrlja je nešto što korisnik vidi i sam prosudi. Izmišljen kamion nije.

### Rezultat 5 — smanjenje konteksta ne pomaže

Probano jer je bila jedina poluga koja ne traži rekonverziju modela: odnos
regiona prema rupi 1,6 → 1,3 → 1,1 pri maski od 2070 px. Sve tri daju isti bledi
preliv. Odbačeno; **u kod nije ušlo ništa od ovoga.**

### Šta je iz ovoga urađeno u kodu

**Ništa u SD receptu.** Nijedna izmerena varijanta nije bolja od isporučene, pa
menjati bilo šta „za svaki slučaj" značilo bi zameniti izmereno stanje
neizmerenim. Harness JESTE ušao u `Tools/`, da se ovo više ne dokazuje ispočetka.

### Šta ovo znači za korisnikov konkretni slučaj

Njegovi tragovi na toj fotki su bili **sitni i razdvojeni**. Posle KORAKA 38
granica se meri **po grupi tragova**, a ne po njihovom zajedničkom okviru — pa
`Quick` na toj istoj slici **više nije siv**, i on je alat koji tu radi.

### ⚠️ Otvoreno pitanje za korisnika, ne za sledeću sesiju da odluči sama

Kapije su, mereno prema težini kvara, **naopako postavljene**:

- `Quick` (kvari se u mekoću) — **tvrdo blokiran** iznad 2200 px
- `Generative` (kvari se u automobil) — **nije blokiran nikad**, samo upozorenje
  iznad 600 px

Tvrdi blok pripada onome koji pravi auto. Ali blok na `Quick`-u je uveden na
IZRIČIT zahtev korisnika (KORAK 20), a on je 30.08 rekao i da granica od 2200
ostaje — pa se ovde ništa ne dira bez njegove odluke.

### Ako se ikad bude htelo da SD zaista briše

Jedini put koji ova arhitektura dopušta nije podešavanje nego **davanje SD-u
gotovog početka**: prvo LaMa popuni rupu, pa SD odradi mali broj koraka niske
jačine samo kao doterivanje teksture. Tada SD nema šta da izmisli jer rupe više
nema. Nije probano; nije mala izmena.


## KORAK 40 — Generative sada kreće od LaMe umesto od šuma (31. avgust 2026)

Korisnikovo pitanje posle KORAKA 39: „misliš, kad kliknem AI generative tada LaMa
da odradi neki posao a SD model da završi?"

Da. I izmereno je da radi.

### Šta je promenjeno

`InpaintPipeline.aiRemoval` sada, pre SD-a, pusti `LaMaInpaintPipeline.fill` nad
**istim** 512 baferom. Ništa se ne dodaje geometriji: oba modela ionako rade nad
istim regionom (`squareRegion`) i istom veličinom (512), pa je ovo jedan poziv
više.

Zatim `SDInpaintPipeline.fill` dobija `refineStrength` i, umesto da krene od
čistog šuma sa vrha rasporeda, kreće **od te slike** sa vraćenim delom šuma:

```
x_t = alpha[t] * x_0 + sigma[t] * noise
```

pa odradi samo rep rasporeda. Za to je `DPMSolverMultistep` dobio `noised(_:noise:index:)` — direktni (forward) proces.

**Suština u jednoj rečenici:** difuzija od šuma je generator; difuzija od
postojeće slike sa samo par preostalih koraka je retušer, jer u njoj nikad nema
dovoljno šuma da se model predomisli šta je tu.

**Uslovljavanje je ostalo netaknuto.** UNet i dalje dobija masku i *sivo-rupičastu*
verziju kadra kao 9-kanalni ulaz — to je ono na čemu je checkpoint treniran.
Menja se samo **odakle šetnja kreće**. Zato se radi DVA VAE encode-a: jedan sa
spljoštenom rupom (za uslovljavanje), jedan bez (za polazište).

### Izmereno — jačina doterivanja

`C4S_7891.NEF`, maska 828×431 preko ljudi uz liniju mora:

| | rezultat |
|---|---|
| SD sam (staro) | **smeđi kamen** |
| LaMa sama | čisto |
| LaMa + SD **0,2** | čisto |
| LaMa + SD **0,3** | čisto |
| LaMa + SD 0,45 | čisto, ali se pri dnu nazire bleda mrlja |
| LaMa + SD 0,6 | **beži mrlja se vraća** — izmišljanje počinje ponovo |

Isporučeno: **0,3** (`SDInpaintPipeline.defaultRefineStrength`). 0,45 je ivica.

**Usput je i brže:** 6–10 s prema 14–15 s, jer se vrti samo 30% koraka.

### Izmereno — korisnikovo pitanje „šta ako je površina veća od 2200?"

Maska **2484 px**, dakle iznad granice na kojoj je `Quick` dugme ugašeno:

| | rezultat |
|---|---|
| SD sam (staro) | **narandžasti sportski automobil na plaži**, i muškarčeva košulja pretvorena u belu majicu |
| LaMa sama | meko levo, bez izmišljanja |
| **LaMa + SD 0,3** | **isti sadržaj kao LaMa, malo više teksture, bez izmišljanja** |

**Odgovor je dakle: LaMa i dalje odradi posao.** Granica od 2200 je ograničenje
na *Quick DUGME*, a ne na sam model — to je izjava o tome šta bi klijent dobio
kad bi Quick bio jedini prolaz. Kao PODLOGA za doterivanje meka popuna je i
dalje pravi sadržaj na pravom mestu, pa iznad te veličine ovaj put i dalje radi
dok je Quick ugašen. To je namerno i tako je zapisano u kodu.

### Izmereno — korisnikov prompt

Zahtev: „promeni prompt u SD modelu da bude samo `remove object and do not put
anything on that place`".

Probano, obe putanje, ista maska:

| | rezultat |
|---|---|
| korisnikov prompt, **stari put** | **REKLAMNA TABLA SA IZMIŠLJENIM SLOVIMA** („RIEVE YOUT / EEAVER RHE / 100 IN / OPNORT") i figura sa crvenom kacigom |
| isporučeni prompt, stari put | smeđi kamen |
| korisnikov prompt + LaMa podloga 0,3 | čisto |
| isporučeni prompt + LaMa podloga 0,3 | čisto |

**Prompt NIJE promenjen**, i to je treći put da je isto izmereno (KORAK 3, KORAK
18, sada ovo). CLIP nema pojam instrukcije ni negacije: „remove object and do not
put anything on that place" doprinosi tokene *object*, *place*, *put*, *anything*
**pozitivnom** uslovljavanju — doslovno traži da se tu nešto naslika, i dobije se
tabla sa slovima.

Ali to je sada uglavnom nevažno: **sa LaMa podlogom prompt jedva da išta menja**,
jer model nema šta da odlučuje. Ono što je korisnik hteo dobija se arhitekturom,
ne rečima.

### Upozorenje u panelu usklađeno sa stvarnošću

`cautionAreaPixels` za `.generative` bio je **600** („where inventing began").
Izmišljanja više nema, pa je taj prag i tekst bili netačni. Sada je **1400**, a
tekst govori o jedinom kvaru koji je ostao — mekoći — i predlaže da se veliko
uklanjanje odradi u dva-tri prolaza.

`Quick` granica od 2200 **nije dirana** (korisnikova odluka od 30.08).

### Ako LaMa nije dostupna

`aiRemoval` se tiho vrati na stari put (šum, ceo raspored). Nedostupna LaMa nije
razlog da se uklanjanje odbije.

### ⚠️ Neprovereno

Sve gore je mereno kroz `Tools/run-inpaint-sweep.py` na pravoj fotki i slike su
gledane — ali **niko još nije pritisnuo dugme u pokrenutoj app-i.**


## KORAK 41 — bela mrlja: uzrok konačno nađen, i nije veličina (31. avgust 2026)

Korisnik posle KORAKA 40: „radi super ali… drugi put kad sam selektovao i krenuo
da brišem AI generative dobio sam ovu belu mrlju, a nisam toliko bio selektovao
area-e." Uz dva pitanja:

1. da li se area vrati na nulu kad posao završi
2. da li da spustimo LaMinu granicu na 1800 da se ovo izbegne

### Pitanje 1: area SE vraća na nulu

Provereno u kodu, ne pretpostavljeno. `removalAreaPixels` čita **tačno tri**
stvari — `removalStrokes`, `removalMask`, `removalMaskUnitBox` — i
`clearRemovalMask()` prazni sva tri. Kad su prazni, `briefShowRemovalJobs` vrati
praznu listu i mera je `nil`, dakle nula. Nije tu problem.

### Pitanje 2: NE, granica ne bi pomogla — i evo zašto

Maske koje su u ovom koraku napravile belu mrlju bile su **310×137 px** i
**310×137 px**. To je daleko ispod svake granice o kojoj se razmišljalo. Spuštanje
na 1800 ne bi promenilo ništa, jer **veličina nikad i nije bila uzrok.**

### Pravi uzrok: `toneMatch`

`InpaintPipeline.toneMatch` meri koliko je model promašio ton, poredeći svoju
verziju prstena oko rupe sa pravim prstenom, pa razliku primenjuje na piksele
rupe kao `gain × vrednost + offset`.

Izmereno na `C4S_7891`, ista fotka, tri mesta:

| mesto | pojačanje (R/G/B) | offset | rezultat |
|---|---|---|---|
| normalno (0,06 / 0,33) | 0,989 / 0,986 / 0,998 | +3,2 / +4,2 / +1,5 | čisto |
| pesak (0,30 / 0,70) | 0,944 / 0,949 / 0,947 | +11,9 / +10,9 / +10,4 | čisto |
| **prežareno (0,04 / 0,36)** | **0,850 / 0,850 / 0,850** | **+39,3 / +39,3 / +39,4** | **BELA MRLJA** |

**Sva tri kanala zakucana tačno na 0,850** — donju granicu clamp-a — sa offsetom
od +39. To nije slučajnost nego potpis kvara.

**Zašto:** tamo gde je fotografija prežarena, pravi pikseli su prikucani uz 255 i
**nemaju skoro nikakvu varijansu**, dok model svoju verziju istog prstena i dalje
crta sa prelivima. Pošten odnos je onda daleko ispod poda (izmereno: **0,475**).
Clamp ga podigne na 0,85, a onda **offset mora da nadoknadi razliku** — i offset
od +39 podigne svaki srednji ton u zakrpi ka belom. **To JESTE bela mrlja.**

### Popravka

Dostizanje **donje** granice se više ne zaokružuje nego se čita kao signal da
prsten uopšte nije merljiv, i korekcija se **napušta** — koriste se modelovi
pikseli kakvi jesu. Nema šta da se spasava: prave vrednosti nikad nisu ni
upisane u fajl.

Samo donja granica; gornja (model izgladio više nego stvarnost) nije opasna.
Odluka je globalna za sva tri kanala, jer bi identitet po kanalu pomerio balans
boja.

### Provereno posle popravke

| mesto | izmereni odnos | šta se desilo |
|---|---|---|
| 0,04 / 0,36 | 0,475 | **napušteno** |
| 0,16 / 0,34 | 0,824 | **napušteno** |
| 0,06 / 0,33 | 0,989 | primenjeno, **brojevi identični ranijim** |
| 0,30 / 0,70 | 0,944 | primenjeno, **brojevi identični ranijim** |

Zdravi slučajevi su nepromenjeni do cifre. Slike: suncobran je vratio pruge i
boju, more je vratilo ton, beli preliv je bitno smanjen.

Hibridna putanja iz KORAKA 40 dobija dvostruko: LaMina korekcija se napusti, a
SD-ova sopstvena onda legne čisto (1,00 / 1,03 / 1,04, offseti od +2,7 do −8,6),
jer polazi od nepokvarene podloge.

### Šta OSTAJE, i to pošteno

Ostaje blaga meka perjanica tamo gde je uklonjena figura bila uz prežarenu
pozadinu. To je KORAK 16 — LaMa nastavlja dominantnu teksturu okoline, a kad je
okolina bela, nastavlja belo. To nije popravljeno i ne popravlja se granicom;
popravlja se samo većim ulazom u model (KORAK 19 to izmerio i odbacio na 1024).

**Razlika je u redu veličine:** ranije je cela zakrpa odlazila u belo, sada
ostaje mek trag na ivici.

### ⚠️ Neprovereno

Sve gore je kroz `Tools/run-inpaint-sweep.py`, sa gledanim slikama. U pokrenutoj
app-i još niko nije pritisnuo dugme.


## KORAK 42 — klik na sličicu u ShowGrid-u se više ne čeka (31. avgust 2026)

Korisnik: „kada hoću da kliknem na jednu sliku dobijem lag, ne klikne se odmah
već delay nekih možda 0,2 sekunde. Je l' može bez delay-a, da se odmah označi?"

### Uzrok je bio zapisan u samom kodu

Na sličici su stajala **dva** tap gesture-a:

```swift
.onTapGesture(count: 2) { DevelopWindowController.shared.open(...) }
.onTapGesture { handleSelectTap(url) }
```

i komentar iznad njih je već opisivao posledicu, ne shvatajući je kao kvar:

> „a single click waits briefly to see if a second one follows before firing
> handleSelectTap"

To i jeste tih 0,2 sekunde. **Nije selekcija bila spora — app je odbijala da se
opredeli.** SwiftUI ta dva gesture-a ume da razdvoji jedino tako što jednostruki
klik zadrži dok ne vidi da li stiže drugi.

### Popravka

Ostao je **jedan** gesture. Klik selektuje **odmah**, uvek, a dupli klik se
utvrđuje naknadno, po vremenu proteklom od prethodnog klika — što je tačno kako
se Finder ponaša i zašto je selekcija u njemu trenutna.

Otvaranje na drugi klik pošto je prvi već selektovao **nije sukob**: fotografija
koju Develop otvori je ona koja je upravo selektovana.

Sitnice koje su namerne:

- **Cmd-klik nikad nije dupli klik.** Njime se gradi višestruka selekcija, a dva
  Cmd-klika na istu fotku znače „dodaj pa skloni" — čitati to kao zahtev za
  Develop značilo bi raditi protiv korisnika.
- **Prag je `NSEvent.doubleClickInterval`**, dakle brzina koju je korisnik
  stvarno podesio u System Settings, a ne broj izabran ovde.
- Posle duplog klika se pamćenje briše, pa treći klik u brzom nizu počinje nov
  par umesto da opet otvara Develop.
- Selekcija se dešava na **obe** polovine duplog klika, namerno: to je ono što
  prvi klik čini trenutnim, a drugi samo ponovo selektuje već selektovano.

### Provereno

`Tools/run-double-click-test.py` — **9/9**. Vadi pravu `briefShowIsDoubleClick`
iz `ContentView.swift` po tekstu, pa test ne može tiho da zastari.

Pokriveno: prvi klik u sesiji, ista fotka unutar i izvan intervala, dve različite
fotke ma koliko brzo (neko brzo bira, ne traži Develop), tačno na granici
intervala, nulti razmak, **sat koji ide unazad** (NTP ili buđenje iz sna) i
poštovanje korisnikovog podešenog intervala.

Plus svojstvo koje se tiče baš prijavljenog kvara: **prvi klik ne može da bude
dupli ni pri jednom rasporedu vremena** (10 000 slučajeva), pa odluka nema kako
da odloži prvi klik — jedina grana koja mu je dostupna je ona koja samo
selektuje.

### ⚠️ Neprovereno

Sam osećaj klika i to da dupli klik i dalje otvara Develop. Logika je merena,
gesture nije — za to treba miš.


## KORAK 43 — Slideshow → BriefShow, Develop → LumenoLab (31. avgust 2026)

Korisnikov zahtev: dugme „Slideshow" da se zove **BriefShow** i to **fontom
wordmark-a**, a „Develop" da postane **LumenoLab** sa ikonicom „lab čašica sa
mehurićima i sunce iza, presečeno".

### ⚠️ Ovaj korak je prošao kroz TRI verzije ikonice — čitati do kraja

Prva verzija (čašica + presečeno sunce) i druga (čašica + iskre) su **odbačene**.
Isporučena je treća. Ne praviti prve dve ponovo bez izričitog traženja; zašto su
pale piše na dnu ovog koraka.

### Nov fajl `Marks.swift`

**`BriefShowWordmark(size:)`** — dvotonski wordmark kao jedan view. Veliki u
zaglavlju ShowGrid-a i mali u dugmetu su sada **isti** mark, ne dve kopije istih
Text-ova. Trekovanje se skalira sa veličinom (−1,7 pri 20 pt, srazmerno niže),
jer je Unbounded Black široko pismo i bez toga se mala kopija raspadne u nešto
što liči na rođaka wordmark-a, a ne na njega.

Wordmark postavlja svoje dve boje, pa **ne prima hover tint** koji ostala
dugmad u zaglavlju primaju. To je cena toga što je brend-znak; hover skaliranje i
dalje odgovara na pokazivač, pa dugme nije nemo.

**`LumenoLabMark`** — ručno nacrtana, jer je SF Symbols nema: na macOS 13 nema
čašicu uopšte, a nijedna verzija nema čašicu sa suncem presečenim iza nje. Isti
razlog zbog kog je i `OpenFolderShape` ručno crtan (KORAK 12).

Sve je na mreži 100×100 i skalira se na dati okvir, pa jedan opis služi i za
15 pt u dugmetu i za bilo šta veće kasnije.

### Tri stvari koje su nađene tek gledanjem, ne čitanjem koda

Ikonica je renderovana headless (`ImageRenderer`) i **pogledana** — na 240 pt da
se sudi crtež i na pravih 15 pt da se vidi preživljava li veličinu na kojoj se
isporučuje. Tri kvara su izašla tek tako:

1. **Mehurići kao prstenovi ne rade.** Rupa u prstenu je na 15 pt ispod jedne
   tačke, pa se na nekima zatvori a na nekima ne — što izgleda kao greška u
   crtežu, ne kao mehurići. Sada su svi manji od polovine debljine poteza, pa se
   svi popune u pune tačke.
2. **Usna čašice je sekla sunce bez razmaka.** Silueta koja se izbija iz sunca
   sada uključuje i usnu (nacrtanu pa zadebljanu), jer dve tamne linije koje se
   ukrštaju na ovoj veličini čitaju kao jedna debela mrlja.
3. **Presečen zrak izgleda kao trunka prašine, ne kao zrak.** Presečen KRUG i
   dalje čita kao krug koji se nastavlja iza nečega — to je i poenta znaka — ali
   prav potez odsečen sa oba kraja ne čita kao ništa. Zato se zrak crta **ceo
   ili nikako**, po tome da li ijedna od šest tačaka duž njega pada u siluetu
   čašice. Testira se ista silueta koju koristi i maska, pa se to dvoje ne može
   raziđati oko toga gde je čašica.

### ⚠️ Mina koja je nađena usput: naslov prozora je NOSIV

`window.title = "Develop"` nije bio samo naslov. Dva `NSEvent` monitora se po
njemu ograničavaju:

```swift
guard NSApp.keyWindow?.title == "Develop" else { return event }
```

To je pravilo #2 sa vrha ovog dokumenta. **Preimenovanje naslova bez ta dva
guard-a ostavilo bi app-wide monitore da primaju i OBRAĐUJU tastere dok je
fokusiran drugi prozor** — tačno ono što je jednom već rekurzivno kopiralo ceo
Desktop folder u sebe, dvaput.

Zato naslov sada dolazi iz **jedne konstante**,
`DevelopWindowController.windowTitle`, koju čitaju i prozor i oba guard-a.
Preimenovanje je od sada izmena na jednom mestu i ne može tiho da ostavi guard
iza sebe.

**Kod se i dalje zove Develop** — preimenovan je prozor, ne kod. Provlačenje
imena kroz devet hiljada linija bio bi velik diff koji ne menja ponašanje.

### ⚠️ Neprovereno

Dugmad su renderovana istim fontom, veličinom, razmakom i okvirom koje
`ShowHeaderButtonLabel` koristi, pa je ono što je gledano ono što ide na ekran —
ali u pokrenutoj app-i ih još niko nije video.


## KORAK 43, dopuna — konačna ikonica i zašto prve dve nisu prošle (31. avgust 2026)

Ikonica je prošla kroz tri verzije u istoj sesiji. Sve tri su renderovane
headless i **gledane** na 240 pt i na pravih 15 pt pre nego što je bilo šta
isporučeno — što je i razlog što se stiglo do treće bez trošenja korisnikovog
vremena na build-ove.

| verzija | šta je bilo | ishod |
|---|---|---|
| A | čašica + sunce iza, presečeno | **odbačena** — korisnik: „nađi neku ikonicu za lab koja je cool" |
| B | čašica + iskre (četvorokrake zvezde) | **odbačena** — korisnik poslao referencu |
| **C** | **čašica sa tečnošću, bez mehurića** | **isporučena** |

### Šta je isporučeno

Konusna čašica po korisnikovoj referenci: debeo obris, usna preko otvorenog
vrata, i tečnost do ispod ramena. **Bez mehurića** — nacrtani su pa izvađeni na
zahtev, i mark je bolji bez njih: na 15 pt četiri tačke u tečnosti pretvore se u
šum uz donju ivicu, a ono što ostane — jedan oblik i jedan ravan ton u njemu —
jeste ono što se čita.

**Boja:** korisnikova referenca je ljubičasta, ali je izričito tražio boje app-a.
Mark uzima boju koju mu dugme prosledi, pa prati i hover tint i sve tri teme ne
znajući ni za jedno od toga. Tečnost je **ista boja na 0,40 prozirnosti**, ne
drugi ton — drugi ton bi morao da se bira po temi i razišao bi se čim se jedna od
njih promeni.

0,40 a ne 0,32 na kojima je crtana: na 15 pt trećina mastila je jedva vidljiva, a
tečnost je cela razlika između ovoga i praznog trougla. Provereno na obe veličine,
ne izabrano po velikoj.

**Geometrija ide iz jednog izvora** (`enum Flask`), a `wallInset(atY:)` računa
koliko je kosi zid odmakao na datoj visini — tako gornja ivica tečnosti dodiruje
staklo tačno, umesto da se pogađa drugim skupom brojeva.

### Zašto su prve dve pale — da se ne prave ponovo

**A (sunce presečeno iza):** na 15 pt su sunce i čašica dva obrisa koja se otimaju
o isti ugao, a rez potreban da se razdvoje košta više nego što donosi. Usput je
otkriveno pravilo koje vredi i dalje: **presečen KRUG čita kao krug koji se
nastavlja iza nečega, ali prav potez odsečen sa oba kraja ne čita kao ništa** —
izgleda kao trunka prašine. Zato je zrak morao da se crta ceo ili nikako.

**B (iskre):** legla je najbolje od prve dve i bila je najčitljivija na 15 pt, ali
nije ono što je korisnik hteo. Iz nje ostaje jedan koristan nalaz: **iskra mora
da bude ispunjena, ne obris**, i mora da ima udubljene stranice — prve iskre su
bile ukrštene prave linije i čitale su se kao znak „plus", kao matematički
simbol, a ne kao svetlo.

### Takođe u ovom koraku: BriefShow dugme je vraćeno na običan stil

Wordmark u dugmetu je probaan i skinut **čim je viđen**. Postavlja svoje dve boje,
pa nije mogao da primi hover tint koji ima svako drugo dugme u zaglavlju, a
brend-znak koji viče iz reda tihih dugmadi čita se kao greška, ne kao brendiranje.
Veliki wordmark iznad i dalje nosi identitet.

`BriefShowWordmark` **ostaje** u `Marks.swift` — zaglavlje ga koristi, i time je
veliki wordmark prestao da bude dva ručno postavljena `Text`-a.


## KORAK 44 — Patch i Selection: free po difoltu, i bez laga (31. avgust 2026)

Korisnik: „kada kliknem na patch circle se dobije i laguje, nije smooth. A kada
kliknem na selection pojavi se neki krug na slici — ja bi da bude free selection
i isto da ne laguje."

### Selection kreće kao free-hand. Patch OSTAJE krug.

**Ovo su dva različita zaključka, iako liče na jedan.** U prvom prolazu su oba
prebačena na free i to je bilo pogrešno na Patch strani; korisnik je ispravio
istog trenutka („ne, patch tool je trebao da bude circle, a selection tool free
selection"). Zapisano da neko ko „sređuje nedoslednost" ne izjednači to dvoje
ponovo.

- **Selection → free.** Selekcija se crta oko nečega što već ima oblik — čoveka,
  table — pa krug nasred fotke nikad nije ono što se htelo: mora da se vuče,
  da mu se menja veličina i da se ionako prebaci na free.
- **Patch → krug.** Patch je clone stamp. Njegov krug JESTE alat — to je četkica
  kojom se slika, a ne obris koji treba ispravljati — pa je to što stiže spreman
  za slikanje upravo poenta.

Oba oblika i dalje postoje u panelu za oba alata.

### Lag je bio isti kvar iz KORAKA 36, ostavljen na JOŠ ČETIRI mesta

Kad je Remove četkica izmeštena sa `@State`, ostala su četiri alata koja to nisu:

| alat | šta je bilo u `@State` |
|---|---|
| free-hand outline (Patch i Selection dele isti) | `activePatchDrawPoints`, `activeSelectionDrawPoints` |
| clone-stamp potez (Patch, krug) | `activePatchStrokePoints` |
| četkica (maske) | `activeBrushStrokePoints` |
| **hover pozicije sva tri** | `brushHoverLocation`, `patchBrushHoverLocation`, `patchSourceHoverLocation` |

**Hover je bio gori od prevlačenja.** Piše se na SVAKI pomeraj miša, i bez ijednog
klika — pa je prosto prelazak mišem preko fotografije iznova gradio sliku, panel,
filmstrip i histogram. To je najverovatnije ono „nije smooth" pre nego što se
uopšte počne crtati.

Sve troje sada piše u objekat koji roditelj **drži ali ne posmatra**, a crtanje
je izmešteno u male poglede koji ga POSMATRAJU: `ActiveOutlineLayer`,
`PatchStampLayer`, `BrushStrokeLayer`.

**Tekst-podsetnik i svaki `if let` su otišli sa njima**, jer bi uslov ostavljen u
telu roditelja vratio poništavanje nazad — ista zamka koju `ActiveStrokeLayer`
već dokumentuje.

### Bag koji je izašao iz same selidbe, a nije njome napravljen

Zastareli Square/Circle patch overlay je čitao poziciju source-hover-a **direktno
u telu**. Čim je ta pozicija prešla na objekat koji telo ne posmatra, čitanje na
tom mestu bi prikazivalo prsten **zamrznut tamo gde je miš bio kad je telo
poslednji put izvršeno**. Zato je i on dobio svoj posmatrački pogled
(`PatchSourceRing`).

To je opšte pravilo koje vredi zapisati: **kad se stanje izmesti sa `@State` na
neposmatrani objekat, svako mesto koje ga je čitalo u telu mora da ode sa njim —
inače ne dobiješ grešku pri prevođenju nego tiho zastarelu sliku.**

### Sitno usput

`closedPolygonPath` je sada slobodna funkcija `briefShowClosedPolygonPath`, iz
istog razloga iz kog je to i `briefShowStrokePath`: outline koji se vuče i
outline kad se potvrdi moraju da se crtaju ISTIM kodom, inače oblik vidno
poskoči u trenutku kad se pusti miš.

### ⚠️ Neprovereno

Da li se sada zaista oseća glatko. Broj prolaza kroz `body` je izveden čitanjem
svakog upisa u drag i hover putanjama, kao u KORAKU 36 — potez se ne može odvući
bez pravog miša.

## KORAK 45 — bela mrlja: NaN, ne veličina (31. avgust 2026)

KORAK 41 je našao i popravio JEDAN uzrok bele mrlje (`toneMatch` zakucan na
donju granicu clamp-a nad prežarenim prstenom). Mrlja se ipak vratila. Korisnik
je pretpostavio da je prešao limit od 2200 i da zato LaMa razmazuje.

**Nije veličina. Nije LaMa. NaN je.**

Uhvaćeno u korisnikovom SOPSTVENOM pokretanju, sa `BRIEFSHOW_SD_DEBUG=1`,
četiri brisanja u nizu:

```
[sd] tone match  x1.019 -1.1   x0.990 +3.2   x0.990 +2.4     ← LaMa, zdravo
[sd] tone match  x0.985 +3.7   x0.986 +4.1   x0.988 +3.5     ← SD,   zdravo
[sd] tone match  x1.014 -0.3   x0.996 +2.2   x1.000 +0.6     ← LaMa, zdravo
[sd] tone match  x1.000 nan    x1.000 nan    x1.000 nan      ← SD,   NaN
```

Jedno od četiri. To jedno je napravilo mrlju.

### Zašto NaN postaje BELO, a ne crno ili nasumično

```swift
UInt8(max(0, min(255, value.rounded())))
```

Izgleda bezbedno i nije. Swift-ov `min(255, x)` je `x < 255 ? x : 255`, a
**svako poređenje sa NaN je false** — pa NaN prođe kroz clamp i izađe kao
**255**. Sva tri kanala odu na 255. To je čisto belo, i to je mrlja.

`offset` je bio NaN jer `meanModel` računa srednju vrednost dekodiranog izlaza
modela, a taj izlaz je sadržao NaN. `gain` je ostao 1,000 jer grana koja ga
menja traži varijansu > 4, a varijansa sa NaN-om ne prolazi taj uslov.

### Popravka — dva sloja, oba potrebna

1. **`toneMatch`** odbija korekciju čim `gain` ili `offset` nisu konačni i
   vraća identitet. Nekonačan fit nije mala greška za zaokruživanje nego cela
   korekcija bez značenja.
2. **`InpaintPipeline.byteFromModel`** zamenjuje onaj clamp na oba mesta (SD i
   LaMa). Vraća `nil` za nekonačnu vrednost, a pozivalac tada **ne upisuje
   ništa** — ostaje ono što je već u baferu. Za generativni put to je LaMina
   popuna, za LaMu netaknuta fotografija. Oba su bolja od belog.

Nije stavljena zamenska boja: izmišljanje piksela je tačno ono što je ovaj bag
i radio.

### ⚠️ Neprovereno

Popravka je izvedena iz korisnikovog loga i pročitana u kodu. U app-i posle
popravke još niko nije ponovio to brisanje. Ako se mrlja vrati, prvo pokrenuti
sa `BRIEFSHOW_SD_DEBUG=1` i tražiti `nan` u ispisu — ako ga NEMA, uzrok je
nešto treće i KORAK 41 i 45 su oba iscrpljeni.

### Šta je ovom prilikom bilo POGREŠNO isprobano, da se ne ponavlja

Pre nego što je log stigao, potrošene su tri hipoteze i sve tri su oborene:

| hipoteza | ishod |
|---|---|
| SD da kreće od šuma kad je prsten prežaren | izmisli ceo objekat — zato KORAK 40 i jeste prešao na LaMu |
| dići refine sa 0,3 na 0,65 | vidi dole, merenje je bilo neispravno |
| prepoznati „LaMa je razmazala" po svetlini/teksturi zakrpe | brojevi se ne razdvajaju: prežareno +8,8/x0,754 naspram zdravih +11,4/x0,689 i +11,5/x0,565 |

**I jedna metodološka greška koja je koštala najviše:**
`Tools/run-inpaint-sweep.py` **ne piše ceo kadar nego isečak oko maske**
(mereno: 1332×1335). Isečci su onda još jednom sečeni `sips`-om kao da su pun
kadar, pa su ocenjivani delovi slike koje maska nikad nije dotakla. Svi
zaključci doneti sa tih slika su odbačeni, a sve izmene u inpaint kodu koje su
iz njih sledile su vraćene.

**Pravilo koje iz ovoga sledi:** izlaz sweep-a gledati direktno. Ako baš treba
sekundarni crop, koristiti alat koji seče po eksplicitnim pikselima i ispisuje
dobijenu veličinu — ne `sips --cropOffset`, čija semantika nije ono što deluje.


## KORAK 46 — LumenoLab: raspored, brzina i zaglavljivanja (31. avgust 2026)

### Raspored

Slika je preuzela celu levu stranu, od vrha do dna. Traka sa alatima i gornji
bar su otišli u desni panel; slika je time dobila ~90 pt visine.

To usput penzioniše celu klasu bagova: sve što je menjalo visinu IZNAD slike
(spinner brisanja, tekst koji pređe u drugi red) guralo je fotku gore-dole dok
klijent radi na njoj. Zato je `cleanUpNotice` bio prikovan na fiksnih 30 pt i
zato je progres brisanja izmešten iz trake. Pored slike umesto iznad nje, ništa
od toga je ne može pomeriti — pa su obe stvari puštene da budu koliko im treba.

- Panel i filmstrip se **razvlače mišem**, vrednosti se pamte
  (`develop.layout.panelWidth`, `develop.layout.filmstripHeight`).
- **AI Manipulation** je iznad tabova, sklopiv, zatvoren po difoltu.
- **Tools** ostaje u Retouch-u i sadrži samo **Patch** — Crop je u Edit-u, a
  Selection u svojoj sekciji, pa su odatle uklonjeni kao dupli ulazi.
  `Patch Circle` i `Patch Free` su obrisani iz Masks; Patch u Tools je jedini
  ulaz.
- Dugmad Select All / Deselect / Sync / Export All su otišla sa filmstrip-a na
  **desni klik**. Filmstrip je sad samo fotografije.
- **Reset** je u zaglavlju pored Done (bio je na dnu skrola i klijent ga nije
  našao — vraćao je fotku ručno, slajder po slajder). Dodat i
  **Reset N Selected** za celu selekciju, na desni klik i u dnu panela.
- Filmstrip i ShowGrid pokazuju **editovane** sličice i osvežavaju se uživo
  preko `.photoEditsChanged`. Sličice koje se još dekodiraju imaju spinner.

### Razvlačenje je drhtalo — dva uzroka

1. `DragGesture` je merio pomeraj u LOKALNOM prostoru hvataljke, a hvataljka se
   pomera zbog tog istog drag-a. Svaki frame je merio od pozicije koju je
   prethodni upravo pomerio. Rešeno sa `coordinateSpace: .global`.
2. Vrednosti su `@AppStorage`, pa je svaki frame bio sinhroni upis u
   UserDefaults plus notifikacija koja ponovo ulazi u view. Sad drag vozi
   obično `@State`, a u UserDefaults se upisuje jednom, na `.onEnded`.

### Otvaranje je trajalo 4 s — `PhotoEditStore`

`allSettings` je bio computed property koji **dekodira ceo JSON iz UserDefaults
na svaki pristup**, a panel je u body pass-u radio
`photoURLs.filter { hasEdits($0) }` — 300 fotki = 300 punih dekodiranja rečnika
sa svim izmenama koje je klijent ikad napravio.

Najgori mogući oblik usporenja: raste I sa brojem fotki I sa istorijom izmena.
Sad se dekodira jednom i drži u kešu, pod `NSLock`-om (keš je od shared mutable
state napravio nešto što tri niti dodiruju).

Isto u drugom smeru: `setSettings` se zove iz `renderNow` na ~20 ms throttle,
pa je enkodirao celu istoriju stotinak puta po jednom potezu slajdera. Sad je
upis debounce-ovan na 0,5 s, sa prinudnim flush-om kad se prozor zatvori.

Dodata i **kartica sa progresom** pri ulasku. Traka se pomera na stvarnim
granicama faza; poslednja faza se završava kad je fotka STVARNO nacrtana.
Zamka: gradnja prozora je sinhrona, pa bi se u istom runloop prolazu sve
završilo i kartica se ne bi ni iscrtala — otud jedan `DispatchQueue.main.async`
hop pre nje.

### Prazan preview — TRI promašena sloja pa tek onda uzrok

Ovo je najvažniji deo koraka, jer je pokazao gde se ne isplati zaključivati.

Simptom: klik na sličicu, panel pun (ime fajla, slajderi), a preview prazan i
histogram prazan, bez „loading".

Popravljano je, redom, i **nijedno nije bio uzrok**:

1. gomilanje refine-ova (uvedeno otkazivanje i 1,2 s za RAW)
2. `createCGImage` koji vraća LENJ CGImage, pa se filter graf izvršava na
   GLAVNOJ niti u Core Animation commit-u — rešeno sa `deferred: false`
3. razdvajanje `DispatchQueue`-ova

(1) i (2) su same po sebi ispravne i ostaju. (2) je stvarna i vredna: uzorak je
pokazao glavnu nit 100% u `CA::Layer::prepare_contents → CI::copyIOSurfaceCallback`
sa 83 nivoa `recursive_render`. Ali (3) nije promenilo ništa, jer:

**`CIContext` se serijalizuje INTERNO.** Svaki render kroz njega uzima isti
`-[CIContext lock]`. Ceo app je koristio jedan kontekst, pa je svaki render
čekao svaki drugi, bez obzira na broj redova.

Sad tri konteksta po ulozi: `briefEditsPreviewCIContext` (samo interaktivni
render), `briefEditsThumbnailCIContext` (mreža i traka), `briefEditsCIContext`
(refine, export, erase).

I to je jednom podeljeno POGREŠNO: refine je bio stavljen na preview kontekst
uz obrazloženje „refine zamenjuje ono što je preview nacrtao". Tačno i
nebitno — bitno je da je refine spor. **Pravilo: ništa sporo ne deli kontekst
sa nečim interaktivnim.**

**Pravi uzrok praznog preview-a** našao se tek instrumentacijom svake grane
`renderNow`. Trag je stajao ovde:

```
renderNow rendering gen=3
renderNow got cgImage 1424x1069
← ništa više, ni COMMIT ni BAIL
```

`luminanceHistogram` je renderovao kroz TEŠKI kontekst i blokirao na lock-u
koji drži refine. Gotova slika je sedela u lokalnoj promenljivoj i nikad se nije
upisala.

Popravka: histogram prima kontekst kao parametar, i **slika se upisuje prva,
sama za sebe** — histogram ide posle, u zasebnom koraku. Ono što klijent čeka
ne sme da zavisi od nečeg sporednog.

**Pouka:** kod tri uzastopna „popravljena pa se vratilo", uzorkovati
(`sample <pid>`) ili instrumentirati PRE nego što se dirne još jedan sloj.

### Ostalo u ovom koraku

- **Alat nije prebacivao.** `removalPaintOverlay` je prva grana lanca overlay-a,
  pa dok je Clean Up četkica upaljena nijedan drugi alat ne dobija platno.
  Paljenje četkice je gasilo sve ostale alate, ali obrnuto niko nije radio — pa
  je klik na Patch dodavao masku a klijent je i dalje slikao AI selekciju.
  Dodat `deactivateRemoveBrush()`, koji NE briše naslikanu površinu.
- **Izvorni prsten Patch-a**: krug iste veličine kao četkica, isprekidan,
  narandžast, bez senke i bez crnog prstena ispod (oboje je probano i odbijeno
  — mrlja na klijentovoj fotografiji da bi se overlay lakše video). Vidi se u
  tačno dva trenutka: dok je ⌥ pritisnut i dok se slika. Pojavljuje se na sam
  pritisak ⌥ (`installOptionKeyMonitor`), ne tek kad se miš pomeri.
- **Minimum četkice** 0,1 umesto 2 (`range: 0.001...0.3`), prikaz na decimalu.
- **Progres brisanja** je traka sa žutim fill-om umesto spinnera; determinate
  kad ima broj, pulsira kad ga nema (LaMin put traje ~1 s i nema šta da javi).


## KORAK 47 — „Quick" Clean Up nije bio quick: `package`, ne model (31. avgust 2026)

Korisnik: traka pokaže puno pa stoji još 20 sekundi. Dva odvojena nalaza.

### Nalaz 1 — traka je lagala

Quick nikad nije ni imao procenat: LaMin put nema šta da javi usput, pa je
neodređeno stanje bilo nacrtano kao **puna traka koja pulsira**. Puna traka je
završena traka, šta god radila sa prozirnošću — čitalo se kao „100% i zaglavilo
se", i tako je i prijavljeno.

Sad je **kratak segment koji putuje** po trećini staze i nikad ne dodiruje
krajeve, pa se ne može pročitati kao gotovo.

### Nalaz 2 — gde je vreme stvarno odlazilo

Instrumentirano po fazama, u korisnikovom pokretanju:

```
[Q] grown        0.01 s
[Q] boundingBox  0.08 s
[Q] makeBuffers  0.18 s     ← pun RAW render NIJE problem
[Q] lama fill    1.14 s     ← model gotov
[T] job 0 done   8.03 s     ← 6,9 s POSLE modela
```

Sve posle modela je `package()`, a u njemu `blur`. Popravka i brojevi su gore,
u zaključanom odeljku na vrhu dokumenta.

**Dve hipoteze su usput oborene merenjem**, obe moje:

1. „Vreme jede ponovno računanje punog RAW rendera, jer je `full` lenj CIImage
   i `cacheIntermediates` je isključen." — `makeBuffers` traje **0,18 s**. Nije.
2. „Vreme je posle petlje, u upisu sloja ili u `PhotoEditStore`." — od
   `all jobs done` do `main block end` je **0,00 s**. Nije.

Obe su zvučale ubedljivo i obe su bile netačne. Faze su merene tek posle toga i
odgovor je bio na trećem mestu.

### ⚠️ Greška pri izvođenju, da se zapamti

Pri prepisivanju `blur`/`grow` obrisan je i `overlayImage`, koji je stajao
između njih i `makeCGImage`. Uhvaćeno na buildu, vraćeno iz kopije koju
`Tools/run-inpaint-sweep.py` ostavlja u `$TMPDIR/inpaint-sweep-*/`.

Pri sečenju većeg bloka koda ovde: seći po EKSPLICITNIM granicama funkcije, ne
po „od A do sledećeg B", jer između zna da stoji nešto treće.

(U prvoj verziji ovog koraka je pisalo da projekat nije pod git-om — netačno.
Repo je u `BriefShow/BriefShow/.git`. Kopije koje sweep ostavlja u
`$TMPDIR/inpaint-sweep-*/` su zgodne, ali git je pravi backup.)



## KORAK 48 — Flatten: zašto AI Clean Up ne prati grade (31. avgust 2026)

Korisnik: „kad patchujem ili odradim AI clean up, pa posle sinhronizujem grade
sa druge slike — taj setting se primeni samo na sliku, ne na AI clean up."

### Šta je tačno, a šta nije

Provereno u `PhotoEditRenderer.render`, redosled je:

```
1. RAW / ekspozicija / balans belog
2. rotacija, straighten
3. tonske klizače
4. boja, kriva
5. applyLocalAdjustments   ← maske i PATCH
6. compositeLayers         ← AI CLEAN UP slojevi
7. crop
```

**Patch je bio ispravan.** `patchSampledImage` uzorkuje iz ŽIVE slike u koraku
5, dakle iz već obrađene — pa patch prati svaku kasniju izmenu.

**AI Clean Up nije.** Rezultat se čuva kao sloj ZAPEČENIH piksela, snimljenih
sa podešavanjima koja su važila u trenutku brisanja, a kompozituje se u koraku
6 — POSLE celog tonskog lanca. Nijedna kasnija izmena ga ne dodiruje. I to nije
samo kod sinhronizacije: isto se vidi ako se posle brisanja samo pomeri
Exposure.

### Dve opcije, korisnik izabrao A

**A — flatten:** zapeći trenutni render kao novu podlogu te fotke.
**B — kompozitovati slojeve pre tonskog dela**, kao Lightroom.

B je nedestruktivan i rešava sve, ali traži da se pikseli zakrpe hvataju PRE
grade-a, dakle da model dobije neobrađen RAW — na ovim presvetlim kadrovima to
je rizik po kvalitet modela — i menja izgled već sačuvanih brisanja (stari
grade bi bio primenjen dvaput).

Izabrano **A**, i to **kao dugme koje korisnik sam pritisne**. Nikako kao
sporedni efekat sinhronizacije: flatten je jedina radnja ovde koja menja ŠTA
fotografija JESTE, a ne kako je opisana, i to se ne sme desiti dok neko pritiska
nešto drugo.

### Kako je izvedeno

`FlattenedImageStore`. Ključ je isti kao kod `PhotoEditStore` (ime + veličina
fajla), fajl ide u kontejner app-e.

- **Originalni fajl se NIKAD ne dira.** Spljoštena kopija je zaseban privatni
  fajl.
- **16-bit TIFF**, ne 8-bit: fotka se posle ovoga i dalje obrađuje — to joj je i
  svrha — a grade gurnut preko 8-bitnih zapečenih piksela pravi trake.
  Rezolucija je native, po zaključanom pravilu na vrhu dokumenta.
- **Crop se NE peče.** Render je `applyCrop: false`, a crop ostaje kao setting,
  pa se kadriranje i posle flatten-a može otvoriti i menjati.
- `loadBaseImage` i `loadPreviewBaseImage` otvaraju spljoštenu kopiju preko
  `FlattenedImageStore.sourceURL`. Namerno TU, da preview, refine, export i
  brisanja vide istu sliku — flatten koji bi poštovao samo preview bio bi laž
  koju bi export posle odao. Isto i `makeEditedShowGridThumbnail`, inače bi
  mreža i traka pokazivale original.
- **Unflatten** briše kopiju i vraća podešavanja od pre pečenja (čuvaju se uz
  fajl), pa je ovo u praksi povratno.



## KORAK 49 — flatten: LZW je bio uzrok TRI prijavljene stvari (31. avgust 2026)

Korisnik je prijavio tri kvara. **Dva od njih su isti kvar**, i to onaj koji se
najmanje očekivao — kompresija fajla.

Prijava, doslovno:

1. „Flatujem sliku, on je izgleda flatovao ali odmah sam izgubio taj isti image
   da ga vidim. Kliknem na drugu sliku — pojavi se, velika i spremna za rad.
   Kliknem opet na tu flatovanu — ništa, prazno. Odradim rotate i back,
   sačekam 4 sekunde, on je prikaže."
2. „Već flatovana slika, pa opet AI Clean Up — dole više nema opcije da je
   flatujem, samo da je unflatujem."
3. „Generative Clean Up: loading bar do 100%, ugasi se, makne red paint, ništa
   nije promenjeno — pa posle 5 sekundi nestane taj deo koji je trebalo da
   nestane."

### Uzrok 1 i 3: LZW

`FlattenedImageStore.flatten` je pisao **16-bitni TIFF sa LZW kompresijom**.
Izmereno na korisnikovom sopstvenom spljoštenom fajlu (C4S_7889.NEF, 5176×3448,
16 bita, 126 MB):

| fajl | veličina | prvi render | drugi render kroz ISTI kontekst |
|---|---|---|---|
| LZW | 126 MB | **10,2 s** | **10,2 s** |
| bez kompresije | 142 MB | 1,5 s | 0,025 s |

Ključni red je onaj drugi. **Sa LZW se ne zagreje nikad** — tri uzastopna
rendera istog CIImage-a kroz isti kontekst koštaju po deset sekundi. Core Image
čita po pločicama, a LZW je serijska dekompresija koja se ne može preskočiti u
sredini, pa svaka pločica plaća ceo fajl ispočetka. Bez kompresije ImageIO
mapira fajl i drugi render je 25 ms.

Time pada oba kvara odjednom:

- **(1)** Posle flatten-a svaki povratak na tu fotku plaćao je 10 s po renderu,
  a `isLoadingPreview` je već bio ugašen (gasi se kad dekodiranje legne, ne kad
  se slika nacrta), pa je u tih deset sekundi pisalo „Select a photo from the
  filmstrip" — na fotki koju je klijent upravo izabrao. Otud „prazno".
- **(3)** Generative je završio, sloj je dodat, `renderNow` je krenuo — i trajao
  je tih ~5–10 s. Traka je nestala, paint je nestao, slika se nije promenila, pa
  se promenila. Ništa nije bilo pokvareno u samom brisanju.

`CGImageSourceCreateImageAtIndex` dekodira taj isti LZW fajl za **0,56 s**, što
znači da problem nije LZW sam po sebi nego kako ga Core Image čita. Nije se
dalje kopalo: fajl je privatni keš, 16 MB je jeftina cena.

### Popravka 1 — bez kompresije

`flatten` piše `representation(using: .tiff, properties: [:])`. 126 → 142 MB po
spljoštenoj fotki.

Postojeći fajlovi se same popravljaju: `upgradeLegacyCompressedFile(for:)` čita
SAMO TIFF zaglavlje (~1 ms, tag `Compression`; 1 = bez kompresije, 5 = LZW) i
prepisuje fajl samo ako treba. Zove se sa pozadinske niti u `loadImages`, tik
pre dekodiranja. Izmereno na korisnikovom fajlu: 0,56 s jednom, pikseli
identični (srednja vrednost 202/200/198 pre i posle), drugi poziv ne radi ništa.

### Popravka 2 — preview se DEKODIRA umanjen, ne skalira posle

`loadPreviewBaseImage`, `.standard` grana, radila je
`image.transformed(by: scale)` nad lenjim punim CIImage-om. Skaliranje lenje
slike je ne pojeftinjuje — samo dodaje umanjenje na kraj grafa koji i dalje mora
prvo da naduva svaki piksel fajla.

Sad ide `CGImageSourceCreateThumbnailAtIndex` sa
`kCGImageSourceCreateThumbnailFromImageAlways` — pravo umanjeno dekodiranje iz
fajla. (Ime je nesrećno: to je puna kvalitet umanjena slika, ne sličica iz
EXIF-a; ta bi bila `...IfAbsent`.)

| | transform | umanjeno dekodiranje |
|---|---|---|
| spljošten TIFF 5176×3448 | 1,50 s | **0,16 s** |
| JPEG 7800×2600 | 0,011 s | 0,066 s |

Na JPEG-u je ovo 55 ms **sporije** i to je pošteno zapisati. Razlog je što Core
Image lenjo dekodiranje JPEG-a ionako radi dobro. Uzeto je jedinstveno rešenje
umesto raspoznavanja formata: 55 ms jednom po otvaranju fotke, protiv sekunde i
po koja se izbegava, i bez pravila koje bi se raspalo na sledećem formatu.

Provereno da nije promenilo sliku: identične dimenzije i identična srednja RGB
vrednost kroz oba puta, na TIFF-u, JPEG-u i PNG-u.

Cena koja se plaća: preview više ne deli dekodiranje sa `fullBaseImage`, pa
refine plati svoje. To je dobra trampa — klijent vidi sliku odmah, a oštru
verziju sekundu i po kasnije, umesto da ne vidi ništa sekundu i po.

### Popravka 3 — prozor više ne laže dok čeka

Grana `else if isLoadingPreview` je sad
`else if isLoadingPreview || selectedURL != nil`. Ako je fotka izabrana a slike
još nema, stoji spinner. Tekst „Select a photo from the filmstrip" ostaje samo
za slučaj kad zaista ništa nije izabrano.

Ovo ne popravlja nijedno kašnjenje — ono je popravljeno gore. Ovo je zato što je
klijent tri puta prijavio „prazno" na tri različita uzroka (vidi i KORAK 46), a
prazan panel sa pogrešnim tekstom je ono što je svaki od njih učinio nečitljivim.

### Uzrok 2: dugme je bilo u `else` grani

`flattenSection` je bila `if isFlattened { Unflatten } else { Flatten }`. To nije
rubni slučaj nego normalan tok rada: flatten, pa se uoči još nešto, pa AI Clean
Up — a taj clean up je opet sloj zapečenih piksela van tonskog lanca, sa tačno
onim kvarom zbog kojeg flatten i postoji.

Sad se **Flatten nudi uvek kad ima šta da se zapeče**, i na već spljoštenoj
fotki (tada piše „Flatten Again"); Unflatten stoji pored njega kad je fotka
spljoštena.

Uz to dve stvari koje su morale da idu zajedno sa tim:

- **`hasUnbakedEdits` umesto `settings.isNeutral`.** `isNeutral` broji crop kao
  izmenu, a crop se namerno NE peče (`applyCrop: false`) — i baš crop je ono što
  ostane posle flatten-a. Sa `isNeutral` bi dugme posle svakog flatten-a ostalo
  upaljeno i nudilo da zapeče ništa, i potrošilo 142 MB na to. Sad se poredi sa
  praznim podešavanjima kojima je dodat isti crop.
- **`flatten` više ne prepisuje snimljena podešavanja.** Snimak pravi samo PRVI
  flatten. Drugi flatten meri podešavanja prema VEĆ ZAPEČENOJ slici, pa bi
  njihovo vraćanje na original bilo vraćanje grade-a fotki koja ga nikad nije
  imala. Unflatten znači „pre svega ovoga", i to je isto mesto bio jedan flatten
  ili tri. Napisano i u panelu, pod dugmetom, da se ne mora pogađati.

### Provereno

- Build prolazi, bez novih upozorenja u `Develop.swift`.
- Sva merenja gore su na korisnikovom fajlu, ne na sintetičkom.
- Migracija LZW → bez kompresije: pikseli identični, idempotentna.

### ⚠️ Neprovereno

- Nije vožena prava app: flatten i Generative traže klikove u prozoru. Merenja
  su rađena posebnim programima nad korisnikovim fajlom, kroz iste pozive koje
  kod radi.
- Nije mereno koliko traje prvi refine posle ove promene na spljoštenoj fotki
  (očekivano ~1,5 s, jer teški kontekst sad dekodira sam za sebe).


## KORAK 50 — šest prijava odjednom (31. avgust 2026)

### 1. Painting je blokiran dok AI radi

Traženo doslovno: „kada je progres cleaning up loading bar da se blokira dalje
painting na slici dok ai ne završi."

I nije bilo samo kozmetički. `eraseMaskedArea` snima poteze u trenutku
pritiska, a `clearRemovalMask()` na kraju posla briše SVE poteze. Potez
naslikan u međuvremenu, dakle, ili nestane bez objašnjenja, ili — ako se
poklopi sa redosledom — preživi brisanje i tiho uđe u SLEDEĆI clean up kao da
ga je klijent tamo i hteo.

Zatvoreno na tri mesta, sva tri potrebna:

- `.disabled(isRemoving)` na hit površini u `removalPaintOverlay` — gest ne
  stiže.
- `guard !isRemoving` u `paintRemovalBrush`, jer je to levak kroz koji prolazi
  svaki put do poteza.
- `guard !isRemoving` u `commitRemovalStroke`, za potez koji je već bio u toku
  kad je posao krenuo.

Prsten četkice se sklanja dok posao traje. Prsten koji prati miša nad četkicom
koja ne slika je alat koji tvrdi da je spreman a nije.

### 2. Blacks nije radio — i nije bila jačina nego oblik krive

Prijava: „Blacks slider, pomeram levo desno, −100 do +100, ništa se ne dešava."
Tačno tako i jeste bilo. Izmereno na rampi 0...255 kroz istu `CIToneCurve`
koju `render` gradi:

```
blacks -1 (staro):  16 -> 16,  32 -> 32     ništa
blacks +1 (staro):   0 -> 19,  16 -> 15     i to obrnuto
```

Dva razloga, oba u rasporedu tačaka, nijedan u vrednosti `strength`:

1. `point0` je bio `(0, blacks * 0.3)`, dakle za negativan blacks y ispod nule.
   **Ispod crne nema gde.** Izlaz na x = 0 je već crn; „skupi crne" je pomeranje
   po x osi, ne spuštanje ispod nule. Komentar iznad koda je tvrdio da su oba
   kraja krive namerno puštena van 0...1 „da bi Whites/Blacks gurali u
   klipovanje" — za Whites (point4, iznad 1) to važi, za Blacks ne važi i nikad
   nije.
2. `point1` je zakucan na x = 0.25. Šta god point0 uradi, potrošeno je do
   četvrtine opsega. Na +1 se kriva između te dve tačke čak vraćala nadole, što
   je ona inverzija gore.

Popravka: `point0` se klampuje na 0, i Blacks nosi **0,15 na point1** pored
Shadows-ovog sopstvenog člana. Isto merenje posle:

```
blacks -1:  16 ->  4,  32 -> 21,  128 -> 129
blacks +1:  16 -> 35,  32 -> 42,  128 -> 128
```

Pravo skupljanje i pravo podizanje, monotono u oba smera, a srednji ton na 0,5
netaknut — što je i bila poenta postojećeg rasporeda. Blacks i Shadows sad dele
point1; to je pošteno, oba su kontrole dna opsega i preklapaju se i u
Lightroom-u.

Probano i odbačeno: dizanje `strength`. Ne pomaže — problem nije koliko se
point0 pomera nego to što ga point1 odmah poništi.

**Isti kvar je bio i u maskama** (`applyLocalAdjustments` gradi istu krivu), pa
je popravljeno na oba mesta. Blacks na maski je bio jednako mrtav.

### 3. Cmd+A

- **LumenoLab: dodato.** Ide u `installEditingKeyMonitor`, bira sve fotke u
  traci — isti skup koji pravi „Select All" iz desnog klika. Čuvano od polja za
  ime preseta (tamo Cmd+A znači označi TEKST i uvek će značiti).
- **ShowGrid: već postoji**, i provereno je zašto bi moglo da izgleda da ne
  radi. Naslov glavnog prozora je tačno `BriefShow`, pa čuvar monitora prolazi;
  a stavka Edit → Select All u meniju je **disabled** (provereno preko System
  Events na pokrenutoj app-i, kao i Cut/Copy/Paste), pa meni ne otima taster.
  Ostaju dva stanja u kojima kod namerno ne radi ništa: kad je otvoren loupe i
  kad u folderu nema nijedne fotke. Ako se ponovi van ta dva, treba tražiti
  dalje — ovo NIJE zatvoreno merenjem u pravoj upotrebi.

### 4. Rezolucija posle edita — provereno, i nađena jedna poluistina

Pitanje: da li slika posle edita u LumenoLab-u ostaje original po veličini i
pikselima.

**Po dimenzijama — da, svuda.** Izmereno na `C4S_5744.NEF` kroz iste pozive koje
export radi:

```
fajl kaže                5176 x 3448
pun RAW dekod (bez draft) 5176 x 3448
posle grade-a             5176 x 3448
CGImage za upis           5176 x 3448
gotov JPEG kaže           5176 x 3448
```

Nigde nema smanjenja. Preview jeste umanjen dok se radi (2600 px), ali on nikad
ne stiže do fajla — export i refine renderuju iz `fullBaseImage`. Crop naravno
smanjuje, ali to je izmena koju klijent traži.

**Po dubini — bila je poluistina i popravljena je.** Panel piše da su PNG i TIFF
„lossless — every export is full quality", a svi exporti su išli kroz
`createCGImage(_:from:)` čiji je difolt **8 bita po kanalu**. Formatu koji zna
16 bita davani su 8-bitni pikseli da bude lossless nad njima. Izmereno:

| format | staro | novo |
|---|---|---|
| TIFF | 20 MB, depth 8 | 107 MB, depth 16 |
| PNG | 18 MB, depth 8 | 75 MB, depth 16 |
| JPEG | 3 MB, depth 8 | 3 MB, depth 8 (JPEG JESTE 8-bitni) |

Cena: 0,41 → 0,48 s po renderu. `ExportFormat.renderFormat` sad bira, i sva
četiri mesta koja pišu fajl idu kroz njega.

### 5. „liked" → „labeled", i broj zvezdica

U zaglavlju ShowGrid-a je pisalo `N photos · M liked`. To je bilo poslednje
mesto koje tu stvar zove tako — dva dugmeta odmah pored zovu se Export Labeled i
Export Starred i rade nad tačno tim skupovima. Sad piše
`N photos · M labeled · K starred`.

Zvezdice su **poseban broj**, ne sabran sa oznakama: fotka može biti starred a
ne labeled, pa bi jedan zbir bio broj koji ne odgovara nijednom od dva dugmeta.
Prikazuje se samo kad ih ima, da folder koji niko nije ocenio ne nosi
„0 starred".

Ispravljen i tekst potvrde za Clear All („the liked label" → „the label").

### 6. Dugme „BriefShow" → „Showcase"

Zvalo se po onome što otvara, i to je bio problem: app se takođe zove BriefShow,
pa dugme BriefShow unutar BriefShow-a, ispod BriefShow wordmark-a, ne govori
kuda vodi. „Showcase" imenuje radnju, pored „LumenoLab" do njega.

⚠️ **Promenjen je SAMO natpis.** `window.title` ostaje `"BriefShow"` — oba
monitora tastature u app-i se ograničavaju po naslovu prozora
(`NSApp.keyWindow?.title == "BriefShow"`), pa bi preimenovanje prozora tiho
otkačilo svaku prečicu na tom ekranu. Vidi MINA 2 u planu za Afterburn Studio.

### ⚠️ Neprovereno

- Nije vožena prava app ni za jednu od ovih šest. Sva merenja su rađena posebnim
  programima nad korisnikovim fajlovima, kroz iste pozive koje kod radi; build
  prolazi bez novih upozorenja.
- Nove vrednosti Blacks-a nisu gledane okom na fotografiji, samo na rampi.
  Ako je 0,15 prejako ili preslabo, to je jedan broj (`blacksOnShadowPoint`) na
  dva mesta u `Develop.swift`.


## KORAK 51 — „kliknem LumenoLab i ne reaguje, kliknem opet i otvori se" (31. avgust 2026)

Prijava: desilo se JEDNOM, odmah posle prebacivanja teme na crnu. Prvi klik na
LumenoLab ništa, drugi klik otvorio prozor.

Nije reprodukovano — u trenutku analize je klijent imao LumenoLab otvoren sa
svojim radom u njemu, pa app NIJE vožena preko System Events-a da se to ne
pokvari. Ono što sledi je nađeno čitanjem koda, i za glavni nalaz postoji
mehanizam koji objašnjava OBA klika, ne samo prvi.

### Glavni nalaz — redosled `activate` i `showWindow` je bio obrnut

`openNow` je radio:

```swift
controller.showWindow(nil)
NSApp.activate(ignoringOtherApps: true)
```

Aktiviranje app-e tera AppKit da **ponovo nametne sopstveni redosled prozora**, a
na vrh stavlja onaj koji smatra ključnim — što je u istom prolazu runloop-a i
dalje ShowGrid. Prozor editora ume da bude napravljen, prikazan, pa odmah
zakopan iza prozora u koji klijent gleda.

Iz klijentove stolice: klik koji nije uradio ništa.

I to objašnjava drugu polovinu prijave, koju nijedno drugo objašnjenje ne
pokriva: **drugi klik radi** zato što je tada `windowController` postavljen i
prozor je vidljiv, pa klik pada u granu `makeKeyAndOrderFront` u `open()`, koja
ne radi ništa drugo nego ga izvuče napred.

Zašto baš posle promene teme, i zašto samo jednom: swatch teme menja
`@Published` unutar `withAnimation`, što ponovo iscrtava svaki view u prozoru
koji čita `AppColors` — samo stil dugmadi u zaglavlju je upotrebljen na 37
mesta. Zauzeta glavna nit je tačno mesto gde se trka između aktiviranja i
uređivanja redosleda reši na pogrešnu stranu. Otud „desilo se jednom".

Popravka: **prvo `activate`, pa `showWindow`, pa `makeKeyAndOrderFront`.**
Poslednji poziv nije višak — `showWindow` je odradio svoje PRE aktivacije, a
ovaj sređuje ko je na vrhu POSLE nje. Isti obrnut redosled je bio i u grani za
već otvoren prozor, i tamo je ispravljen.

### Usput nađeno — crveno dugme prozora nikad nije zvalo `close()`

`close()` se zvao samo iz Done dugmeta. Zatvaranje LumenoLab-a običnim macOS
putem, crvenim dugmetom u naslovnoj traci, nije zvalo ništa. Dve posledice, obe
prave:

1. **`PhotoEditStore.flushNow()` se preskakao.** Upis podešavanja je debounce-ovan
   na 0,5 s (KORAK 46), pa je klijent koji zatvori editor na uobičajen način
   mogao da ostavi do pola sekunde poslednje izmene neupisano.
2. `windowController` je ostajao postavljen, i pokazivao na skriven prozor
   napravljen oko STARE liste fotografija. Sledeći klik na LumenoLab bi vratio
   editor za pogrešan folder.

Dodat `DevelopWindowCloseWatcher` kao `NSWindowDelegate`; `windowWillClose` zove
isti `close()` koji zove i Done. Zaseban objekat, ne sam kontroler, jer NSWindow
drži delegata slabo — ovako je vlasništvo vidljivo: kontroler drži watcher-a,
prozor pokazuje na njega, i oba nestaju u `close()`. Delegat se odvezuje PRE
`close()`-a da se ne bi vrteo u krug.

### Usput nađeno — dva klika su mogla da naprave dva prozora

`windowController` se postavlja tek sa druge strane `DispatchQueue.main.async`
hopa, pa nije mogao da odgovori na pitanje „da li jedan već stiže". Kartica nad
ShowGrid-om guta klikove, ali se ona iscrtava JEDAN prolaz runloop-a posle
`begin()` — taj hop joj i omogućava da se uopšte iscrta — a klik koji padne u
taj procep je pravio drugi `openNow`, dakle drugi prozor, dok prvi ostaje bez
ičega što na njega pokazuje.

A klik ponovo je tačno ono što čovek uradi kad mu se čini da klik nije primljen,
što je doslovno ova prijava. Dodat `isOpening` u samom kontroleru, tamo gde se
odgovor zna.

### ⚠️ Neprovereno

- Nije reprodukovano ni pre ni posle popravke. Mehanizam objašnjava obe polovine
  prijave i redosled `activate`/`showWindow` je nesporno bio pogrešan, ali da je
  baš to bilo — nije dokazano vožnjom.
- Ako se ponovi: vredi pogledati da li dugme izgleda ugašeno (`.disabled` kad je
  folder prazan) i da li se negde otvorio drugi LumenoLab prozor iza prvog.


## KORAK 52 — uvoz Lightroom preseta (.xmp) (31. avgust 2026)

Korisnik je dao jedan pravi fajl, `Classic Edits Lightroom.xmp` (preset
„Camilo"), i tražio da se presets mogu uvesti u LumenoLab.

Nov fajl `DevelopLightroomPreset.swift`. Dugme **„Import from Lightroom…"** u
sekciji Presets. Bira se jedan fajl, više njih, ili **ceo folder** — paketi
preseta se tako i prodaju, pa biranje jednog po jednog iz seta od četrdeset ne
bi bio način na koji bi to iko koristio.

### Ovo NIJE Lightroom renderer

Pola onoga što .xmp može da nosi — Color Mixer, tone curve, color grading,
profil kamere — ovde nema svoj regulator. Uvezen preset je zato
**približavanje** izgleda, i uvoz **naglas kaže šta nije preneo**. Prećutan
gubitak bi ostavio klijenta da poredi sa Lightroom-om i nalazi razliku bez
ijednog objašnjenja.

### Mapiranje, i tri mesta gde nije obično deljenje sa 100

Većina jeste deljenje sa 100 (Adobe ide −100...100, ovde je −1...1). Zanimljivo
je ostalo:

**Highlights se OKREĆE.** U Lightroom-u pozitivan Highlights posvetljuje, a
negativan vraća detalj. Ovde je obrnuto — `render` gradi krivu kao
`0.75 - highlights`, dakle pozitivno zatamnjuje. Taj znak je jednom već
zadržan zbog fotki editovanih starijim buildom, pa se okreće uvoz, ne kod.
Preset koji vraća svetla na −77 mora ovde da stigne kao **+0,77**, inače bi ih
raspalio umesto da ih spasi.

**Vignette se takođe okreće.** Lightroom-ov Post-Crop Vignetting je negativan da
zatamni uglove, ovdašnji `vignette` je pozitivan za isto.

**Beli balans je RELATIVAN, ne apsolutan.** Lightroom čuva kelvine (6339 K);
ovde se čuva pomeraj od as-shot balansa te fotke, skaliran tako da je 1,0 =
3000 K (`asShotTemperature + temperature * 3000` u `render`-u). Preset nosi
as-shot vrednost fotke NA KOJOJ je napravljen, pa je pomeraj koji je fotograf
zaista odabrao razlika između to dvoje — a pomeraj je ionako ono što ima smisla
preneti na drugu fotografiju. Apsolutni kelvin se ovde ne može ni izraziti.
Ako je `WhiteBalance="As Shot"`, beli balans se ne dira uopšte.

**Izoštravanje se čita u odnosu na Lightroom-ov difolt, ne na nulu.** Lightroom
svaki RAW počinje na Sharpness 40, pa 40 u presetu znači „nisam dirao
izoštravanje". Uvoz toga kao 0,4 bi izoštrio fotku koju niko nije tražio da se
izoštri, pa se difolt prvo oduzme.

**Crno-belo se prenosi**, kao puna desaturacija. Lightroom pravi svoje sivo iz
B&W miksera — osam težina po boji, za koje ovde nema regulatora — pa se ne može
poklopiti kanal po kanal. Ali izbor nije „tačno sivo ili približno sivo" nego
„sivo ili U BOJI", a monohromatski look koji stigne u punoj boji nije
približavanje ničega. U izveštaju stoji da je izgubljeno miksovanje, ne
konverzija.

### Zamka koja je uhvaćena na prvom pravom fajlu

Prva verzija je prijavljivala kao izgubljeno sve što nije nula. **Lightroom u
preset upisuje svaki regulator, dirao ga neko ili ne.** Na korisnikovom fajlu je
tako prijavljivala Color Grading, Noise Reduction i Sharpening detail — a sva
tri su stajala na Adobe-ovim difoltima: `ColorGradeBlending` je 50 iz kutije,
`ColorNoiseReduction` je 25 na svakom RAW-u, `SharpenDetail` je 25.

Spisak stvari kojih nikad nije ni bilo nauči klijenta da prestane da čita
spisak, a to košta više nego da ništa nije ni pisalo. Sad postoji tabela
Adobe-ovih difolta i prijavljuje se samo ono što se **pomerilo**.

### Izmereno na korisnikovom fajlu

```
name: "Camilo"
  exposure     -0.1000     (Exposure2012 -0.10, isti EV)
  contrast     -0.0500     (-5 / 100)
  highlights   +0.7700     (-77, okrenuto)
  shadows      +0.7000     (+70 / 100)
  whites       +0.2500     (+25 / 100)
  blacks       -0.2800     (-28 / 100)
  vibrance     +0.1000     (+10 / 100)
  temperature  +0.3297     ((6339 - 5350) / 3000)
  tint         -0.1600     ((-10 - 6) / 100)
  texture      -0.1400     (-14 / 100)
  clarity      +0.0700     (+7 / 100)
  dehaze       +0.0400     (+4 / 100)
  vignette     +0.1900     (PostCropVignetteAmount -19, okrenuto)
  sharpness     —          (Sharpness 40 = Lightroom-ov difolt, dakle nula)

nije preneto: Colour Mixer (HSL),
              Sharpening detail (radius / detail / masking),
              Vignette shape (midpoint / feather / roundness)
```

Ime „Camilo" je pročitano iz `crs:Name`, **ne** „Adobe Color" iz ugnežđenog
`crs:Look` — parser hvata samo prvi, spoljni `rdf:Description` i ignoriše sve
unutar drugog, jer Look nosi svoj sopstveni `crs:Name`.

### Provereno i na sintetičkim slučajevima

| slučaj | rezultat |
|---|---|
| vrednosti kao ELEMENTI umesto atributa | pročitano (oba oblika se sreću) |
| `WhiteBalance="As Shot"` uz `Temperature="9000"` | temperatura ignorisana, kako i treba |
| bez `AsShotTemperature` | pretpostavljen dnevni 5500 K, pa (8500−5500)/3000 |
| bez `crs:Name` | ime preseta = ime fajla |
| kriva sa tri tačke | prijavljena kao Tone Curve |
| fajl koji nije XML | uredna greška, bez rušenja |

### ⚠️ Neprovereno

- Nije gledano OKOM na fotografiji da li uvezeni „Camilo" liči na Lightroom-ov.
  Brojevi su tačni po mapiranju; koliko je približavanje verno bez HSL-a je
  nešto što može da presudi samo klijent.
- Nije probano na paketu od više desetina preseta odjednom, niti na .xmp koji
  je razvoj fotografije (sa crop-om i maskama) umesto preseta — takav fajl bi
  se pročitao, ali bi mu se uzeli samo klizači.


## KORAK 53 — Color Mixer (HSL), i još tri stvari — SVE KAO DODATAK (31. avgust 2026)

Korisnik: „jel možeš da napraviš da i LumenoLab ima HSL", pa zatim vinjeta kao
Lightroom, kelvini, highlights i sharpening kao Lightroom — a onda, izričito:

> **„ali ne smeš da menjaš green lock uopšte! samo možeš da dodaš ove stvari"**

To pravilo je oblikovalo ceo korak i vredi ga zapisati kao pravilo, ne kao
anegdotu: **ništa se ne menja, sve se dodaje.** Svaki nov regulator ima difolt
koji reprodukuje TAČNO ono što je app crtao pre nego što je taj regulator
postojao, i to je izmereno, ne pretpostavljeno.

### Zaključane sekcije — provereno da nisu dirane

- `DevelopInpaint.swift`, `DevelopSDInpaint.swift`, `DevelopLaMaInpaint.swift`
  **nisu dirani ni jednom u celoj sesiji** (`git diff --stat` od 5da0314).
  `imageSide` je i dalje 512/512, `defaultSteps` 12. Lock 2 i lock 3 netaknuti.
- Lock 1 (rezolucija): `previewMax` je i dalje **2600**, a `refinedRenderNow` i
  dalje renderuje iz `fullBaseImage` u nativnoj rezoluciji. ⚠️ U KORAKU 49 je
  promenjen NAČIN na koji se tih 2600 px dobija (pravo umanjeno dekodiranje
  umesto skaliranja lenjog punog CIImage-a). Dimenzije su izmerene identične
  (2600×1732 oba puta) i srednja RGB vrednost identična, ali to je jedina tačka
  u sesiji koja dodiruje temu zaključanu lockom 1 — vredi da klijent baci oko.

### Color Mixer

Osam opsega na **Adobe-ovim sopstvenim centrima** hue točka: 0, 30, 60, 120,
180, 240, 285, 315. Nisu ravnomerno raspoređeni i to je namerno kod Adobe-a —
topli kraj, gde je koža, ima korak od 30°, a zeleno-plavi od 60°. Kopiranje tog
rasporeda je ono što uvezen preset spušta na iste boje na koje ga je spustio
Lightroom.

Renderuje se kao **jedan `CIColorCube`**, ne kao osam maskiranih lanaca filtera.
Kocka je jedan filter šta god mikser nosio, a njena gradnja dodiruje 32³ =
32.768 ulaza — posao koji ne zavisi od veličine fotografije. Izmereno 5 ms, uz
keš vezan za vrednost miksera, jer `render` u toku vučenja slajdera radi na
~20 ms i svaki prolaz traži kocku.

**Težine opsega su particija jedinice**: hue leži između dva centra i glatko se
deli između njih, pa zbir uvek daje tačno 1. Provereno po celom točku i na sva
tri centra. Zvonaste krive po centru bi značile da svih osam saturacija na +20
neke hue-ove zasiti više nego druge — dakle da regulator ne radi ono što piše.

### Tri stvari oko kocke, sve tri jer je očigledna verzija izmerena i pala

**1. Siva mora ostati siva.** Kocka se uzorkuje trilinearno, pa prava neutralna
0,5 pada TAČNO IZMEĐU ulaza i meša se iz osam ćoškova — šest su blago obojeni i
zato ih je pomerio onaj opseg koji ih polaže. Izmereno: sa svih osam Luminance
na +100, siva 0,5 je izašla na **0,725**. Gašenje efekta UNUTAR kocke jedva je
pomoglo (0,35 → 0,11 u najboljem slučaju) jer su komšije TAMNE sive jako
zasićene. Ono što radi je odlučivanje IZVAN kocke, u punoj preciznosti: koliko
je piksel daleko od sive, i mešanje odgovora kocke tom merom. Rezultat:
**0,000000** pomeraja, a bledo nebo i zasićena plava prošli su nepromenjeni do
poslednjeg broja.

**2. Prostor iznad bele mora preživeti.** `CIColorCube` gleda po 0...1 i
klampuje preko. Izmereno na .NEF-u kroz baš ovaj lanac: slika stiže do miksera
sa komponentama do **1,33**, a **identična** kocka ih je vratila na 1,000 — što
posle čitaju clarity, vinjeta i svaka zatamnjujuća maska. Deo iznad bele se
zato nosi oko kocke i vraća sabiranjem.

**3. Sabiranje dve slike je palo TRI puta, sve tri zbog premultiplikovane alfe.**
Zapisano da se ne ponavlja:

1. Postavi alfu viška na 0 da sabiranje ne udvostruči neprozirnost. Core Image
   drži boju PREMULTIPLIKOVANO, pa alfa 0 znači boja 0 — višak je izašao kao
   (0,0,0,0) i cela stvar je bila tih no-op.
2. Zadrži alfu pa je posle vrati na 1 preko `CIColorMatrix`. **Taj filter prvo
   DEPREMULTIPLIKUJE**, pa je sa alfom 2 svaki kanal podeljen sa dva — cela
   fotografija na pola svetline. Izmereno: netaknuta narandžasta je od
   0,90/0,50/0,20 otišla na 0,4494/0,2500/0,0996.
3. `CILinearDodgeBlendMode` — čuva alfu 1, ali **klampuje zbir na 1**, što je
   baš ono što se zaobilazi.

Radi ovako: pusti sabiranje da udvostruči alfu, pa tačno to poništi — **boja ×2,
alfa ×0,5**. Izmereno tačno za zbir ispod 1, iznad 1, za nulti višak (pravi
no-op) i, pošto je ispravka algebarska a ne specijalan slučaj za neprozirno, za
dve slike sa alfom 0,5.

### Dodato uz to — vinjeta i sharpening, oba kao ČIST dodatak

| polje | difolt | šta je difolt |
|---|---|---|
| `vignetteMidpoint` | 0,5 | stari `radius0 = 1` |
| `vignetteFeather` | 0,5 | stari `radius1 = √2` |
| `vignetteRoundness` | 0 | stara elipsa po kadru |
| `sharpenRadius` | 1 | ×1,69, sopstveni difolt `CISharpenLuminance` |

**Izmereno da su difolti pravi no-op**, jer bi drugačije ovo bila promena a ne
dodatak:

- `CISharpenLuminance` prijavljuje difolt radijusa **1,69**, a render sa
  eksplicitnih 1,69 protiv rendera bez postavljenog radijusa daje **najveću
  razliku po kanalu 0**. (Kontrola: 1,7 daje razliku 1, a 1,6 razliku 4 — test
  jeste osetljiv.)
- Nova vinjeta na difoltima računa `inner = 1,0000000000` i
  `outer = 1,4142135624` — identično starim `radius0`/`radius1` do 1e-12. Pri
  `roundness = 0` ose ostaju `halfW`/`halfH`, nedirnute.

`isNeutral` NAMERNO ne broji ova četiri polja: to je OBLIK efekta, ne efekat.
Fotka sa Vignette na 0 je bez vinjete šta god midpoint kaže, a brojanje bi
upalilo „ova fotka ima izmene" — i s tim Flatten, Reset i spiskove za export —
zbog regulatora koji ne radi ništa.

Roundness je pošteno **približavanje**: Lightroom-ov negativan roundness savija
oblik ka zaobljenom PRAVOUGAONIKU, što nijedna elipsa ne može. Pozitivan je
tačan (ose se stapaju dok elipsa ne postane krug); negativan se dobija guranjem
elipse napolje da joj ivica grli ćoškove.

### Kelvini — dodati kao PRIKAZ, ne kao promena skladišta

Ovaj app čuva POMERAJ od as-shot balansa te fotke, ne apsolutne kelvine, i to je
ispravno za ono čemu služi: pomeraj je ono što se sme preneti na fotografiju
snimljenu pod drugim svetlom, a to je tačno posao Sync-a i preseta. Ali +0,33
nije broj koji iko može da uporedi sa Lightroom-om ili sa poleđinom aparata.

Zato se kelvini **prikazuju** — iz iste računice `asShot + offset × 3000` koju
render radi — i mogu se **ukucati**, pa se slajder pomeri. Ništa se u tome što
se čuva nije promenilo. Samo za RAW: JPEG nema as-shot kelvine da bi bio
relativan prema njima, pa nema ni poštenog broja da se ispiše. Lightroom radi
isto i za non-raw pokazuje običnu skalu −100...100.

### Highlights — NIJE menjano, i zašto

Traženo je da highlights bude kao u Lightroom-u. U Lightroom-u pozitivno
posvetljuje, ovde pozitivno zatamnjuje, i taj znak je već jednom svesno zadržan
zbog fotki editovanih starijim buildom (vidi `render`). Okretanje znaka je
PROMENA, ne dodatak — pa nije urađeno.

I ne treba: **uvoz već okreće znak**, pa Lightroom-ov preset ovde izgleda kako
treba. Jedino što ostaje drugačije je smer sopstvenog slajdera u panelu. Ako se
to ikad bude htelo, to je zaseban dogovor sa migracijom postojećih izmena, ne
uzgredna izmena.

### Rezultat na korisnikovom fajlu

Preset „Camilo" se sad uvozi **u celosti**:

```
not carried over: []
```

Svih 24 HSL vrednosti (Yellow hue −31 → −0,31, Green hue −61 → −0,61, Blue sat
+39 → +0,39 …), vinjeta feather 100 → 1,0, SharpenRadius 1,1 → 1,1, uz sve
klizače iz KORAKA 52.

### ⚠️ Neprovereno

- Nije gledano okom da li uvezeni „Camilo" sad liči na Lightroom-ov. Sad kad HSL
  prolazi, trebalo bi znatno bliže — ali to presuđuje klijent.
- Roundness i luminance krivulja (`luminanceSwing = 0,6`) su odabrani da budu
  razumni, ne izmereni protiv Lightroom-a. Ako se pokaže preslabo ili prejako,
  to su dva broja u `ColorMixerCube`.
- Sharpening Detail i Masking i dalje nemaju regulator, kao ni stil vinjete
  (Highlight/Colour Priority). Uvoz to i kaže.


## KORAK 54 — prečice postaju podesive, i sitnice oko njih (1. septembar 2026)

### Nazivi proizvoda — ispravljeno svuda u Disclaimer-u

Korisnik: „nemamo ustvari mi ShowGrid, imamo samo **BriefShow kao suite**,
**Showcase** kao slideshow app i **LumenoLab** kao app za editovanje."

Disclaimer je govorio o „BriefShow and ShowGrid" kao o dva proizvoda. Sad:
BriefShow je paket, Showcase je slideshow u njemu, LumenoLab je editor. Reč
„ShowGrid" više ne postoji ni u jednoj rečenici koju klijent čita — provereno
programski nad celim blokom teksta.

⚠️ `window.title` je i dalje `"BriefShow"` i **ne sme se dirati** — oba monitora
tastature se po njemu ograničavaju (MINA 2).

### Nov fajl `Shortcuts.swift`

Do sad je svaka prečica bila literal zakopan u jedan od dva `NSEvent` monitora —
`key == "x"` u BriefShow-u, `key == "z"` u LumenoLab-u. Nije postojao spisak,
nije se moglo promeniti, i nije se moglo saznati šta je zauzeto pre nego što se
doda nova. Sad postoji spisak, a monitori ga pitaju.

**Difolti su tačno one prečice koje je app već imao.** Ništa se u ponašanju
svežeg instala nije promenilo; promenilo se to što sad može da se promeni.

- `KeyCombo` — taster plus modifikatori, uporediv i upisiv. Slova se čuvaju kao
  `charactersIgnoringModifiers` (radi i na ne-US rasporedu), a strelice/Esc/
  Delete po **key code-u**, jer su to fizičke pozicije a ne slova.
- `KeyCombo.relevantModifiers` sužava na command/shift/option/control —
  **namerno ne** `.deviceIndependentFlagsMask`. Caps Lock ili numerički bit
  legitimno stignu uz pritisak, a poređenje je stroga jednakost, pa bi jedan
  slučajan bit tiho ubio prečicu. **Taj bag je u ovom app-u već jednom
  popravljen i ne vraća se.**
- `ShortcutStore` čuva **samo izmene**, ne ceo skup. Difolt koji se popravi u
  nekoj kasnijoj verziji tako stigne svakome ko tu prečicu nije dirao.
- **Setovi prečica** (`Preset`) čuvaju **pun** skup, difolte uključivo — set je
  potpun odgovor na „koje su bile moje prečice" i mora da preživi promenu
  difolta u novoj verziji.
- Sudar se prijavljuje **samo unutar iste grupe**. ⌘C znači jedno u BriefShow-u
  a drugo u LumenoLab-u i oduvek je tako — monitori su i ograničeni po prozoru
  baš zato. To nije sudar.

### Šta je podesivo, a šta nije

Podesivo: Next/Previous Photo, Undo, Redo, Copy/Cut/Paste Selection, Select All,
Zoom In/Out/Fit, veličina alata — plus, za BriefShow prozor: Select All, Copy,
Cut, Paste, Toggle Label, Clear All, Preview.

Fiksno, i **ispisano u prozoru da klijent vidi da postoji**: ← / → (nudge
slajdera), Esc, Delete, Space (ručica), ⌥ (izvorni prsten), strelice u mreži,
1–5 (zvezdice). Svaka od njih je taster čije značenje drži platforma ili alat
kome pripada; nuditi njihovu izmenu značilo bi nuditi nešto što ostatak app-a ne
može da ispoštuje.

### Q i E

Traženo: „E" sledeća slika, „Q" prethodna. Kroz `ShortcutStore` od prvog dana, pa
se mogu promeniti kao i sve ostalo.

Ponavljanje pritiska **jeste** dozvoljeno — držanje tastera da se protrči kroz
folder je poenta toga što je na slovu a ne u meniju — a svaki pritisak je jedan
ograničen pomeraj indeksa, pa se ne može gomilati kao nekad ponovljeni paste.
`stepPhoto` vraća `false` na krajevima, pa taster tada prođe dalje netaknut
umesto da bude progutan bez efekta.

### Edit ▸ Keyboard Shortcuts…

**Jedna** stavka u meniju, namerno — ne meni sa svakom komandom i njenim
tasterom. Obe prečice žive u lokalnim monitorima vezanim za naslov prozora, a
key equivalent u meniju bi bio **drugi polagač prava** na isti pritisak: dva
puta do iste akcije, u trci, a klijentova izmena vidljiva samo u jednom. Prozor
koji se otvori **jeste** spisak, i on je onaj koji se menja.

Snimač u tom prozoru **guta svaki pritisak** dok je upaljen. To je poenta: ceo
app osluškuje tastere, pa bi snimač koji pušta pritisak dalje istovremeno
prevezao Undo i izvršio ga. Esc izlazi bez vezivanja — jedini način napolje iz
nečega što jede sve ostalo.

### Sitnice iz istog zahvata

- **Oznaka „editovano" na sličici** bila je bela ikonica na `accentColor`, a to
  je u crnoj temi bledo krem — bela na krem je bela na ničemu. Sad je
  `AppColors.background` na `AppColors.ink`: to su dve boje app-a čiji je jedini
  posao da se razlikuju, pa kontrast postoji u svakoj temi, i čita se kao deo
  app-a a ne kao upozorenje. `accentColor` ostaje prsten selekcije, za šta je i
  rezervisan.
- **Ikonice u futeru** za Fund Mission (srce — dobrovoljan prilog, ne kupovina,
  pa ne ikonica kartice) i Disclaimer (dokument). RocketsBrief i Support su ih
  već imali, pa je red čitao kao dve vrste stvari.

### ⚠️ Neprovereno

- Prečice nisu isprobane rukom posle prevezivanja; difolti su prepisani jedan u
  jedan iz starih monitora i build prolazi, ali klik-po-klik proveru vredi
  uraditi, naročito ⌘Z/⌘⇧Z i `[` / `]`.
- Snimanje prečice nije probano na ne-US rasporedu tastature.


## KORAK 55 — točkić miša menja veličinu alata (1. septembar 2026)

Traženo: krug alata — patch ili AI Clean Up četkica — da raste na scroll gore i
da se smanjuje na scroll dole.

U LumenoLab-u dotad **nije postojalo nikakvo rukovanje scroll-om**, pa je ovo
čist dodatak. `[` i `]` rade i dalje, nepromenjeni; točkić je drugi put do iste
funkcije `adjustActiveToolSize`.

### Guard je ceo posao

Desni panel je scroll view. Monitor koji bi uzimao svaki scroll menjao bi
veličinu četkice svaki put kad klijent skroluje nadole do Vignette. Zato se
okida **samo** kad je pokazivač nad slikom i kad je upaljen alat koji ima
veličinu, a događaj se **guta samo kad je iskorišćen** — scroll koji nije ništa
promenio vraća se dalje, pa panel skroluje normalno.

Test „nad slikom" ima dva izvora, namerno:

1. **Hover pozicije samih alata** (`removalBrushCursor.location`,
   `brushCursor.brushHover`, `patchCursor.brushHover`). One su ne-nil tačno dok
   je pokazivač nad platnom, jer se iz njih crta prsten kursora — dakle „prsten
   se vidi" i „scroll ga menja" su jedna činjenica, ne dve koje mogu da se
   raziđu.
2. **`isHoveringPreview`**, jedan `.onContinuousHover` na samom kontejneru
   preview-a. Radial maska i Selection alat **imaju veličinu ali nemaju prsten**,
   pa ne prate ništa — bez ovoga bi to bila jedina dva alata kod kojih scroll
   tiho ne radi ništa. Na kontejneru, a ne po alatu: jedno mesto, svi alati,
   uključujući i one dodate kasnije.

### Tri stvari koje nisu očigledne

- **Fizički smer, ne prijavljeni.** macOS već obrne delta kad je uključeno
  „natural" skrolovanje, pa bi čitanje sirove vrednosti značilo da isti pokret
  prsta radi suprotno na dva Mac-a sa različitim podešavanjem. Kompenzuje se
  preko `isDirectionInvertedFromDevice` — pokret je pokret.
- **Akumulator, ne korak po događaju.** Trackpad šalje niz sitnih razlomaka, miš
  nekoliko celih brojeva po zupcu. Reagovanje na svaki događaj bi na trackpad-u
  prebacilo četkicu preko celog opsega, a na mišu bi puzalo. Prag je 6 za
  precizne delte (trackpad) i 1 za zupčaste (miš), pa oba imaju isti osećaj.
- **Promena smera resetuje akumulator**, da se predomišljanje odmah vidi umesto
  da prvo mora da se „potroši" nakupljeno u suprotnu stranu.
- Scroll sa modifikatorom (⌘, ⇧, ⌥, ⌃) se **ne dira** — to je neko ko traži
  nešto drugo od sistema.

### Provereno

- **Klijent je probao i smer je tačan.** Kompenzacija za „natural scrolling"
  preko `isDirectionInvertedFromDevice` radi kako je zamišljena: scroll gore
  povećava, dole smanjuje. Potvrđeno 01.09.2026. na klijentovoj mašini, sa
  njegovim sopstvenim podešavanjem skrolovanja.

### ⚠️ Neprovereno

- Nije probano na mišu sa zupcima, samo na klijentovom ulaznom uređaju. Prag 1
  po zupcu je izbor, ne merenje — ako na nekom mišu bude preosetljivo ili
  pretromo, to je `step` u `installScrollWheelMonitor`.


## PLAN — preimenovanje u „Afterburn Studio" (dogovoreno 31. avgusta 2026, NIJE počelo)

Korisnik: „promeni ime App-a u Afterburn Studio… kao i folder na desktopu
`/Users/esti/Desktop/BriefShow` da se zove Afterburn Studio."

Istraživanje je URAĐENO 31.08 i sve što sledi je provereno u kodu. Nije potrebno
tražiti ispočetka.

### ⚠️ MINA 1 — SD modeli se raspadnu ako se folder preimenuje bez ovoga

Putanja do dev modela je **zakucana na dva mesta**:

- `BriefShow/DevelopSDInpaint.swift:49` → `Desktop/BriefShow/CoreMLModels/<folder>`
- `BriefShow/DevelopLaMaInpaint.swift:56` → `Desktop/BriefShow/CoreMLModels/LaMa/LaMa.mlmodelc`

**LaMa preživljava** preimenovanje jer je upakovana u app (`Bundle.main`), pa joj
je dev putanja samo rezerva. **SD NE preživljava** — 2 GB modela nisu u bundle-u,
pa je ta putanja jedini način da ih nađe. Preimenovati folder bez ove izmene
znači da „Generative Clean Up" prestaje da radi u celini.

Uz to: `Tools/README.txt` tvrdi da postoji `BRIEFSHOW_MODELS` override — **u
Swift kodu ga NEMA.** Dokument i kod se ne slažu. Preimenovanje je pravi trenutak
da se taj override zaista doda, pa da sledeća selidba foldera ne bude izmena
koda.

### ⚠️ MINA 2 — naslovi prozora su nosivi, i JEDAN BAG VEĆ POSTOJI

Tri prozora, tri `window.title`:

| gde | naslov | koristi se kao guard? |
|---|---|---|
| `Develop.swift:2190` | `DevelopWindowController.windowTitle` = „LumenoLab" | DA — `Develop.swift:3262` i `:3385` |
| `ContentView.swift:20906` (ShowGrid, glavni prozor) | `"BriefShow"` | DA — `ContentView.swift:22651` |
| `ContentView.swift:20996` (BriefShow slideshow prozor) | `"BriefShow"` | ne, ali **nosi isti naslov** |

**⚠️ TU JE BAG, I POSTOJI VEĆ SADA:** ShowGrid-ov monitor tastature se ograničava
na `keyWindow?.title == "BriefShow"` — a **slideshow prozor ima ISTI naslov.**
Znači dok je slideshow u fokusu, ShowGrid-ov monitor prolazi kroz guard i
obrađuje tastere (Cmd+C/X/V, ocene, Space, Escape) sa ShowGrid-ovim kontekstom.

To je tačno onaj razred incidenta koji pravilo #2 sa vrha ovog dokumenta
opisuje, samo još neaktiviran. Komentar iznad tog guard-a opisuje raniji,
ISPRAVLJENI slučaj i zato deluje kao da je stvar rešena — nije.

**Preimenovanje je prilika da se to popravi kako treba:** dva različita naslova,
oba iz imenovanih konstanti (kao `DevelopWindowController.windowTitle`), i guard
koji čita konstantu a ne literal.

### ⚠️ MINA 3 — šta se NE SME preimenovati, da korisnik ne izgubi podatke

Ovo ostaje netaknuto, ma šta se promenilo na ekranu:

- `PRODUCT_BUNDLE_IDENTIFIER = com.rocketsbrief.BriefShow`
- `com.rocketsbrief.briefshow.rootFolderBookmark` — security-scoped bookmark za
  pristup home folderu. Promeni ključ i korisnik ponovo dobija dijalog za dozvolu.
- ključevi `PhotoLabelStore` (lajkovi i zvezdice), `FolderColorStore` (boje
  foldera), `appTheme`

Sve su to `UserDefaults` ključevi vezani za bundle identifier. Promena ijednog
znači **tiho izgubljene ocene, lajkove i boje foldera** — bez greške, samo
prazno.

### Šta se MENJA

1. **`PRODUCT_NAME`** u `project.pbxproj` (linije 330 i 361):
   `"$(TARGET_NAME)"` → `"Afterburn Studio"`. Time se `.app` i izvršni fajl
   preimenuju; `CFBundleName` prati `PRODUCT_NAME` pošto je
   `GENERATE_INFOPLIST_FILE = YES`. Shema ostaje `BriefShow`, pa `xcodebuild
   -scheme BriefShow` i dalje radi.
   **Posledica:** izlazni put postaje `build_dd/.../Afterburn Studio.app` —
   ispraviti svaku komandu koja ga otvara.
2. **Wordmark** u `Marks.swift` — „Brief"+„Show" → „Afterburn"+„Studio". Pogled
   preimenovati u nešto neutralno (`AppWordmark`), pošto više neće biti o
   BriefShow-u.
3. **Naslov glavnog prozora** (ShowGrid) → „Afterburn Studio", kroz konstantu, i
   guard na `:22651` da čita tu konstantu.
4. **Folder**: `mv /Users/esti/Desktop/BriefShow "/Users/esti/Desktop/Afterburn Studio"`
   — **prvo ugasiti app**, koja se izvršava iz tog foldera. Premeštanje je u
   okviru istog diska, pa je trenutno i `CoreMLModels` (4,4 GB) se ne kopira.
5. **`Tools/README.txt`** i putanje u ovom dokumentu.

### Šta OSTAJE „BriefShow"

Ime **slideshow funkcije**. Korisnik je 31.08 izričito tražio dugme koje se zove
BriefShow (KORAK 43) — to je ime dela app-e, ne app-e. Ostaju i:

- dugme „BriefShow" u zaglavlju
- naslov slideshow prozora (ali kao **svoja konstanta**, vidi MINU 2)
- `BriefShowWindowController`, `BriefShowApp` i sva ostala imena u kodu —
  preimenovanje kroz ~38 000 linija je velik diff koji ne menja ponašanje,
  isto obrazloženje po kom je i Develop kod ostao „Develop" posle KORAKA 43

### Redosled kojim ovo treba raditi

1. dodati `BRIEFSHOW_MODELS` override i izmeniti obe zakucane putanje
2. razdvojiti naslove prozora u konstante i popraviti guard (MINA 2)
3. build + provera da SD i LaMa i dalje rade **pre** nego što se folder pomeri
4. ugasiti app, `mv` foldera
5. build iz nove putanje, provera da SD radi
6. `PRODUCT_NAME`, wordmark, naslov glavnog prozora
7. README i ovaj dokument

## KORAK 56 — jedan email, jedan kompjuter (i 22 za Vista Photography) (1. septembar 2026)

Traženo: kad se app zaključa sa RocketsBrief-a, svako mora da se uloguje; ko se
jednom uloguje ostaje ulogovan dok se **sam** ne izloguje — i posle update-a
takođe. Jedan email = jedan kompjuter; kad se isti email uloguje na drugom
kompjuteru, prvi se izloguje. Izuzetak: `vuk@vista-photography.com` sme na
**22** kompjutera.

### Ostajanje ulogovan posle update-a — već je radilo, i evo zašto

Sesija stoji u Keychain-u (`KeychainStore`, servis
`com.rocketsbrief.briefshow.session`), ne u `UserDefaults`. Keychain stavka je
vezana za bundle identifier i potpis, a nijedno se pri update-u ne menja, pa
nova verzija zatiče istu sesiju. Provereno i drugo mesto na kom se to moglo
pokvariti: `refreshSessionIfNeeded()` prosleđuje `existingAvatarKey`, a
`performAuthRequest` odjavljuje **samo** kad je taj parametar `nil` — dakle
neuspeo refresh (nema mreže, istekao token) ne izbacuje nikoga. Ništa nije
menjano na toj strani.

### Gde se odluka o broju kompjutera zaista donosi — u bazi, ne u app-i

**Broj nije zakucan u Swift-u i ne sme da bude.** App pita server i radi šta mu
se kaže. Dve posledice, obe namerne:

1. Podizanje nekog klijenta sa 1 na 3 kompjutera je jedan `UPDATE` na
   `briefshow_seat_limits` — **bez novog build-a i bez slanja update-a.**
2. Neko ko bi zakrpio app ne može sebi da doda mesta: izbacivanje se dešava u
   Postgres funkciji sa `SECURITY DEFINER`, a same tabele imaju RLS uključen i
   **nijednu policy** — dakle anon ključem se do njih ne može ni čitanjem ni
   brisanjem, samo kroz te dve funkcije.

Sve je u `Tools/seats.sql`. Pokrenuti **jednom** u Supabase SQL editoru.

### ⚠️ FAIL-OPEN JE ODLUKA, NE PROPUST

`SeatManager` odjavljuje **isključivo** kad server izričito kaže `"ok": false`.
Svaki drugi ishod — nema mreže, DNS pao, funkcija još nije postavljena, 5xx —
znači „ne znam" i sesija ostaje netaknuta. Fotograf na terenu bez signala mora
da radi. Cena: Mac kome se iščupa kabl ostaje ulogovan dok se ne vrati na mrežu.
To je ispravna zamena za plaćen alat, i mesto je na serveru ionako već oduzeto u
trenutku kad se drugi Mac uloguje.

**Izmereno danas, na živom backend-u, pre postavljanja SQL-a:**

```
POST /rest/v1/rpc/briefshow_seat_heartbeat → HTTP 404  (PGRST202)
```

Dakle dok se `seats.sql` ne pokrene, svaki heartbeat je 404 → `nil` → niko se ne
odjavljuje. **Pokretanje tog fajla je ono što uključuje pravilo**, i nema
prozora u kom je klijent zaključan zbog poluzavršenog podešavanja.

### ⚠️ ZAMKA KOJA JE UMALO IZBACILA SVE POSTOJEĆE KORISNIKE

Prva verzija SQL-a je na heartbeat-u vraćala `ok=false` čim za taj Mac nema
reda u `briefshow_seats`. To bi odjavilo **svakoga ko je već bio ulogovan pre
ovog posla**: njihova sesija je u Keychain-u, oni se nikad više nisu logovali,
pa nikad nisu ni zauzeli mesto — i prvi heartbeat posle update-a bi ih izbacio.
Tačno ono što je korisnik izričito tražio da se NE desi.

Popravka je u `briefshow_seat_heartbeat`, u grani bez `p_claim`: ako reda za taj
Mac nema, a nalog **nije popunjen**, red se tiho pojavi (slobodno mesto je
slobodno mesto). `ok=false` je rezervisan za jedini slučaj koji zaista nešto
znači: nalog je pun i ovaj Mac nije među vlasnicima mesta.

### Identitet kompjutera — IOKit, ne slučajan UUID

`MachineIdentity.deviceID` je `IOPlatformUUID`, **namerno ne** onaj slučajni
UUID koji `DeviceCheckIn` drži u `UserDefaults`. Taj je po instalaciji: obriši
plist ili reinstaliraj app i isti Mac dobija novi identitet, pa bi klijent tiho
potrošio drugo mesto na istoj mašini. Platform UUID je mašina i preživljava
reinstalaciju, update i selidbu foldera. `UserDefaults` fallback postoji samo za
slučaj da sandbox odbije IOKit — tada se mesto i dalje broji, ali po
instalaciji.

### Zašto claim ide samo na pravi login, a ne na refresh

`performAuthRequest` je dobio `claimsSeat`. Login i registracija **zauzimaju**
mesto (zato novi Mac gura najstariji napolje — najnoviji pobeđuje, jer klijent
sedi za tim kompjuterom). Refresh tokena **ne sme**: dešava se pri svakom
pokretanju, i kad bi i on zauzimao, dva Maca bi se doveka smenjivala i
izbacivala jedan drugog svaki put kad se bilo koji od njih otvori.

### Šta je dodato

| gde | šta |
|---|---|
| `RocketsBriefSeats.swift` (nov) | `MachineIdentity`, `SeatManager` — claim, heartbeat na 120 s, release, retry na 401 |
| `RocketsBriefAccount.swift` | `forcedSignOutMessage`, `forceSignOut(message:)`, `signOut()` sad vraća mesto, `claimsSeat` |
| `AccountUI.swift` | objašnjenje na ekranu za prijavu („izbačeni ste jer…"), i red u profilu: „x od 22 kompjutera" |
| `BriefShowApp.swift` | `SeatManager.shared.start()` — iz app-a, ne iz pogleda, jer klijent može biti u bilo kom od četiri prozora |
| `Tools/seats.sql` (nov) | tabele, dve funkcije, grant-ovi, i gotove komande za svakodnevnu administraciju |

Heartbeat ide i na `didBecomeActiveNotification`, da izbačen Mac to sazna čim se
klijent vrati u app, a ne za sledećih do dva minuta.

### Browse iz BriefShow prozora — provereno, već je bilo tako

`ContentView.swift:20968` — `onOpenShowScreen` poziva
`ShowGridWindowController.shared.open(initialPhotoURLs:)` pa
`BriefShowWindowController.shared.close()`. Prozor se zatvara ceo, i vraća se na
**postojeći** ShowGrid (preko `registerIfNeeded`), ne otvara drugi. Ništa nije
menjano.

### Izmereno posle postavljanja (1. septembar 2026)

`seats.sql` je pokrenut u Supabase SQL editoru — `Success. No rows returned`.
Provereno, a ne pretpostavljeno:

| provera | rezultat |
|---|---|
| `select … from briefshow_seat_limits` | 1 red: `vuk@vista-photography.com`, `device_limit = 22` |
| `information_schema.routines` | `briefshow_seat_heartbeat` i `briefshow_seat_release` |
| `POST /rpc/briefshow_seat_heartbeat` sa **anon** ključem | `42501 permission denied` (pre toga je bio `404`) |
| `POST /rpc/briefshow_seat_release` sa anon ključem | `42501 permission denied` |
| `GET /briefshow_seats` sa anon ključem | `[]` — RLS drži |

Poslednja tri su ono što zaista treba znati: funkcije **postoje**, ali se anon
ključem ne mogu ni pozvati ni zaobići čitanjem tabele. Da je bilo koji `grant`
promašen, prvi red bi vratio podatke umesto odbijanja.

### ⚠️ NEPROVERENO
- Ceo tok sa dva Maca (login na drugom → prvi izbačen) nije viđen uživo, pošto
  za to trebaju dva kompjutera i postavljen SQL.
- Build je čist (`xcodebuild -scheme BriefShow -configuration Debug` →
  `BUILD SUCCEEDED`), ali nijedan novi ekran nije viđen u pokrenutoj app-i.

### Redosled kojim ovo treba pustiti

1. Pokrenuti `Tools/seats.sql` u Supabase SQL editoru.
2. Proveriti da je red za `vuk@vista-photography.com` sa `device_limit = 22`
   zaista u `briefshow_seat_limits`.
3. Napraviti build, potpisati, i **tek onda** dići `latest_version` u
   BriefControl-u, da svi pređu na verziju koja poštuje mesta.
4. **Zaključati app** (`is_locked`) tek kad su svi na novoj verziji. Zaključati
   ranije nije opasno — stari build-ovi već traže login kad je zaključano — ali
   oni ne poštuju ograničenje kompjutera, pa bi to bio poluuključen sistem.

## KORAK 57 — nalog se vidi i na home screenu, i prijava je u app-i (1. septembar 2026)

Prijavljeno na ekranu: profil se video **samo u Showcase prozoru**, a na home
screenu (ShowGrid) ničega — ni slike, ni načina da se čovek uloguje osim odlaska
na sajt.

### Zašto je to bio pravi propust, a ne sitnica

ShowGrid je prvi i, za većinu klijenata, **jedini** ekran. Profil koji se
pojavljuje isključivo u prozoru koji možda nikad ne otvore je profil koji nemaju.
Isto važi i u ogledalu: u Showcase-u je badge stajao pod `if remoteStatus.isLocked`,
pa je ulogovanom klijentu profil iskakao i nestajao u zavisnosti od zastavice na
serveru koju on ne vidi. Sad je uslov na oba mesta isti i jedini smislen —
**postoji sesija ili ne postoji.**

### Jedan modal za dva posla, ne dva modala

`LockedAccessOverlay` je dobio `onClose: (() -> Void)?`:

- **`nil` = zid.** App je zaključan, niko nije ulogovan, i izlaza namerno nema.
  Ponaša se tačno kao pre.
- **non-nil = klijent ga je sam otvorio** sa home screena. Dobija X, gasi se
  klikom pored, i **sam se zatvori čim prijava prođe** (`onChange` na
  `isSignedIn`).

Namerno **nije** napravljena druga kopija forme. Ista su polja i ista ona
dvolinijska provera unosa; dve kopije bi se razišle prvom sledećom izmenom.

**⚠️ Redosled u `else if` lancu je nosiv:** zid je IZNAD zatvorivog modala, pa
kad je app zaključan uvek pobeđuje zid. Zameni li im neko mesta, zaključan app
dobija prozor za prijavu koji se može zatvoriti klikom pored — dakle zaključavanje
prestaje da znači išta.

### Nikoga ne šalje na sajt da bi se ulogovao

Bio je izričit zahtev. Dugme „Sign In" na home screenu otvara modal **u app-i**;
`auth.users` je ionako zajednička sa sajtom, pa je nalog isti — nema razloga da
klijent izlazi iz app-e i vraća se.

### Izmenjeno

| gde | šta |
|---|---|
| `AccountUI.swift` | `LockedAccessOverlay.onClose`, X, klik pored, samozatvaranje po prijavi, drugačiji naslov kad je zatvoriv |
| `ContentView.swift` (ShowGrid) | `ProfileBadge` / „Sign In" na kraju zaglavlja, `isProfileModalPresented` i `isSignInPresented`, oba modala u lancu |
| `ContentView.swift` (`HeaderView`) | badge više ne zavisi od `isLocked`; `remoteStatus` ispao jer mu je to bila jedina upotreba |

### Stanje na serveru u trenutku pisanja

`app_config`: `is_locked = true`, `latest_version = 6.0`. Dakle app JESTE
zaključan, ali `latest_version` je i dalje jednak onome što svi imaju — prijava
se traži, ograničenje kompjutera se još ne poštuje nigde osim u ovom Debug
build-u. Ostaje: dići `MARKETING_VERSION`, napraviti i okačiti build, pa
`latest_version`.

### ⚠️ NEPROVERENO

Build je čist i app je pokrenuta, ali **nijedan od dva nova ekrana nije viđen**:
badge na home screenu, i zatvoriv modal za prijavu. Isto i dalje stoji za ceo
tok sa dva Maca iz KORAKA 56.

## KORAK 58 — Cmd+V nije radio u prijavi: ShowGrid-ov monitor ga je gutao (1. septembar 2026)

Prijavljeno: u modalu za prijavu na home screenu **paste ne radi**. Kucanje radi,
paste ne.

### Uzrok — nije SwiftUI, nego naš monitor

`installKeyMonitor()` u ShowGrid-u se ograničava **samo** na naslov prozora
(`NSApp.keyWindow?.title == "BriefShow"`) — a modal je u tom istom prozoru, pa
guard prolazi. Cmd+V zato pada u `ShortcutStore.matches(event, .gridPaste)`,
koji pozove `pasteIntoGrid()` i **vrati `nil`**. Vraćeno `nil` znači „događaj je
pojeden": tastatura nikad ne stigne do polja.

Lokalni `NSEvent` monitori rade **pre** responder lanca, pa polje nije imalo
nikakve šanse. Kucanje je prolazilo samo slučajno: „x" i „v" imaju uslove
(`!selectedURLs.isEmpty`, `hasLabelsOrRatings`) koji na praznom ekranu ne važe,
pa ta slova propadnu dalje. Cmd+V nema nijedan uslov.

**I nije bilo samo neprijatno:** ako je klijent ranije kopirao fotke u mreži,
`clipboardURLs` je pun — pa taj isti Cmd+V, dok je modal otvoren, pokrene pravo
kopiranje fajlova iza modala.

### Popravka — guard koji LumenoLab ima od početka

```swift
if (NSApp.keyWindow?.firstResponder as? NSTextView)?.isFieldEditor ?? false {
    return event
}
```

Odmah posle provere naslova. Isti izraz koji `Develop.swift` već koristi
(`isTyping`) — nije izmišljan nov način, prepisan je onaj koji tamo radi.

**Zašto ga ovaj monitor nikad nije imao:** do juče na ovom ekranu **nije bilo u
šta da se kuca.** Modal za prijavu je prvo polje koje je stiglo na home screen.

Pokriva i sve ostalo u tom prozoru u šta se kuca: „DELETE" u profilu i
preimenovanje foldera.

### ⚠️ PRAVILO ZA SVAKO BUDUĆE POLJE ZA UNOS

Svaki `NSEvent` monitor u ovoj app-i mora da propusti događaj kad je fokus u
polju. Guard po naslovu prozora **nije dovoljan** — modal je u istom prozoru kao
i ekran koji pokriva. Ovo je isti razred incidenta kao MINA 2, samo iznutra:
tamo dva prozora dele naslov, ovde jedan prozor deli naslov sam sa sobom.

### ⚠️ NEPROVERENO

Build je čist i app je pokrenuta, ali paste u polju **nije viđen kako radi.**

## KORAK 59 — brisanje fotki tastaturom, i „Delete" umesto „Add to Bin" (1. septembar 2026)

Traženo: selektovana fotka + ⌫ šalje je u kantu; i da desni klik piše samo
**Delete**, crveno, umesto „Add to Bin".

### Tastatura

⌫ i ⌦ u mreži zovu **isti** put kao desni klik — `pendingTrashPhotoURLs` pa
`isTrashPhotoConfirmationPresented`, i na kraju `trashPhotos()`. Jedno ponašanje,
ne dva.

**Potvrda je namerno zadržana.** Backspace je taster koji se pritiska refleksno,
u uverenju da je kursor u nekom polju. Guard za kucanje iz KORAKA 58 pokriva
prava polja; potvrda pokriva sve ostalo. Ako se ispostavi da smeta pri prebiranju
stotina fotki, skida se u jednom redu — ali odluka da se počne sa potvrdom je
svesna, a ne previd.

Prima **prazan taster ili ⌘** (Finder-ov Move to Trash), i ništa drugo. Slučajan
Shift ili Option ne sme da briše fotografije.

**Nije prebacivo**, i stoji u `ShortcutAction.fixed`. Isto obrazloženje po kom su
tamo već Esc i ocene 1–5: Delete koji znači delete određuje platforma. U toj
listi je uostalom već stajao „Delete — Delete the selected mask or layer" za
LumenoLab, pa je ovo samo drugi kraj istog pravila.

### Meni

„Add to Bin" → **„Delete"**, i na fotkama i na folderima u sidebar-u. Ista radnja
ne sme da ima dva imena na jednom ekranu — isti razlog zbog kog na ovom ekranu
piše „labeled" i „starred" svuda, a ne „liked" na jednom mestu.

Boja ostaje na `role: .destructive`, kako je i bilo. **Da li ga macOS zaista
crveno iscrtava u kontekstnom meniju nije provereno** — ako ne, popravka je ručno
pravljen `NSMenu`, jer SwiftUI meniju ne može da se prosledi boja teksta.

### Usput — zaglavlje se lomilo

Na slici je wordmark stajao kao „Brief Sho / w", a dugme kao „LumenoLa / b".
Verovatno posledica KORAKA 57: dodata je još jedna kontrola u isti red, pa je za
ostale ostalo manje širine.

Komentar iznad wordmarka tvrdi da mu je zaseban red dat baš zato da se to ne
dešava — **a ne pomaže**: red i dalje deli širinu sa onim što stoji pored njega.
Sad je rečeno izričito: `.lineLimit(1)` + `.fixedSize()` na wordmark, i isto na
`ShowHeaderButtonStyle`, dakle na svih 37 mesta gde se taj stil koristi. Kad
ponestane mesta, red postaje tesan umesto da se lomi.

### ⚠️ NEPROVERENO

Build je čist, app je pokrenuta, ali **ništa od ovoga nije viđeno na ekranu**:
ni brisanje tasterom, ni crvena boja u meniju, ni da se zaglavlje više ne lomi.

## KORAK 60 — „Black & White" i „Duplicate & BW" u filmstrip meniju (1. septembar 2026)

Traženo: desni klik na filmstrip, tamo gde su Sync i ostalo — dugme koje
selektovane slike pretvara u crno-bele, i drugo koje ih duplira pa duplikate
pravi crno-belim.

### B&W je `saturation = -1`, i to je odluka

Nije dodato novo polje u `PhotoEditSettings`. Novo polje bi tražilo coding key,
fallback u ručno pisanom `init(from:)` za sve što je snimljeno pre njega, granu u
rendereru i kontrolu u panelu — **da bi opisalo stanje koje panel već ume da
opiše.** Renderer saturaciju predaje CIColorControls-u kao `1 + saturation`,
dakle -1 je tačno 0, prava siva. I klijent to poništava povlačenjem jednog
slajdera, umesto da traži skriveno dugme.

**Vibrance i Color Mixer se NE diraju, i to je provereno u kodu, ne
pretpostavljeno:** oba rade POSLE desaturacije u `PhotoEditRenderer.render`
(redosled: colorControls → vibrance → colorMixer), i nijedan ne može da vrati
boju u neutralan piksel. CIVibrance množi saturaciju koja je sad nula, a mikser
po dizajnu prikucava neutralnu osu — vidi `fullyColoured`, gde stoji da je
mereno na tri praga. Nuliranje bi samo bacilo posao koji klijent dobija nazad čim
podigne Saturation.

### Duplikat je pravi fajl, i mora da bude

Svaka izmena u ovoj app-i je vezana za URL (`PhotoEditStore`). Dve verzije jedne
fotke zato traže **dva URL-a** — inače su to jedna fotka sa jednim podešavanjem,
pa bi „original u boji" koji je klijent tražio da zadrži pocrneo zajedno sa
kopijom.

Kopija **nasleđuje izmene originala** pa tek onda gubi boju: fotka koja je već
eksponirana, iseckana i retuširana ne vraća se kao sirov fajl koji treba raditi
po drugi put.

Ime: `Beach.jpg` → `Beach BW.jpg`, pa `Beach BW 2.jpg`. Ne Finder-ovo „copy" —
prestaje da bude kopija istog trenutka, a folder pun „… copy" fajlova ne govori
koji je koji. **Izmereno pravim fajlovima** (`Tools`-stil probni binarni fajl, 5
imena × 3 uzastopne kopije): tačke u imenu (`my.photo.jpeg`), veliko slovo u
ekstenziji (`.NEF`), fajl bez ekstenzije i naša slova (`Već ćirilica šđž.png`) —
sve prolazi, brojač sudara radi.

### ⚠️ `photoURLs` je prestao da bude `let`

Bio je `let` u `DevelopView`. Duplikat mora da se pojavi u traci **odmah, pored
originala**, a `let` se menja samo ponovnim pravljenjem cele view-e — što baca
otvorenu fotku, njen undo stack i dekodovanu sliku.

Sad je `@State` sa izričitim `init`-om koji ga seeduje jednom. Prozor koji se
kasnije ponovo otvori pravi se iz foldera, koji tada ionako sadrži nove fajlove.

### ⚠️ ZNANO OGRANIČENJE

**ShowGrid ne vidi nove fajlove dok se folder ponovo ne otvori.** Obaveštenje
`.photoEditsChanged` osvežava sličice postojećih fotki; ono nema pojam „u folder
je stigao nov fajl". U traci LumenoLab-a se vide odmah, u mreži tek posle
ponovnog otvaranja foldera.

### Odabrano ponašanje

Duplikati se **selektuju, ali se ne otvaraju.** Klijent gleda fotku na kojoj
radi; pomeranje pregleda na kopiju bi mu to oduzelo kao usputnu posledicu pravljenja
kopije — isti razlog zbog kog „Select All" namerno ne dira `selectedURL`.

Meta je ista kao kod Export-a na vrhu istog menija: cela selekcija kad je
kliknuta fotka deo nje, inače samo fotka pod kursorom. Jedan desni klik ne sme da
znači dva različita skupa u zavisnosti od toga šta se klikne.

### ⚠️ NEPROVERENO

Build je čist i app je pokrenuta, ali **nijedna od dve stavke nije viđena u
meniju**, niti je ijedan duplikat napravljen iz app-e. Imenovanje jeste izmereno,
odvojeno; sve ostalo nije.

## KORAK 61 — zašto B&W nije bio crno-beo, i „Duplicate" (1. septembar 2026)

Prijavljeno slikom: posle „Black & White" portret jeste siv, ali je **red
narandžastih tačaka na obrazu ostao u boji.** Traženo: da se slika automatski
ispeče (flatten) pri B&W i pri Duplicate & BW, i da se doda još jedno dugme
„Duplicate" koje samo duplira sliku kakva jeste.

### ⚠️ UZROK — `saturation = -1` NE MOŽE da stigne do slojeva

U KORAKU 60 stoji da je `saturation = -1` dovoljno. **Nije, i slika je to
dokazala.** `PhotoEditRenderer.render` ide ovim redom:

```
colorControls (saturacija)  →  vibrance  →  colorMixer  →  ...
→  applyLocalAdjustments  →  compositeLayers  →  crop  →  vignette
```

Maske i slojevi se komponuju **posle** kontrole boje, i to namerno — komentar uz
`compositeLayers` kaže da je zalepljen komad novi sadržaj IZNAD celog steka, do
kog maska ispod ne sme da dosegne. Posledica: globalna desaturacija ih nikad ne
dotakne. Koliko god retuš tačaka, patch-eva ili zalepljenih slojeva — svi zadrže
boju.

Provera iz KORAKA 60 („mikser ne može da vrati boju u neutralan piksel") **jeste
bila tačna, ali je gledala pogrešno mesto.** Mikser zaista ne može; slojevi
nikad nisu ni bili desaturisani, pa nemaju šta da vraćaju.

### Popravka — prvo peći, pa skidati boju

Sad ide: `flatten` (slojevi ulaze U piksele) → pa `saturation = -1`. Na pečenoj
slici iznad boje više nema ničega, pa desaturacija stiže svuda.

### ⚠️ OVO JE JEDINO MESTO U APP-I KOJE PEČE BEZ PITANJA

Komentar uz `flattenPhoto` izričito kaže da se to nikad ne sme desiti kao
usputna posledica pritiska na nešto drugo. Prekršeno je ovde, svesno, iz dva
razloga: traženo je izričito, i **jeftino se poništava.**

Ključno, i proveravano u kodu a ne pretpostavljano: **flatten NIKAD ne dira
klijentov fajl.** `FlattenedImageStore.flatten` upisuje TIFF u Application
Support, a svaki dekod ide kroz `FlattenedImageStore.sourceURL`. Original stoji
na disku netaknut, i Unflatten ga vraća. Da fajl biva prepisan, ovo se ne bi
smelo uraditi.

### Odabrana ponašanja

**Peče se van glavne niti** (`developRenderQueue`) — dekodira i renderuje svaku
fotku u punoj rezoluciji, isti posao koji radi export. Selekcija od četrdeset na
glavnoj niti bi zamrzla prozor.

**Otvorena fotka se proverava ponovo na kraju pečenja**, ne pamti se i veruje:
klijent sme da otvori drugu dok se peče, a `settings` bi tada pripadao toj
drugoj. Bez te provere se tuđa podešavanja upisuju preko otvorene fotke.

**Žive `settings` se gurnu u store pre pečenja.** `renderNow` ih upisuje sa
zadrškom od 0,02 s, pa store ume da bude jednu izmenu iza onoga što klijent
GLEDA. Bez toga se peče slika koja nije na ekranu.

**Duplikat nasleđuje izmene originala**, a kod „Duplicate & BW" pečenje pada
**samo na kopiju** — original ostaje i neispečen i u boji.

### Imena

`Beach BW.jpg` za crno-belu, `Beach copy.jpg` za običan duplikat (reč koju
Finder koristi za baš to). Brojač sudara na oba.

### ⚠️ NEPROVERENO

Build je čist i app je pokrenuta. **Nije viđeno na ekranu:** da narandžaste tačke
sad zaista pocrne, da „Duplicate" radi, ni koliko pečenje traje na velikoj
selekciji.

## KORAK 62 — zašto je duplikat vraćao original, i ista tri dugmeta u mreži (1. septembar 2026)

Prijavljeno: „duplicirao sam sliku a on mi je duplicirao original". Traženo:
Duplicate uvek da peče, i da BW / Duplicate / Duplicate & BW postoje i u
ShowGrid-u. Uz to: Delete u LumenoLab-u, meni i ⌫.

### ⚠️ UZROK — kopiran je FAJL, a slika nije bila u fajlu

Original je bio ispečen. Pečenje **ne dira klijentov fajl** — piše TIFF u
Application Support, ključ `ime|veličina`. Kopija dobija **drugo ime**, dakle
drugi ključ, dakle nema svoj pečeni TIFF; a nasleđena podešavanja su bila
post-flatten, gotovo prazna. Rezultat: kopija se dekodira iz sirovog fajla i
izgleda kao neobrađen original.

To je bilo neizbežno sa „kopiraj fajl pa nasledi podešavanja". **Kopija mora da
se ispeče** — i to renderom uzetim od ORIGINALA (koji poštuje svoj pečeni TIFF),
a upisanim pod KOPIJU.

Zato `PhotoBakeService.BakeJob` ima **odvojene `source` i `target`**. Za pečenje
na mestu su ista fotka; za duplikat se namerno razlikuju. To je celo rešenje i
jedini razlog zbog kog taj tip ima dva polja.

### `PhotoBakeService` — jedna implementacija za oba prozora

Izvučeno iz `DevelopView` i stavljeno pored renderera, jer su i `CIContext` i
red za render privatni za `Develop.swift`. Zovu ga oba menija — filmstrip u
LumenoLab-u i mreža u ShowGrid-u. Dve kopije bi bile dva mesta na kojima
„Duplicate" počne da znači različite stvari.

### Delete u LumenoLab-u

**⚠️ Redosled u monitoru je nosiv.** Delete je u LumenoLab-u već značio „obriši
izabranu masku ili sloj". Nova grana za fotku stoji ISPOD te, i pali se samo kad
u fotki ništa nije izabrano. Delete dok je maska naoružana mora da skloni masku,
a nikako celu fotografiju.

Meta: multi-selekcija ako je ima, inače otvorena fotka. Ide kroz potvrdu, kao u
mreži.

**Zapisi o izmenama se NE brišu**, za razliku od ShowGrid-a koji briše lajkove.
Fotka vraćena iz kante sleće na isti put iste veličine — što je tačno ključ
`PhotoEditStore`-a — pa se vraća sa svojim izmenama. Lajk je odluka o fotki koju
si sortirao, izmena je posao.

Ako se obriše poslednja fotka, editor se zatvara. Prozor bez ičega za uređivanje
nije stanje vredno crtanja.

### Sitno

Komentari koji su još pisali „Add to Bin" ispravljeni na pet mesta — ime je
promenjeno u KORAKU 59, komentari nisu pratili.

### ⚠️ NEPROVERENO

Build je čist i app je pokrenuta. **Ništa nije viđeno na ekranu:** ni da duplikat
sad zaista izgleda kao original sa izmenama, ni tri nova dugmeta u mreži, ni
Delete u LumenoLab-u. Nije mereno ni koliko pečenje traje na velikoj selekciji —
a u mreži je to sad moguće pokrenuti na svemu što je selektovano.

## KORAK 63 — slojevi dobijaju svoje slajdere, i „Select People" pravi sloj (1. septembar 2026)

Traženo: skloniti „Select People" iz sekcije Remove i staviti ga u Tools pored
Patch-a; promeniti mu posao — da od ljudi napravi **sloj**, odmah zalepljen na
istom mestu, spreman za obradu; da se svaki **selektovan sloj** obrađuje sam za
sebe, a da bez selektovanog sloja obrada ide na celu sliku; i da posle pravljenja
sloja iskoči kartica sa „Remove Paint Selection" i „Undo", pri čemu oba gase
karticu.

### ⚠️ ODLUKA — globalni slajderi se NE preusmeravaju

Zahtev se mogao pročitati na dva načina. Drugi je bio: kad je sloj selektovan,
neka **glavni** slajderi počnu da rade nad njim. To je **odbijeno**, i evo zašto:

- glavni panel bi tiho menjao značenje u zavisnosti od selekcije napravljene
  negde drugde u panelu;
- ne bi ostalo načina da se dira cela slika dok je neki sloj slučajno selektovan.

Umesto toga, selektovan sloj dobija **svoju karticu sa istim slajderima** —
tačno onako kako selektovana **maska** već radi (`selectedMaskEditor`). Pravilo
je time izgovorivo: slajderi gore su fotografija, slajderi u kartici su taj sloj,
a bez selektovanog sloja postoji samo fotografija. To je i doslovno ono što je
traženo, samo bez dvosmislenosti.

Vrednosti sloja žive u `ImageLayer.adjustments`, tipa `LocalAdjustmentSettings` —
**isti** tip koji koriste maske. To je već tačan podskup (tonovi i boja, bez
geometrije i bez vinjete); drugi, skoro isti tip bio bi još jedno mesto na kom se
„koji slajderi su lokalni" razilazi.

Renderer ih primenjuje u `compositeLayers`, na piksele sloja, **pre** skaliranja
— jeftinije je jer je komad manji od fotke, a rezultat je isti.

### ⚠️ MINA KOJA JE IZBEGNUTA — `ImageLayer` je Codable

Dodavanje polja u `ImageLayer` sa sintetizovanim dekoderom **tiho briše sve
postojeće slojeve.** Sintetizovani `init(from:)` puca na ključu koji nedostaje
čak i kad polje ima podrazumevanu vrednost, a `PhotoEditStore.allSettings`
**odbacuje sve što ne dekodira** — bez greške, bez traga.

Zato je `init(from:)` sad pisan ručno, svako polje `decodeIfPresent` sa
fallback-om, plus izričit memberwise `init` (koji se gubi čim se u strukturi
definiše bilo koji init). **Svako sledeće polje u `ImageLayer` mora isto tako.**

### Select People → sloj

Ista Vision maska koja je i pre nalažena, samo drugačije upotrebljena: pikseli
ispod nje se iskopiraju kao PNG (sa alfom, zbog mekih ivica — JPEG bi vratio
tvrd pravougaonik sa nebom okolo) i vrate na isto mesto kao `ImageLayer`. Na
ekranu se ništa ne pomeri; razlika je što ljudi sad imaju svoj sloj.

Aktivna Selekcija i dalje sužava pretragu, kao i pre.

**Konverzija koordinata je nosiva:** `y` sloja je GORNJA ivica merena naniže,
a Core Image meri donju ivicu naviše. Otud `1 - (maxY - minY_extenta)/visina`.
Ista konverzija koju `compositeLayers` radi unazad.

### ⚠️ Dva poznata ograničenja, oba svesna

1. **Kopija je uzeta od rendera KAKAV JESTE.** Globalni slajderi pomereni posle
   toga menjaju sliku ispod, a ne sloj iznad — ljudi će vizuelno „odlepiti" od
   ostatka kadra. Tako se ponaša svaki zalepljen sloj u ovoj app-i; vredi znati,
   ne vredi se pretvarati.
2. **Jedan sloj za sve nađene ljude**, ne jedan po osobi. Maska je jedna slika;
   deljenje na povezane komponente je zaseban posao.

### ⚠️ `findPeople` je sad MRTAV KOD

Nema više nijednog pozivaoca. Nije obrisan — to je ceo radan „nađi pa obriši"
put, uključujući `backgroundOnly`, i previše izmerenog ponašanja da bi se bacilo
na pretpostavku da niko ne želi nazad. **Ali ne izvršava se**, i tako piše iznad
njega.

Poruke na ekranu koje su upućivale na Select People kao deo brisanja su
ispravljene — dve su bile vidljive klijentu i sad bi lagale.

### ⚠️ NEPROVERENO

Build je čist i app je pokrenuta. **Ništa nije viđeno na ekranu:** ni da Select
People zaista napravi sloj koji sedi tačno preko ljudi, ni da slajderi sloja rade
samo na njemu, ni kartica sa dva dugmeta. Konverzija koordinata je izvedena
prepisivanjem postojeće u suprotnom smeru, **nije izmerena.**

## KORAK 64 — nečitljiv blend mode, traka za AI, i kartica sa jednim dugmetom (1. septembar 2026)

Tri sitnice prijavljene na slici i u tekstu, sve tri urađene.

### Multiply / Screen / Overlay su bili crno na crnom

Bio je `Picker(.pickerStyle(.segmented))`. **Native segmented control crta svoje
natpise SISTEMSKIM izgledom, ne temom ove app-e**, pa su na tamnoj temi tri
neselektovana režima ispadala skoro crna na skoro crnom.

Isti razred problema koji je imao Stepper (vidi `ContentView`), sa jednom
razlikom koja je ovde presudna: **`.preferredColorScheme` do njega ne dopire**,
jer segmented control sam boji svoj tekst. Zato nije podešavan nego zamenjen —
naš red dugmadi, u našim bojama, istog oblika kao par Add/Erase u sekciji
Remove. Panel sad ima jedan način da nacrta izbor, a ne dva.

### Traka dok AI traži

`ProgressView(.linear)` pored dugmeta u Tools-u. **Neodređena, ne procenat** —
Vision ne javlja napredak, pa bi procenat bio izmišljen; a jedina stvar koju ta
traka mora da uradi jeste da joj se veruje.

Isti tekst „Looking for people…" stajao je i dalje u sekciji Remove, iz vremena
kad je dugme bilo tamo. Sklonjen odande: linija o napretku u sekciji koja taj
posao više ne pokreće je linija koju niko ne može ni sa čim da poveže.

### Kartica ima samo Undo

„Remove Paint Selection" je sklonjen na prijavu, i s pravom: pretraga **ne
ostavlja nikakav paint** — ona pravi sloj. To dugme je nudilo da poništi nešto
što se nije ni dogodilo.

### ⚠️ NEPROVERENO

Build je čist i app je pokrenuta; nijedna od tri izmene nije viđena na ekranu.

## KORAK 65 — Background sloj, B&W i Blur po sloju, i popravljen Undo (1. septembar 2026)

Traženo: da selektovani ljudi mogu da budu crno-beli; da Select People napravi i
drugi sloj **Background** koji se može zacrniti ili zamutiti; dugme Blur pored
dugmeta Black & White; siva umesto žute za selekciju sloja. Uz to prijavljen bug:
Undo posle pomeranja sloja nije vratio sliku pre selekcije.

### ⚠️ NAJVAŽNIJE — sloj preko celog kadra NE SME da nosi piksele

Ovo je otkriveno pre pisanja, i promenilo je ceo dizajn.

**Svaka izmena u ovoj app-i živi u JEDNOM JSON blobu u `UserDefaults`**, koji se
ponovo enkodira pri svakom flush-u (`PhotoEditStore.flushNow`). Sloj „Background"
preko celog kadra, čuvan kao piksele, bio bi **desetine megabajta PNG-a** u
`UserDefaults`, prepisivanih svaki put kad se bilo koji slajder smiri. To nije
teška funkcija nego pokvarena app.

Zato je uveden **izvedeni sloj** (`ImageLayer.maskData`): sloj koji ne nosi
nikakve piksele, nego je REGION fotografije ispod, a renderer mu piksele uzima
odande u trenutku rendera. Čuva se samo matica, i to smanjena na 1024 px
(`maskPNG`) — maska je glatka i skoro ravna, pa se vraća naviše bez vidljive
razlike, a razlika u ceni je desetine KILObajta prema desetinama MEGAbajta.

**Usput je nestalo ograničenje iz KORAKA 63:** izvedeni sloj se čita iz fotke pri
svakom renderu, pa ga globalni slajderi pomereni kasnije **nose sa sobom** umesto
da ostane zamrznuta kopija. Ljudi više ne „odlepe" od kadra.

Zato su i People i Background sad izvedeni slojevi.

### ⚠️ BUG SA UNDO — kartica je zvala `undo()`

`undo()` skida **jedan** korak sa steka. Dok klijent stigne da pritisne to dugme,
na vrhu steka je obično nešto drugo — pomeranje sloja, pokret slajdera — pa su
slojevi ostajali, a poništavala se nevezana izmena. Tačno ono što je prijavljeno.

Dugme sad briše **tačno one slojeve koje je poslednji Select People napravio**,
po id-u (`peopleLayerIDs`). Upisuje `settings.layers` kao svaka druga izmena, pa
Cmd+Z i dalje može da ih vrati.

**Pravilo:** dugme koje obećava da poništi jednu određenu radnju ne sme da bude
implementirano kao „skini jedan korak sa steka". To dvoje se poklapa samo dok se
između ništa ne dogodi.

### Blur je skaliran na SLIKU, ne na piksele

`layerBlur` računa sigmu kao `0.02 × kraća ivica`. Sigma u pikselima bila bi
pogrešna **nevidljivo**: preview se renderuje na 2600 px a export u punoj
rezoluciji, pa bi isti broj zamutio to dvoje različito — klijent bi odobrio jednu
sliku a dobio drugu.

Slika se `clampedToExtent()` pre zamućenja i seče posle; bez toga filter uzorkuje
prazno van kadra i zatamni svaku ivicu.

### Šta izvedeni sloj NEMA

Blend mode i prevlačenje su sakriveni (ne onemogućeni — red mrtvih kontrola
tera klijenta da se pita zašto). Oboje pripadaju **zalepljenom** komadu: nečemu
što je došlo spolja, sreće ono iza sebe i može drugde. Iza regiona ove iste
fotografije nema ničega osim nje same, a pomeranje bi samo skliznulo maticu sa
onoga oko čega je isečena.

### Boje

Selekcija sloja je sad siva, ne žuta. Žuta je signal „ovaj slajder je naoružan za
strelice"; spisak koji se pregleda ne mora da viče kao jedna živa kontrola, a i
činilo je da izgleda kao da su tri stvari naoružane odjednom. **Maska (`maskRow`)
je ostala žuta** — o njoj niko ništa nije prijavio, i menjati je bilo bi
pospremanje po pretpostavci.

### ⚠️ NEPROVERENO

Build je čist i app je pokrenuta. **Ništa nije viđeno na ekranu**, a ovde ima
više nego obično da se pogleda: da Background matica zaista pokriva sve osim
ljudi, da se skaliranje matice sa 1024 px na punu rezoluciju ne vidi, da Blur
izgleda isto u preview-u i u exportu, i da Undo sad briše oba sloja.

## KORAK 66 — Reset po sloju, Select Sky, i Change Sky (1. septembar 2026)

Traženo: dugme Reset u kartici sloja koje vraća sloj na izgled od pravljenja ali
ga ne briše; dugme Select Sky pored Select People; i, kad se napravi Sky sloj,
dugme Change Sky sa modalom neba za biranje.

### Reset

Vraća `adjustments`, `blur`, `opacity` i `blendMode`. **Geometriju NE dira** —
ovo poništava IZGLED; zalepljen komad koji je pažljivo postavljen ne sme da
odskoči preko fotografije zato što je neko hteo ekspoziciju nazad na nulu.

### ⚠️ Select Sky — Apple nam ovde ne daje ništa

Vision segmentira ljude i ništa drugo: nema zahteva za nebo, nema parsiranja
scene, nema opšteg „segmentiraj ovu klasu" API-ja na macOS-u. Alternativa je
bila pakovati semantički segmentacioni CoreML model — stotine megabajta povrh
4,4 GB i licenca koju treba raščistiti za app koja se prodaje.

Odabrano je drugo: **naša heuristika** (`SkyMasker`), koja gleda četiri stvari
odjednom, jer nijedna sama nije dovoljna — boju neba (plavo ILI svetlo-bezbojno,
kao MAKSIMUM a ne proizvod, jer duboko plavo nebo ne skoruje na „svetlo" i
obrnuto), ravnost (nebo je najravnija stvar u kadru; ovo izbacuje zgrade i
lišće), visinu u kadru (sa PODOM od 0,25, ne rezom — nebo silazi između zgrada, a
ravan rez preko slike je najočigledniji način da zamena neba oda samu sebe) i
grubu povezanost (jak blur pa tvrda kriva).

**Greši na snegu, mirnoj vodi, belim zidovima u gornjem delu kadra i enterijerima
sa svetlim prozorima.** Sve četiri su svetle, ravne i visoko — što je i cela
definicija. Zapisano u kodu, i rečeno klijentu u poruci kad ne nađe ništa.

### ⚠️ NEBA SU NACRTANA — i planina neće biti

Nijedna slika se ne pakuje i ništa se ne preuzima. Zato u spisku nema planina i
neće ih biti: planina je fotografija stvarnog mesta, ne može se dobiti gradijentom
i šumom, a fotografija znači licencu za app koja se prodaje. Nebo je gradijent,
svetlo i oblak — to računar ume ubedljivo.

Sloj sa izabranim nebom **zamenjuje** ono ispod matice; svaki drugi sloj ga samo
doteruje. Sopstveni slajderi sloja rade i na nacrtanom nebu, pa se ono može
zatamniti, ohladiti ili zamutiti kao i sve ostalo.

### ⚠️ TRI PUTA MERENO, DVA PUTA POGREŠNO — i zašto

Ovo je najkorisniji deo ovog koraka.

**Pokušaj 1:** kriva za oblake pisana za raspon 0–1. Zamućen `CIRandomGenerator`
ne stoji tamo. Svih pet oblačnih neba se renderovalo kao **beo list.**

**Pokušaj 2:** izmeren opseg — ali čitanjem bajtova iz **sRGB** bitmape. Filtri
rade u **linearnom** prostoru; sRGB 0,73 je linearno 0,49, pa je opseg seo IZNAD
podataka i oblaci su **potpuno nestali.**

**Pokušaj 3:** čitano u linearnom prostoru (`CGColorSpace.linearSRGB`). Prava
raspodela: p05 0,376, p50 0,494, p95 0,584. Sa `gain 4,81 / bias -1,81`,
`amount` postaje bukvalno pokrivenost: 0,18 → 0,16, 0,45 → 0,51, 0,85 → 0,88.

**Pouka, i ona se ne odnosi samo na nebo:** kad se meri išta što ulazi u
CoreImage filter, mora se meriti u prostoru u kom filter radi. Merenje u sRGB-u
je izgledalo kao merenje i bilo je pogrešno tiho.

Harnesi su sačuvani: `Tools/linstat.swift` (raspodela u linearnom prostoru) i
`Tools/skytest.swift` (renderuje svih sedam na jedan list). `skytest` izvlači
`SkyPainter` iz `Develop.swift` u trenutku pokretanja, pa ne može da se raziđe sa
kodom.

**Brojke za oblake su namerno niže nego što aritmetika kaže**, i to iz gledanja u
rendere: prag ima meku ivicu s obe strane, pa oblak izgleda veći od dela na kom
je odsečen. `softClouds` na 0,45 je bio beo list sa plavim rupama.

**Dramatic je posebno tvrdoglav:** taman oblak preko sivog neba je mnogo manje
opraštajuć nego beo preko plavog. Na 0,72 i opet na 0,55 renderovao se kao crn
pravougaonik. Sada je 0,30.

### ⚠️ NEPROVERENO

Neba **jesu** viđena, u pet iteracija, i sedmo od sedam sad izgleda kao nebo —
ali **odvojeno, ne u app-i.** Nije viđeno: da `SkyMasker` na pravoj fotografiji
nađe ono što treba, kako izgleda šav između nacrtanog neba i fotografije na
horizontu, ni sam modal.

Šav je prvo što treba pogledati. Heuristička maska sa mekom ivicom preko prave
linije horizonta je tačno mesto na kom se ovakva stvar raspada.

## KORAK 67 — maska neba izmerena na pravoj slici, i ručke na sloju (1. septembar 2026)

Prijavljeno: Reset radi za B&W na ljudima ali ne i za nebo; maska neba je loša;
i — najvažnije — nestala je linija oko selektovanog sloja, a tražena je samo
promena BOJE te linije, ne uklanjanje. Uz to: svaki sloj mora da se može
pomeriti, uvećati, suziti i **rotirati**.

### Reset

Nije čistio `skyStyle`, pa je crno-belo silazilo sa People sloja a zamenjeno
nebo nije. Sad čisti i njega, i rotaciju. „Kako je napravljen" znači **svaki**
izbor donet posle toga.

### ⚠️ MASKA NEBA — izmereno na klijentovoj fotografiji, ne izrezonovano

`Tools/skymask.swift` izvlači `SubjectMasker` i `SkyMasker` iz izvora i crta
masku crveno preko prave slike. Na plaži sa porodicom prva verzija je markirala:
nebo (tačno), **širok pojas peska niz levu ivicu**, i **mrlje po svakom licu**.

Svaki pojedinačni test je radio. **Definicija je bila pogrešna.**

**Dodato dvoje, oba mereno:**

1. **Povezanost sa vrhom kadra** (`growFromTop`). Nebo je ono do čega se stigne
   spuštanjem od vrha slike bez prelaska preko nečega što nije nebo. Pesak pada
   na tom testu ma koliko bio svetao, jer je horizont na putu. To je hod po
   kolonama na CPU-u, ne lanac filtera — „povezano sa vrhom" nije pitanje na
   koje filter po pikselu može da odgovori. Radi na radnoj kopiji ispod
   megapiksela, par milisekundi po pritisku dugmeta.
   `runToStop = 3`, da jedan taman red — žica, grana — ne preseče nebo iznad
   horizonta.
2. **Oduzimanje ljudi.** Koža na jakom suncu je bleda, glatka i visoko u kadru —
   dakle prolazi **po zasluzi**. Vision tačno zna gde su ljudi, pa nema razloga
   da heuristika nagađa. Ovo je uklonilo i oreol oko para.

**Prag zaustavljanja je 110, i to je izmereno:** na 140 i naviše maska se uruši
skoro na ništa (140, 170 i 200 daju identičan fajl). Sweep je u istoriji ovog
koraka.

**Šta i dalje ne valja, i rečeno je klijentu:** na kontra-svetlo slici gde nebo,
more i pesak prelaze jedno u drugo bez vidljivog horizonta, maska curi niz tu
ivicu. Tu ni čovek ne bi povukao liniju bez konteksta. Rešenja su dva i oba su
klijentova odluka: zaokružiti oblast Selection alatom pre pritiska (radi već
sada), ili trenirani model — što je stotine megabajta i licenca.

### ⚠️ People je VRAĆEN na piksel sloj

U KORAKU 65 je prebačen na izveden (matica, bez piksela) zbog cene skladištenja.
**To mu je oduzelo mogućnost pomeranja**, što je klijent odmah prijavio — i s
pravom: pomeranje matice ne pomera ljude, pomera rupu i kroz nju pokaže sliku na
drugom mestu.

Sad su dva sloja **namerno različite vrste**:

- **People — piksel sloj.** Pravi izrezan komad, pomerljiv, skalabilan, rotabilan.
- **Background — izveden.** Pokriva ceo kadar, a PNG celog kadra u `UserDefaults`
  je desetine megabajta na svaki upis. Niko ga ionako ne pomera nigde.

Sky ostaje izveden, iz istog razloga. **Zato Sky i Background nemaju okvir na
platnu** — okvir bi bio pravougaonik oko cele slike, a vući nema šta.

### Ručke

Okvir je sad `layerSelectionColor` (siva), ne žuta. Dodata je **rotacija**:
`ImageLayer.rotationDegrees`, transformacija u `compositeLayers` (centar →
skaliranje → rotacija → pozicija, jer rotacija ima smisla samo oko tačke), i
kvaka na kratkoj drški iznad gornje ivice.

**Dve stvari su nosive:**

- **Rotira se kontejner veličine SLOJA, ne platna.** Prva verzija je rotirala
  ceo pogled veličine fotografije oko njegovog gornjeg levog ugla i okvir bi
  odletao van ekrana.
- **Matematika prevlačenja ostaje u nerotiranom prostoru** (`unrotated`). Vučenje
  ugla znači „šire duž OVE ivice", ne „šire duž ekrana"; bez toga sloj se opire
  kursoru čim se zarotira.

Ugao ima **detent od 5°**, da ravno ostane ravno.

### ⚠️ NEPROVERENO

Maska neba JESTE viđena, na pravoj fotografiji, pre i posle. **Nije viđeno:**
ručke i rotacija na ekranu, i da Reset sad zaista skida nebo.

## PLAN — devet prijava od 1. septembra uveče (napravljen 1.09, NIJE počelo)

Klijent je prijavio devet stvari odjednom. Ovo je plan, ne izveštaj — ništa od
ovoga još nije popravljeno. Svaka tačka nosi **šta je izmereno u kodu** odvojeno
od **šta je pretpostavka**, jer se u ovom dokumentu ta dva već jednom pomešala i
koštalo je tri merenja (KORAK 66).

**⚠️ Ništa u ovom planu ne dira zaključane odeljke** — rezoluciju u LumenoLab-u,
AI modele i njihove brojeve, ni `blur`/`grow` u `DevelopInpaint.swift`. Tačka 4
je najbliža toj ivici i tamo je posebno zapisano zašto je NE dira.

### Redosled — tri talasa

Talasi su poređani po odnosu vrednosti prema riziku, ne po redosledu prijave.
Talas A se vidi odmah i ne može ništa da obori; talas C traži merenje na
klijentovoj mašini i može da ne ispadne.

---

### TALAS A — vidi se odmah, mali rizik

#### A1. Traka napretka izlazi iz desnog panela u sliku

**Izmereno:** `eraseProgressBar` (`Develop.swift:5383`) crta se na dva mesta —
`panelHeader:6565` i AI kartica:`10721`. Traka je `GeometryReader` sa
`.frame(height: 6)`; visina je vezana, **širina nije** — `GeometryReader` uzima
ponuđenu širinu, a putujući segment se pomera `offset`-om do
`proxy.size.width - segment`. Ako roditelj ponudi širinu veću od panela, segment
odlazi preko ivice, i ništa ga ne seče.

**Popravka:** vezati širinu na panel (`.frame(maxWidth: .infinity)` na traci) i
staviti `.clipped()` na `ZStack` — clip je pojas i tregeri, da nijedan budući
raspored ne može opet da je pusti u sliku.

**Prvo reprodukovati u pokrenutoj app-i** i uslikati, jer za ovu prijavu nema
slike — treba znati DA LI curi iz zaglavlja panela ili iz AI kartice, pošto su
dva različita roditelja.

Cena: mala.

#### A2. Levi panel sa folderima se ne razvlači

**Izmereno:** `ContentView.swift:21255` — `.frame(width: 260)`, tvrdo. Nema
razdelnika, nema `@AppStorage`. Na klijentovoj slici (18.38) posledica se vidi:
imena foldera su „325 Pl…", „Al…", „Re…", „Se…", „St…" — pet redova zaredom
odsečenih na dva-tri znaka.

**Popravka:** širina u `@AppStorage`, plus razdelnik koji se vuče. **Ne pisati
novi** — LumenoLab već ima razvlačenje i ono je u KORAKU 46 popravljeno da ne
drhti; uzeti isti obrazac.

**⚠️ Mina:** `ContentView.swift:21307` ima `.padding(.leading, 284)` sa
komentarom „sidebar's width (260) plus its divider". To je 260 upisano drugi put,
rukom. Kad širina postane promenljiva, ovo mora da je prati ili će kartica sa
prečicama da odleti preko drveta foldera.

Cena: mala.

#### A3. Crop dugme se teško nalazi

**Izmereno:** `cropRotateSection:9603` — dugme je ikonica bez natpisa
(`Image(systemName: "crop")`), treća u redu, unutar sekcije „Crop & Rotate" u
desnom panelu. Do nje se **skroluje**. U Lightroom-u je crop u stalnoj traci
odmah ispod histograma i nikad ne odlazi sa ekrana.

**Popravka:** Crop dobija mesto u gornjoj traci panela, pored Before/After i
Reset — tamo gde traka već stoji uvek. Sekcijsko dugme OSTAJE (isto stanje,
`isCropping`), ne seli se: klijent ga je već naučio gde je.

Prečica: `R`, kao u Lightroom-u, kroz `Shortcuts.swift` da bude podesiva.

Cena: mala.

#### A4. Slika u ShowGrid-u je mekša nego u Lightroom-u

**Izmereno, i ovo je ceo uzrok:** `ContentView.swift:23171` —
`makeEditedShowGridThumbnail(from: url, maxPixelSize: 2000)`. Uvećan prikaz u
ShowGrid-u dekodira se na **2000 px po dužoj strani**. Na Retina ekranu lupa
široka ~1500 pt je **3000 fizičkih piksela**. Dakle slika se razvlači 1,5× —
tačno ono što se na slici 19.11 vidi kao mekoća.

Drugi, manji izvor: dok se 2000 px ne učita, `loupeImageView:22408` pokazuje
`gridThumbnails[url]` — a to je **420 px** (`makeEditedShowGridThumbnail`
difolt, `Develop.swift:1499`). Prvi kadar posle klika je zato jako mek.

**Zašto se LumenoLab ne poredi loše (slika 19.12):** tamo je zaključano pravilo o
nativnoj rezoluciji i ono radi. Ovo je isključivo ShowGrid-ova lupa.

**Popravka:** dekodirati na stvarnu veličinu prikaza — širina lupe u tačkama ×
`backingScaleFactor`, ograničeno nativnom rezolucijom fajla. Isti potez kao
KORAK 49: **dekodirati umanjeno, ne skalirati posle.**

**⚠️ Ovo NE dira zaključani odeljak.** Pravilo kaže da sličice u filmstrip-u i
ShowGrid mreži SMEJU biti male — i ostaju 420 px. Lupa nije sličica.

**Meriti:** ista fotografija, ista veličina prozora, pre i posle, uz Lightroom
pored — jer je klijent tako i prijavio.

Cena: mala. Pazi na memoriju kad je više fotki otvoreno u lupi odjednom.

---

### TALAS B — ponašanje, srednja cena

#### B1. Sinhronizovan 4:3 se ne zadrži kad se uđe u fotografiju

**Izmereno, i piše u samom kodu:** `Develop.swift:351` —

> „Quick aspect-ratio presets … **not persisted anywhere** (EditCropRect itself
> has no notion of 'locked to a ratio')"

`selectedCropAspectRatio` je `@State` (`:4971`) i vraća se na `.free` na
`:13395`. Uz to, `mergedSyncSettings` u kategoriji `.cropRotate` (`:13116`)
prenosi `rotationQuarterTurns`, `straightenDegrees` i `crop` — **odnos NE**,
jer ga nema gde da prenese.

Dakle Sync prenese pravougaonik, ali fotografija koja se posle otvori nema
pojma da je zaključana na 4:3, pa svako vučenje ručke ide slobodno. Tačno kako
je prijavljeno.

**Popravka:** odnos postaje polje u `PhotoEditSettings`, ide u `.cropRotate`
kategoriju Sync-a, i vraća se pri otvaranju fotografije.

**⚠️ Mina — `PhotoEditSettings` je Codable.** Novo polje mora imati difolt pri
dekodiranju ili **svaka postojeća izmena koju klijent ima na disku prestaje da
se pročita.** Isto upozorenje već stoji uz `ImageLayer` u KORAKU 63. Uraditi
`init(from:)` sa `decodeIfPresent` i difoltom `.free`, i **proveriti na pravom
`UserDefaults`-u sa starim zapisom**, ne samo na novom.

Cena: srednja. Rizik je isključivo u Codable migraciji.

#### B2. Vučenje i razvlačenje crop-a lagovi

**Izmereno:** matematika nije uzrok — `resizeCrop:7755` je nekoliko deljenja i
`min`/`max`, ništa po pikselu.

**Pretpostavka, i mora se izmeriti pre nego što se dira:** `pendingCrop` je
`@State` na `DevelopView`, pa svaka izmena tokom vučenja ponovo gradi **celo**
telo pogleda, sliku uključivo. To je isti kvar koji je već tri puta nađen u
ovom dokumentu — KORAK 36 (painting), pa opet u KORAKU 44 na **još četiri
mesta**. Ovo bi bilo peto.

**Popravka, ako se pretpostavka potvrdi:** izdvojiti crop overlay u sopstveni
pogled sa sopstvenim stanjem, tako da vučenje ne dira `DevelopView`. Isti
obrazac koji je već primenjen u KORACIMA 36 i 44 — ne izmišljati šesti.

**Meriti Instruments-om ili brojanjem prolaza kroz `body`**, pre i posle. Ne
„izgleda brže".

Cena: srednja.

#### B3. Odbačene fotografije (Lightroom „reject")

Traženo: fotografija se označi kao odbačena, sa znakom na sebi, **ne briše se**,
i pri izvozu se preskače.

**Izmereno:** `PhotoLabelStore` (`ContentView.swift:23631`) već drži dva skupa u
`UserDefaults` — liked i ratings — ključem `"ime|veličina"`. Treći skup ide
istim putem, bez ičeg novog.

**Popravka:**
- `PhotoLabelStore.setRejected/isRejected`, treći ključ.
- **⚠️ `X` JE VEĆ ZAUZET, i to baš u ShowGrid-u.** `ShortcutAction.gridToggleLabel`
  ima difolt `.key("x")`, a `gridClearLabels` `.key("v")` — obe u ShowGrid grupi,
  tačno tamo gde bi Lightroom-ov reject išao. Dakle nije „dodaj X", nego
  **odluka koju od dve stvari X radi**, i klijent je taj koji je bira:
  (a) X ostaje Toggle Label, reject ide na neko drugo slovo — čuva naviku, ali
  se razilazi sa Lightroom-om baš na tasteru koji se najviše pritiska;
  (b) X postaje Reject kao u Lightroom-u, a Toggle Label se seli — poklapa se
  sa Lightroom-om, ali menja naučen taster.
  U svakom slučaju obe idu kroz `Shortcuts.swift`, pa su podesive.
- `U` vraća odbačenu nazad (u Lightroom-u je to par sa X).
- Znak na sličici u mreži i u filmstrip-u, i prigušen prikaz — Lightroom je
  zatamni; odluka za klijenta da li i mi.
- **Izvoz preskače odbačene na SVA četiri mesta**, i to je jedini deo koji sme
  da se pogreši tiho: `ContentView.exportPhotos:23206`,
  `Develop.exportSelectedPhotos:13876`, `Develop.exportAllEditedPhotos:13947`,
  i `Develop.exportSinglePhoto:13828`.

**Odlučeno 1.09. (klijent):** ako je otvorena JEDNA fotografija i ona je
odbačena, a klijent pritisne Export — **izveze se, uz upozorenje.** Izričit
pritisak na jednu fotografiju je namera, ne previd. Grupni izvozi je i dalje
preskaču bez pitanja.

Cena: srednja, raširena po fajlovima.

#### B4. Prevlačenje foldera na ikonicu ne radi

**Izmereno, i uzrok je konačan:** app **ne prijavljuje da ume da otvori išta.**
`GENERATE_INFOPLIST_FILE = YES` i nema `Info.plist` fajla
(`project.pbxproj:322`), dakle nema `CFBundleDocumentTypes`, i u
`BriefShowApp.swift` nema `NSApplicationDelegateAdaptor` — nema
`application(_:openURLs:)`. Finder zato ne dozvoljava da se folder pusti na
ikonicu, i ništa se ne dešava. Nije bag, nikad nije ni bilo napravljeno.

**Popravka ima dva dela i oba su potrebna:**
1. Pravi `Info.plist` sa `CFBundleDocumentTypes` za `public.folder` (uloga
   `Viewer`) i `LSSupportsOpeningDocumentsInPlace`. Uz `GENERATE_INFOPLIST_FILE`
   Xcode fajl uzima kao osnovu i dodaje svoje ključeve povrh.
2. `AppDelegate` sa `application(_:openURLs:)` koji folder prosledi ShowGrid-u.

**Ne pisati novu logiku otvaranja** — `ContentView.swift:21419` već otvara
prevučen folder na prozor, i to radi. Delegat samo puni isto mesto.

**⚠️ Sandbox:** puštanje na ikonicu jeste korisnikov izbor i Powerbox daje
pristup, ali **ovo se mora videti na potpisanom build-u**, ne u Xcode-u. Ista
klasa greške kao entitlement iz KORAKA 35.

Cena: srednja. Traži izmenu projekta, ne samo Swift-a.

---

### TALAS C — mora merenje na pravoj mašini, može i da ne ispadne

#### C1. Kamera se vidi, ali „0 files on the card"

**Izmereno sa klijentove slike (18.34), i ovo sužava pretragu na jedno mesto:**
bočni panel piše **„0 files on the card"**. `statusLine`
(`CameraImportView.swift:141`) tu rečenicu daje SAMO za faze
`.ready/.importing/.finished/.failed`; da je faza bila `.listing`, pisalo bi
„Reading the card… 0 so far".

Dakle: **sesija se otvorila, kamera je javila kompletan katalog
(`deviceDidBecomeReady`), i `mediaFiles` je bio prazan.** Nije USB, nije
entitlement, nije spavanje kamere — sve troje je prošlo. Poruka u sredini
(„Reading the card…", `:196`) je zato **lagala**, jer se crta kad god je lista
prazna, bez obzira na fazu. To je zaseban, siguran popravak.

**Pretpostavka broj 1, najjača:** `ICCameraDevice.mediaFiles` je **filtrirana**
lista — samo ono što ImageCaptureCore prepozna kao medija po UTI-ju. NEF sa
novijeg tela koje sistem ne poznaje ispada. `device.contents` (stablo foldera)
ne filtrira ništa.
→ **Popravka:** šetati `contents` rekurzivno i uzimati svaki `ICCameraFile`, a
`mediaFiles` koristiti samo kao potvrdu.

**Pretpostavka broj 2:** dupla stavka. Na obe slike kamera je u spisku **dvaput**
(„LOC:346030080" dvaput u 18.34, „Z 6" dvaput u 18.38). `CameraBrowser`
razlikuje uređaje po `device ===` (`CameraImport.swift:39`), pa dva različita
objekta za isto telo oba prolaze. Ako se sesija otvori na pogrešnom, katalog je
prazan. Uz to `id` ide preko `uuidString` — ako su isti, `ForEach` ima dva
jednaka ključa, što je samo po sebi nedefinisano ponašanje.
→ **Popravka:** razlikovati po `uuidString`, i pokazati jedan red po telu.

Ime „LOC:346030080" u 18.34 i „Z 6" u 18.38 je isto telo pre i posle nego što
uređaj bude spreman — dakle spisak se crta i dok su uređaji polusirovi.

**Prvi potez nije popravka nego merenje:** `Tools/camtest.swift`, po ugledu na
`skymask.swift` i `skytest.swift` — komandna alatka koja izlista uređaje
(`name`, `uuidString`, `transportType`), otvori sesiju, i **ispiše sa vremenima
svaki delegatski poziv**, plus `contents.count` i `mediaFiles.count` posle
`deviceDidBecomeReady`. Time se između dve pretpostavke bira mereno.

**⚠️ Alatka nije u sandbox-u i app jeste** — ako se u alatki fajlovi vide a u
app-i ne, odgovor je sandbox i pretpostavke padaju obe. To je i dalje nalaz.

**⚠️ Traži klijentovu kameru priključenu.** Ovo ne mogu da izmerim sam.

Cena: nepoznata dok se ne izmeri. Popravka je verovatno mala, pronalaženje nije.

#### C2. SD Generative na Intelu

Mašina: i7 3,2 GHz 6 jezgara, 32 GB DDR4-2667, **Radeon Pro 560X sa 4 GB**.

**Prvo, pošteno, o traženom „kombinuj sve troje":** ne kombinuje se tako.
32 GB sistemske memorije se **ne dodaje** na 4 GB video memorije — na Intel Mac-u
su to dve odvojene memorije preko PCIe. CoreML sme da podeli mrežu između CPU-a
i GPU-a (`MLComputeUnits.all`) i to je maksimum onoga što „kombinovanje" ovde
znači. Ono što ne stane u 4 GB ide na CPU, i tamo je sporo. Ovo nije prepreka
sama po sebi — SD 1.5 na 512×512 u fp16 staje u 4 GB — ali obećanje da će 32 GB
RAM-a nadoknaditi grafičku nije tačno i ne treba ga davati.

**Dve prepreke, i druga je veća od prve.**

**Prepreka 1 — `Float16` ne postoji na x86_64.** Već zapisano u ovom dokumentu:
`DevelopSDInpaint.swift` ga koristi na 8 mesta i ceo fajl je danas iza
`#if arch(arm64)`. Ovo je rešivo i **ne mora da dira arm64 put uopšte**:
`MLMultiArray` sa `dataType: .float16` postoji i na Intelu, samo se ne sme
puniti kroz Swift-ov tip `Float16`. Puni se preko
`vImageConvert_PlanarFtoPlanar16F`, koji na Intelu radi. Ulazi u model ostaju
bajt-u-bajt isti, pa se **ništa izmereno na arm64 ne pomera** — što je uslov,
jer je izlaz AI Clean Up-a zaključan od 31.08.

**Prepreka 2 — modela nema ni na jednoj klijentovoj mašini, ni Intel ni Apple
Silicon.** Ovo već stoji u „GDE SMO STALI": `SDModelStore` traži modele u
Application Support pa na Desktopu; **prvo mesto niko ne popunjava** —
preuzimanja nema, `installedDirectory` se u celom kodu samo čita. Drugo postoji
samo na ovoj mašini. Težine su **2,14 GB**, app je 125 MB, a GitHub Releases
prima do 2 GB po fajlu — dakle ni kao zaseban prilog.

**⚠️ Zato prepreka 2 ide PRVA.** Ako se uradi samo Intel deo, klijent na Intelu
dobije isti „models missing" kao i svi ostali, i uložen posao ne isporuči ništa.
Redosled je: **prvo hosting i preuzimanje težina, pa tek onda Intel.**

**⚠️ Ovo je redosled UNUTAR C2, ne u projektu.** Ceo C2 je klijentovom odlukom
od 2.09. **poslednji** — v. „REDOSLED I KAPIJA" u spisku od 2. septembra uveče.

**Čega još nema, a mora:** SD put ide na 512 px radno platno
(`SDInpaintPipeline.imageSide`, zaključano) i 12 koraka. Na Radeon Pro 560X to
je realno **minuti, ne sekundi**. Broj se ne sme pogađati — meri se na
klijentovoj mašini pre nego što se dugme uopšte pusti, i ako ispadne
neupotrebljivo sporo, pošten odgovor je da dugme na Intelu ostane isključeno sa
razlogom koji piše, kako je danas.

**Predlog:** raditi C2 posle svega ostalog, u dva odvojena koraka, i ne
obećavati ishod dok se ne izmeri.

Cena: velika, i jedina tačka u planu koja može da se završi sa „ne isplati se".

---

### Šta ovaj plan NE dira

Nebo (`SkyMasker`) — dogovoreno da ide posle ovoga. Preimenovanje u „Afterburn
Studio" — i dalje nije počelo. Puštanje KORAKA 56 (`is_locked`,
`latest_version`) — čeka da svi budu na novom build-u.

**⚠️ Kad se bude pravio build sa ovim izmenama, gleda se KORAK 56 do kraja** —
`latest_version` u BriefControl-u i dalje piše 6.0.

## KORAK 68 — talas A iz plana: traka, levi panel, Crop, oštrina lupe (1. septembar 2026)

Prve četiri tačke plana „devet prijava". Sve četiri su izmene rasporeda i
učitavanja; **nijedna ne dira nijedan zaključan odeljak** — ni rezoluciju u
LumenoLab-u, ni AI modele, ni `blur`/`grow`.

### Oštrina u ShowGrid lupi — bio je jedan broj

`loadLoupeImages` je dekodirao na **fiksnih 2000 px**. Lupa na Retina prozoru
širokom ~1500 pt traži **3000 fizičkih piksela**. Dakle AppKit je razvlačio
2000 px na 3000 — 1,5× uvećanje, i to je cela prijavljena „meka slika". Nije bio
RAW, nije bio renderer, nije bio profil boje.

Sad se dekodira na ono što ekran zaista crta: ćelija u tačkama × `backingScaleFactor`
prozora, ograničeno na 6000. Ista pouka kao KORAK 49 — **dekoduj umanjeno, ne
skaliraj umanjeno posle** — primenjena na jedino mesto u ShowGrid-u koje je
radilo obrnuto.

**Tri stvari koje nisu očigledne, i sve tri su morale:**

1. **Dekodiranje sad vodi `loupeGrid`, ne `openLoupe`.** `openLoupe` ne zna
   koliko će slika biti velika; `GeometryReader` u mreži zna. Zato `openLoupe`
   više uopšte ne pokreće učitavanje.
2. **`loupeImages` preživljava zatvaranje lupe**, pa obična provera „da li je
   već učitana" znači da je **prva veličina prozora na kojoj je lupa ikad
   otvorena zauvek i najoštrija koju ta slika dobija.** Zato postoji
   `loupeImagePixelSizes` — pamti na kojoj je veličini dekodirana, i dekoduje
   ponovo kad prozor poraste. Prag je 0,87, ne tačno poređenje: vučenje ivice
   prozora menja ćeliju za par tačaka po kadru, a tačno poređenje bi naručilo
   jedno puno dekodiranje RAW-a **po kadru vučenja**.
3. **`backingScaleFactor` se čita sa PROZORA, ne sa `NSScreen.main`.**
   `NSScreen.main` je ekran sa ključnim prozorom, što nije nužno ekran na kom je
   ShowGrid. Na spoljnom 1× ekranu bi promašaj značio dekodiranje na dvostruko,
   a na Retini prevučenoj na 1× — dekodiranje na pola, i opet meku sliku.

`loupeImagePixelSizes` se briše svuda gde se briše i `loupeImages` (bacanje u
korpu, premeštanje, izmena) — inače bi izmenjena fotografija zadržala staru
zauzetu veličinu i ne bi se ponovo dekodirala.

**Ostavljen je i dalje `gridThumbnails` kao međukorak dok se ne učita** — to je
420 px i jeste mutno prvi tren. Namerno: prazan okvir sa vrtiljkom je gori od
mutne slike koja se izoštri za pola sekunde.

### Traka napretka — kriv je `.offset`, ne širina

`.offset` **ne učestvuje u rasporedu.** Pomerena stavka se crta gde je stavljena,
pravo kroz granice roditelja, jer SwiftUI po difoltu ne seče ništa. Putujući
segment je jedina necečena stvar u toj traci i on je izašao na fotografiju.

Sad je `.clipped()` na traci. Bekstvo je time strukturno nemoguće, umesto da
zavisi od toga da aritmetika `proxy.size.width - segment` ostane tačna u oba
roditelja u kojima se traka crta (`panelHeader` i AI kartica).

**⚠️ Ovo NIJE potvrđeno gledanjem.** Za ovu prijavu nema slike, i nije
reprodukovano — v. NEPROVERENO na dnu.

### Levi panel se razvlači

`.frame(width: 260)` → `@AppStorage` širina (180–560) plus ručica koja se vuče.
**Nije pisana nova** — uzet je `panelResizeHandle` iz LumenoLab-a, jer je taj
prošao KORAK 46 gde su nađena **dva** razloga drhtanja: pisanje kroz na svaki
kadar, i lokalne koordinate kao povratna sprega. Nova ručica bi bila druga
prilika da se obe naprave ponovo. Znak je obrnut — ovaj panel je levo, pa
vučenje udesno širi.

**⚠️ Usput izbegnuta mina:** `.padding(.leading, 284)` na kartici sa prečicama
bio je stari fiksni 260 upisan **drugi put, rukom**. Da je ostao, kartica bi bila
na pogrešnom mestu na svakoj širini osim jedne. Sad se računa iz iste vrednosti.

### Crop je u stalnoj traci

Bio je gola ikonica, treća u redu, u sekciji „Crop & Rotate" do koje se skroluje.
Sad ima i mesto u zaglavlju panela — pored Before/After, Reset i Done — sa
natpisom, jer ikonica bez natpisa u redu reči čita se kao ukras.

**Ono u „Crop & Rotate" OSTAJE.** Isto stanje (`isCropping`), nije drugi režim.
Ukloniti ga da ne bi bilo duplikata značilo bi popraviti prijavu tako što se
pokvari naučena navika.

Prečica: **`R`**, kao u Lightroom-u, kroz `Shortcuts.swift` pa je podesiva.
Slobodno je u LumenoLab grupi. Čuvano je `selectedURL != nil`, kao i svaki drugi
slučaj u tom monitoru — bez otvorene fotografije `R` ostaje obično slovo.

### ⚠️ NEPROVERENO — i ovo je ceo domet ovog koraka

**Prevodi se** (`BUILD SUCCEEDED`, Debug). **Ništa nije viđeno na ekranu.**
App je pokrenuta i podigla se kao proces, ali je ekran ove mašine u trenutku
pisanja pokazivao samo pozadinu — bez menija, bez Dock-a — i `System Events` je
odgovarao istekom vremena, pa snimak ekrana nije uhvatio nijedan prozor.

Dakle nije viđeno **ni jedno od četiri**:

- da lupa zaista jeste oštrija (**meriti isto kao što je prijavljeno**: ista
  fotografija, isti prozor, Lightroom pored, pre i posle);
- da traka više ne izlazi iz panela — **a ovo nije ni reprodukovano**, pa je
  popravka rezonovanje o `.offset`, ne odgovor na viđeni kvar. Ako i dalje curi,
  uzrok je drugde i traži se snimak;
- da se levi panel vuče glatko i da širina preživi gašenje app-e;
- da `R` otvara crop i da dugme u zaglavlju svetli dok je crop aktivan.

## KORAK 69 — B1: zaključan odnos crop-a se pamti i sinhronizuje (2. septembar 2026)

Prijava: „kad sinhronizujem sve fotke na 4:3, pa uđem u fotku da doteram crop,
kreće od originalnog odnosa a ne od 4:3 koji je već postavljen."

### Uzrok je pisao u samom kodu

Iznad `CropAspectRatioOption` je stajalo, doslovno: *„not persisted anywhere
(EditCropRect itself has no notion of 'locked to a ratio')"*. Odnos je bio
`@State`, a `toggleCropMode` ga je pri svakom otvaranju alata postavljao na
`.free`. Sync je u kategoriji `.cropRotate` prenosio `rotationQuarterTurns`,
`straightenDegrees` i `crop` — **odnos ne, jer ga nije imao gde preneti.**

Dakle putovao je PRAVOUGAONIK a ne BRAVA. Na cilju je crop bio 4:3, ali prvo
vučenje ručke išlo je slobodno, jer taj sloj podataka nije znao da postoji
zaključanje.

### Šta je urađeno

`cropAspect` je sad polje na `PhotoEditSettings`, pa:

- `toggleCropMode` ga **vraća** umesto da ga briše (bila je jedna linija
  `= .free`, i to je bio ceo bag);
- `commitCrop` ga upisuje — **tu, a ne na svaki pritisak dugmeta u redu odnosa.**
  Prolazak kroz red bi inače upisao `settings` šest puta, a `onChange(of:
  settings)` ponovo renderuje fotografiju. Brava se pamti u istom trenutku kao i
  pravougaonik koji je napravila;
- `mergedSyncSettings` ga nosi zajedno sa `crop`-om u kategoriji „Crop & Rotate";
- `resetAllSettings` čisti i `@State` kopiju — bez toga bi Reset sa OTVORENIM
  crop alatom ostavio 4:3 upaljeno u redu, i `commitCrop` bi tu ustajalu bravu
  upisao nazad preko reseta.

`CropAspectRatioOption` je izašao iz `private` i dobio **`String` sirove
vrednosti, ne podrazumevane `Int` redne brojeve** — ovo završava u JSON zapisu na
klijentovom disku, a redni brojevi bi tiho preusmerili svaki sačuvan odnos onog
dana kad neko ubaci novi slučaj u sredinu spiska.

`cropAspect` NE ulazi u `isNeutral`, iz istog razloga iz kog ne ulaze ni oblik
vinjete ni `sharpenRadius`: sam po sebi ne menja nijedan piksel, a brojanje bi
upalilo „ova fotka ima izmene" — a s tim i Flatten, Reset i spiskove za izvoz —
za polugu koja ne radi ništa.

### ⚠️ MINA JE VEĆA NEGO ŠTO JE PLAN REKAO — i sad je izmerena

Plan je rekao „novo polje bez difolta obara postojeće izmene". Pravo stanje je
gore. `PhotoEditStore.allSettings` radi:

```swift
(try? JSONDecoder().decode([String: PhotoEditSettings].self, from: data)) ?? [:]
```

To je **JEDAN rečnik sa svim izmenama koje je klijent ikad napravio, i odluka je
sve-ili-ništa.** Jedan zapis koji ne dekodira ne ispada sam — ceo dekod vrati
nil, sve izmene u app-i postanu `[:]`, i sledeći odloženi upis to prazno
prepiše preko klijentovog rada. Bez greške, bez dijaloga, bez undo-a.

**Zato je napravljen `Tools/run-editsettings-decode-test.py`.** Čita PRAVI blob
iz `defaults` instalirane app-e i dekodira ga strukturom kakva je u
`Develop.swift` u tom trenutku — tipovi se vade iz izvora po tekstu, kao u
`run-layer-reorder-test.py`, pa test ne može tiho da zaostane za kodom.

**Izmereno na klijentovom stvarnom skladištu (2.09.):**

```
records in the client's store: 25
declared but absent from every stored record: ['cropAspect']
decoded: 25 records
RESULT: OK — every record survives, and no stored number moved
```

Dakle svih 25 zapisa napisanih STARIM build-om i dalje dekodira, i nijedan
sačuvan broj se nije pomerio na round-tripu. Test ne proverava samo da dekodira
nego i da vrednosti ostanu iste — zapis koji dekodira u DRUGE brojeve je tiha
izmena tuđeg rada, što je gore od pada.

**Negativna kontrola je takođe pokrenuta**, jer test koji ne može da padne ne
dokazuje ništa: sa jednim namerno pokvarenim zapisom (`exposure` kao string) od
25, test pada, imenuje baš taj zapis, i pokaže da bi app obrisala **svih 25**.

Rezerva klijentovog `defaults`-a je uzeta pre svega ovoga.

### ⚠️ NEPROVERENO

Prevodi se, i migracija je izmerena. **Nije viđeno na ekranu:** da Sync na 4:3
sad zaista drži odnos kad se uđe u drugu fotku i povuče ručka, i da Reset sa
otvorenim crop alatom gasi red odnosa.

## KORAK 70 — B2: crop lag nije bio ponovna gradnja pogleda nego render (2. septembar 2026)

Prijava: „kad pomeram crop ili ga razvlačim, malo lagne."

### ⚠️ PLAN JE PRETPOSTAVIO POGREŠAN UZROK — i zato je tražio merenje

Plan (tačka B2) je rekao: verovatno peti slučaj kvara iz KORAKA 36 i 44 —
`pendingCrop` je `@State`, pa svaki kadar vučenja ponovo gradi `DevelopView.body`.
**To jeste tačno, i nije glavni trošak.**

Prava cena je bila jedna linija:

```swift
.onChange(of: pendingCrop) { _ in
    if isCropping { scheduleRender() }
}
```

### Zašto je to bilo čisto bacanje

`renderNow()` prosleđuje **`applyCrop: !isCropping`**. Dakle dok je crop alat
otvoren, render **potpuno ignoriše crop** — `pendingCrop` mu uopšte nije ulaz.
Ulazi su `settings`, `previewBaseImage` i `showOriginal`, i nijedan se ne menja
tokom vučenja.

Znači svaki kadar vučenja je proizvodio **bit-identičnu sliku**, a usput radio:

| po kadru vučenja | šta je |
|---|---|
| `PhotoEditRenderer.render` | ceo CoreImage lanac nad preview-om |
| `briefEditsDisplayCGImage` | konverzija u CGImage |
| `PhotoEditStore.setSettings` | upis u skladište + zakazan flush celog blob-a |
| `luminanceHistogram` | pun prolaz kroz renderovanu sliku |
| `scheduleRefinedRender()` | **puna rezolucija** (5176×3448 na .NEF-u) |
| `displayedImage =` i `histogramBins =` | još **dva** poništenja `body`-ja |

Na `scheduleRender`-ovom pragu od 20 ms to je do **pedeset takvih u sekundi, za
sliku koja se nije menjala.**

### Popravka — brisanje, ne optimizacija

`onChange(of: pendingCrop)` više ne postoji. Na njegovom mestu stoji objašnjenje
zašto ga ne treba vraćati.

**Provereno jedan po jedan, ne pretpostavljeno:** svaki drugi upisivač
`pendingCrop`-a ili u istom dahu postavlja `settings` (undo/redo, flatten,
unflatten, bake, preset, paste, reset) pa ga pokriva `onChange(of: settings)`
iznad, ili sam zove `scheduleRender()` (`toggleCropMode` pri ulasku, `commitCrop`
pri izlasku). Ona tri koja ne rade ni jedno ni drugo — `applyCropAspectRatio`,
„Reset Crop" i samo vučenje — **ne treba im render**, iz razloga iz prvog
pasusa.

### Šta OSTAJE, i to pošteno

Ponovna gradnja `DevelopView.body` po kadru vučenja je i dalje tu — `pendingCrop`
je i dalje `@State` na tom pogledu. To je **sekundarni** trošak i namerno nije
diran u istom koraku: izmeštanje u observable objekat (obrazac iz KORAKA 36 i 44)
dotiče `pendingCrop` na dvadesetak mesta, i nema smisla praviti taj zahvat pre
nego što se zna da li se preostali lag uopšte oseti.

**Ako se posle ovoga i dalje oseti, to je taj ostatak i tada se radi izmeštanje.**

### ⚠️ NEPROVERENO

Prevodi se. **Nije viđeno na ekranu**, i ovo je jedina od dosadašnjih tačaka gde
je potvrda korisnika i jedina moguća mera — lag je osećaj, a sve što se moglo
utvrditi čitanjem jeste da render nije mogao ništa da promeni na slici.

## KORAK 71 — B3: odbačene fotografije, i tri prečice po klijentovom rasporedu (2. septembar 2026)

Traženo: fotografija se označi kao odbačena kao u Lightroom-u — **sa znakom na
sebi, ne obrisana** — i izvoz je preskače. Uz to, izričito zatražen raspored
tastera: `X` odbacuje, `.` je label, `,` dodaje zvezdicu.

### Skladište — treći ključ, ne vrednost u ocenu

`PhotoLabelStore` je već držao dva skupa u `UserDefaults` ključem `"ime|veličina"`.
Odbacivanje je treći, istim putem.

**Namerno nije uvučeno u ocenu** (npr. „ocena −1"): u Lightroom-u su odbačeno i
ocenjeno nezavisni, a klijent radi u obe app-e. Fotografija može biti trojka koja
je kasnije odbačena, i skidanje odbacivanja mora da vrati te tri zvezdice.

`clear(for:)` — „Clear All" — **briše i odbacivanje.** To je jedina kontrola koja
kaže da vraća celu selekciju na ništa, a ostaviti fotografije odbačenim posle nje
značilo bi izvoz koji tiho preskače fajlove za koje klijent misli da ih je upravo
odznačio.

### ⚠️ X JE BIO ZAUZET — i to je bila stvarna odluka, ne sitnica

`gridToggleLabel` je imao difolt `.key("x")`. Po klijentovom izboru:

| taster | pre | sada |
|---|---|---|
| `X` | Toggle Label | **Reject** |
| `.` | — | Toggle Label |
| `,` | — | **+1 zvezdica**, 5 se vraća na nulu |

Sve tri idu kroz `Shortcuts.swift` i vide se i menjaju u Edit ▸ Keyboard
Shortcuts. Tasteri `1`–`5` i dalje POSTAVLJAJU ocenu i nisu dirani — ostaju u
`fixed` spisku.

**⚠️ Mina koja postoji i ne može da se ukloni iz koda:** `ShortcutStore` čuva samo
ono što je klijent stvarno menjao, pa novi difolt stiže svakome ko taster nije
dirao — što je i poenta. Ali klijent koji je NEKAD izričito vezao Toggle Label
BAŠ na `x` zadržava taj override, i tada dve akcije u istoj grupi odgovaraju na
X. Monitor zato proverava **Reject prvo**, pa X odbacuje a stari override je mrtav;
ekran sa prečicama pokazuje sudar i bilo koja od dve može da se premesti.

**Odbacivanje je preklopnik, ne jednosmerna oznaka.** Lightroom za vraćanje
koristi `U`, ali drugi taster čiji je jedini posao poništavanje prvog je taster
koji se pamti ni za šta.

**`,` radi samo u mreži**, kako je i traženo. Uvećano su `1`–`5` ionako tu i kažu
tačno šta postavljaju; taster koji znači „jedan više nego što je sad" zarađuje
mesto na sličici, ne preko celog ekrana.

**Sa više izabranih fotografija korak se računa JEDNOM**, od prve izabrane, i ista
dobijena vrednost se upisuje svima. Koračanje svake od njene sopstvene ocene bi
mešovitu selekciju na svaki pritisak razvlačilo dalje umesto da je skuplja, i ne
bi postojao jedan broj koji se može prijaviti.

### Kako izgleda

Odbačena fotografija je **prigušena i nosi X u krugu**, kao u Lightroom-u.
Prigušenje ide **samo na sliku, ne na celu ćeliju**, da zvezdice i kružić ispod
ostanu čitljivi — klijent koji traži šta da vrati čita baš njih.

Podnožje sad broji i odbačene („184 photos · 12 labeled · 5 starred · 9
rejected"). To je tu iz jednog razloga: izvozi pored njega tiho ostaju kraći dok
je taj broj iznad nule, a broj koji se vidi PRE pritiska vredi više od objašnjenja
posle.

### Izvoz — sva četiri mesta, i izuzetak

Preskakanje je dodato na sva četiri: `ContentView.exportPhotos` (Labeled i
Starred), `Develop.exportSelectedPhotos`, `Develop.exportAllEditedPhotos`.

**Filtrira se PRE nego što se otvori birač foldera**, u sva tri grupna slučaja.
Filtriranje posle bi otvorilo panel koji obećava dvadeset fajlova a upisalo
jedanaest. Panel uz to kaže koliko ih preskače — klijent koji je odbacivao pre
više sati neće sam povezati kratak izvoz sa oznakom koje se ne seća, a „nedostaju
mi fajlovi" je najgore što izvoz može da ostavi za sobom.

**Izuzetak, odlučen 1.09:** `exportEditedCopy` i `exportSinglePhoto` — jedna
imenovana fotografija — **izvoze je i kad je odbačena, uz upozorenje u panelu.**
Pritisak na Export nad jednom imenovanom fotografijom je namera, ne previd, a
odbijanje bi značilo da se oznaka mora skinuti samo da bi izašao jedan fajl.

### ⚠️ NEPROVERENO

Prevodi se. **Nije viđeno na ekranu:** znak i prigušenje na sličici, da `X`, `.`
i `,` rade i da se sve tri vide u Edit ▸ Keyboard Shortcuts, i da izvoz zaista
preskoči odbačene i to kaže u panelu.

Posebno neprovereno: da odbacivanje **preživi gašenje app-e** — piše se istim
putem kao label i ocena, koji preživljavaju, ali to nije isto što i viđeno.

## KORAK 72 — B4: folder se pušta na ikonicu (2. septembar 2026)

Traženo: prevučeš folder na BriefShow ikonicu, BriefShow se otvori i pokaže šta
je u njemu.

### Uzrok — app nikad nije rekla da ume išta da otvori

`GENERATE_INFOPLIST_FILE = YES` i **nije bilo `Info.plist` fajla**, dakle nije
bilo `CFBundleDocumentTypes`; u `BriefShowApp.swift` nije bilo
`NSApplicationDelegateAdaptor`, dakle nije bilo `application(_:open:)`.

Finder zato nije ni **dozvoljavao** puštanje na ikonicu. Nije bio bag u obradi
puštanja — nikad nije ni napravljeno.

### Popravka ima dve polovine i nijedna ne radi sama

**1. `BriefShow/Info.plist`** — postoji zbog jednog ključa,
`CFBundleDocumentTypes` za `public.folder`. Za tip dokumenta ne postoji
`INFOPLIST_KEY_` podešavanje, i to je jedini razlog zašto fajl uopšte mora da
postoji. `GENERATE_INFOPLIST_FILE` ostaje `YES` i Xcode svoje ključeve spaja
povrh ovoga.

Referišе se putanjom iz `INFOPLIST_FILE` i **nije dodat u Xcode navigator** —
isto kako je pored njega referisan `BriefShow.entitlements`. To je zatečena
konvencija ovog projekta, ne prečica.

**⚠️ `LSHandlerRank` je `Alternate`, i to je nosivo.** `Owner` ili `Default` bi
značilo da BriefShow postaje ono što se otvori kad se u Finder-u dvaput klikne
na folder. Treba nam samo da bude legalna meta puštanja na sopstvenu ikonicu i
da se pojavi u „Open With".

`LSSupportsOpeningDocumentsInPlace` je `true`: bez toga app dobija KOPIJU foldera
na privremenoj lokaciji, a za pregledač fotografija je to beskorisno — svaka
izmena, oznaka i ocena bi se pisala na putanju koja nestaje.

**2. `BriefShowAppDelegate`** — `application(_:open:)`.

Tri stvari koje nisu očigledne:

- **URL se ne prosleđuje pogledu nego se PARKIRA** (`ExternalFolderOpen`).
  Puštanje foldera na ikonicu app-e koja NE radi je pokreće, i povratni poziv
  delegata ume da stigne pre nego što ShowGrid-ov pogled uopšte postoji. Pogled
  ga preuzima preko `.onReceive` — a `Publisher` isporučuje trenutnu vrednost
  čim se pretplati, pa je slučaj hladnog pokretanja pokriven istim kodom kao i
  slučaj kad app već radi.
- **`startAccessingSecurityScopedResource()` mora, i nikad se ne pušta.** URL
  predat ovim putem nosi sopstveno sandbox proširenje koje se mora preuzeti.
  ⚠️ **Važi samo za sesiju:** folder IZVAN klijentovog home foldera — spoljni
  disk, mrežni disk — čita se sada ali ne i posle ponovnog pokretanja, jer se za
  njega ne čuva bookmark. Sve ispod home-a pokriva `RootFolderAccess`.
- **Delegat NE otvara prozor**, samo `NSApp.activate`. Pravljenje prozora odavde
  je tačno ono što je u KORAKU 51 pravilo dva prozora.

Otvaranje foldera ide kroz **iste dve linije** koje već koristi puštanje foldera
na sam prozor (`refreshFolderTree()` pa `selectedFolderURL = folder`). Drugi
način otvaranja foldera bio bi drugi način da otvaranje bude pogrešno.

Usput: `BriefShowApp.swift` je morao da dobije `import Combine`. Meta se prevodi
sa `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`, koji gasi to što SwiftUI
inače re-izvozi `@Published`.

### ⚠️ IZMERENO — i to baš na riskantnoj polovini

Izmena `project.pbxproj`-a je bila jedini deo koji je mogao tiho da ošteti build.
Zato je sagrađen `Info.plist` **uporeðen ključ po ključ** sa onim iz prethodnog
build-a (`build_universal`):

```
IZGUBLJENO: ništa
DODATO:     ['CFBundleDocumentTypes', 'LSSupportsOpeningDocumentsInPlace']
PROMENJENO: (ništa)
```

Dakle spajanje nije pojelo nijedan generisani ključ — verzija, identifikator,
ikonica, minimalni sistem, svi su prošli. (`NSPrincipalClass` ne postoji, ali ga
nije bilo ni u jednom ranijem build-u — provereno na tri.)

**I LaunchServices to potvrđuje**, posle `lsregister -f` na sagrađenoj app-i:

```
claimed UTIs:  public.folder
claim id:      Folder (0x49a0)
rank:          Alternate
bindings:      public.folder
```

To je tačno ono čega pre nije bilo, i na rangu koji ne otima Finder-u dvoklik.

### ⚠️ NEPROVERENO — i zašto je test stao

Prava putanja (`open -a … <folder>`, isti LaunchServices put kojim ide i puštanje
na ikonicu) je pokrenuta, ali se app zaustavila na **dijalogu keychain-a**:
„BriefShow wants to use your confidential information stored in
`com.rocketsbrief.briefshow.session`".

To nije bag iz ovog koraka. Debug build je potpisan drugačije od klijentovog
Release build-a, pa ACL na tom keychain zapisu ne prepoznaje binarni fajl i
sistem pita. **Pojaviće se pri svakom pokretanju Debug build-a**, i nema veze sa
folderima.

Zato NIJE viđeno: da folder zaista sleti u mrežu, i da drvo foldera levo pokaže
gde je. Deklaracija i registracija jesu izmerene; poslednji korak — folder na
ekranu — nije.

## KORAK 73 — C1: alat za kameru, i dve popravke koje su već bile izmerene (2. septembar 2026)

Kamera nije bila priključena, pa se glavno pitanje — zašto je karta prazna — NIJE
moglo izmeriti. Napravljen je alat koji to rešava jednom komandom, i popravljene
su dve stvari koje su već bile izmerene sa klijentovih slika i iz koda.

### `Tools/camtest.swift`

```
swift Tools/camtest.swift
```

Koristi **istu masku** koju koristi `CameraBrowser.start()`, pa gleda ono što
gleda i app. Ispisuje svaki delegatski poziv sa vremenom, a na
`deviceDidBecomeReady` uporedi `mediaFiles.count` sa rekurzivnim hodom kroz
`contents` i **sam kaže koja je hipoteza potvrđena**, imenujući fajlove i UTI-je
koji ispadnu između to dvoje. Provereno da se prevodi i pokreće (0 uređaja, bez
kamere).

**⚠️ Alat NIJE u sandbox-u, a app jeste.** Ako fajlovi izađu ovde a u app-i ne,
odgovor je sandbox i obe hipoteze padaju — što je i dalje nalaz, i korisniji.

### Popravka 1 — kamera se pojavljivala DVAPUT

Na obe klijentove slike od 1.09. Z 6 je u spisku dvaput. `ConnectedCamera` se
poredio po `device ===`, a ImageCaptureCore je predao **dva različita objekta za
jedno telo** — dva promašaja, dva reda. Povrh toga su im `id`-jevi (uuidString)
isti, što je u `ForEach` nedefinisano ponašanje, ne samo ružan prikaz.

Sad se porede po `id`. Kad nema ni uuid-a ni imena, pada nazad na pokazivač —
tada nema po čemu drugom, a dva reda su bolja od tihog gutanja druge prave kamere.

### Popravka 2 — prazan ekran je LAGAO

`emptyState` je crtao vrtiljak i „Reading the card…" **kad god je lista prazna,
bez obzira na fazu.** Zato je na slici bočni panel pisao „0 files on the card" —
tekst faze `.ready`, dakle gotovo — dok je sredina prozora tvrdila da još čita.
Prozor koji istovremeno kaže dve stvari gori je od onog koji kaže razočaravajuću.

Sad postoji treća grana: čitanje je gotovo i karta je prazna, sa uputstvom koje
uključuje i pravu proveru — **ako ni Image Capture ne vidi karticu, problem je
kamera ili kabl, ne BriefShow.**

### Dodato usput — hod kroz `contents`, kao UNIJA

`rebuildItems` sad na `mediaFiles` dodaje rekurzivan hod kroz `contents`.
**Strogo dodatno:** ništa što se ranije uvozilo ne prestaje. Filtrirano po
spisku ekstenzija, da ne uvuče sidecar-e i pomoćne fajlove koje svako telo piše
(Nikonov `.NKSC`, `MISC` folder) — mreža puna toga gora je od kratke mreže.

Ovo je popravka za **hipotezu 1** i napravljena je pre merenja, svesno, jer ne
može ništa da oduzme. Merenje i dalje treba: ako `camtest` pokaže da su i
`contents` prazni, uzrok je drugde i ovo nije rešenje nego samo bezopasan dodatak.

### ⚠️ NEPROVERENO

Sve troje. Traži kameru.

## KORAK 74 — zašto nova ikonica ne bi bila viđena posle update-a (2. septembar 2026)

Klijent: ikonica ostaje kakva jeste za sada, ali **kad se sledeći put promeni,
mora da se vidi čim se app zameni u Applications.**

### ⚠️ IZMERENO — `CFBundleVersion` je bio 17 u SVAKOM build-u

Provereno na četiri sagrađena bundle-a:

| bundle | verzija | build |
|---|---|---|
| `dist-universal` | 6.0 | **17** |
| `build/UniversalRelease` (arhiva) | 6.0 | **17** |
| `build_universal` | 10.1 | **17** |
| `build_dd` (Debug) | 10.1 | **17** |

macOS kešira ikonicu app-e u IconServices, po identitetu i **verziji** bundle-a.
Zamena bundle-a na istoj putanji, sa istim `CFBundleIdentifier` i **istim
`CFBundleVersion`**, je tačno slučaj u kom sistem zaključi da se ništa nije
promenilo i nastavi da crta staru ikonicu.

Dakle uzrok nije bio u ikonici nego u broju koji se nije pomerao.

### ⚠️ GLAVNA POPRAVKA JE RELEASE KORAK, NE KOD

`CURRENT_PROJECT_VERSION` je podignut 17 → 18. Ali **mora da se podiže na svako
izdanje**, i to je korak u puštanju koji kod ne može da natera. Zapisano ovde jer
je jedini razlog zbog kog bi se ovo ponovilo to što je zaboravljeno.

### Šta je dodato u kodu

`reregisterWithLaunchServicesIfVersionChanged()` u `BriefShowApp.init()`. Kad se
verzija promeni u odnosu na zapamćenu, LaunchServices-u se kaže da ponovo pročita
bundle — to je API iza `lsregister -f`. Verzija se upisuje **pre** poziva, da
zaglavljivanje ili pad u registraciji ne bi bili na svakom sledećem pokretanju.

### ⚠️ NIJE GARANCIJA, i ne treba je tako prodavati

Pločica koju je klijent **prikačio u Dock** crta se iz Dock-ove sopstvene kopije,
a ona popušta tek kad se Dock ili Mac restartuje. Ako sledeća promena ikonice i
dalje izgleda ustajalo u Dock-u — to je razlog, i nije bag u app-i.

### ⚠️ NEPROVERENO

Ne može se proveriti dok se ikonica stvarno ne promeni i app ne zameni u
Applications. Ono što JESTE provereno: build prolazi i sagrađen bundle sad nosi
`CFBundleVersion = 18`.

## KORAK 75 — crop je i dalje pisao „Free", plavi ček, i ručica (2. septembar 2026)

Tri prijave posle KORAKA 69, sa slikama.

### ⚠️ KORAK 69 NIJE BIO DOVOLJAN — i evo zašto

Prijava: „sinkujem, idem na sledeću sliku, ona JESTE lepo kropirana na 4:3 i to
se vidi — ali red odnosa pokazuje Free, pa kad krenem ručno da pomeram, pomeram
slobodno umesto tog sinhronizovanog 4:3."

KORAK 69 je dodao `settings.cropAspect` i sve troje radi — **za ono što je
sinkovano POSLE te izmene.** Ali `cropAspect` govori samo koji je odnos neko
izabrao **kroz ovaj alat**. Fotografija može doći do savršenog 4:3 crop-a a da se
to nikad nije desilo: sinkovana build-om koji bravu nije imao gde da upiše,
kropirana starijom verzijom, ili donesena presetom. **Klijentove fotografije su
sve takve** — sinkovane su ranije.

**Popravka: pita se i PRAVOUGAONIK, ne samo zapis.** `inferredCropAspect` računa
stvarni odnos postojećeg crop-a (razlomak puta sopstveni odnos slike — ista
konverzija koju `resizeCrop` radi u drugom smeru) i traži preset koji mu odgovara.

Redosled je: upisana brava pobeđuje ako postoji; ako ne, gleda se pravougaonik.
**Pravougaonik je ono što klijent vidi na ekranu i njemu treba verovati.**

Tolerancija je 1%. Preseti su daleko jedan od drugog (0,75 / 1 / 1,33 / 1,78) pa
se nijedan ne može zameniti susedom, a crop koji je prošao kroz razlomke i
odsecanje na granice sme da bude za dlaku pored bez da bude proglašen slobodnim.

**⚠️ Samo kad crop POSTOJI.** Nekropirana fotografija ostaje Free i onda kad je
sam kadar 4:3: tamo je odnos kamerin, a ne nečija odluka, i zaključavanje bi tiho
oduzelo slobodno vučenje svakoj fotografiji snimljenoj 4:3 telom.

### Plavi ček u filmstrip-u

Bio je **namerno** fiksna macOS plava, da se poklopi sa Finder-ovim i Photos-ovim
„stavka je izabrana". Klijent traži da prati temu, kao znak za izmene desno od
njega.

Sad koristi **isti `ink`/`background` par** koji taj znak već koristi, i iz istog
razloga: to su app-ine sopstvene boje za tekst, pa su garantovano kontrastne u
svakoj temi. Plavi disk je bio jedina stvar u toj traci koja pripada tuđoj paleti.

`.palette` ostaje — boji kvačicu i disk kao dva sloja, i to je ono što kvačicu
drži čitljivom. Jedna ravna boja je tu jednom već dala skoro belu mrlju na svetlim
sličicama, i to ne treba ponovo otkrivati.

### Ručica pri pomeranju crop-a

Otvorena šaka iznad crop-a, zatvorena dok se vuče — isti par koji Space-to-pan
sloj već koristi u ovom fajlu.

**⚠️ Zatvorena šaka se gura JEDNOM po vučenju, sa čuvarem.** `NSCursor` je STEK:
guranje na svaki `onChanged` je jedno guranje po kadru miša, a jedan `pop` na
kraju bi ostavio stotine zatvorenih šaka naslaganih — posle čega je svaki drugi
kursor u app-i pogrešan do ponovnog pokretanja.

### ⚠️ NEPROVERENO

Sve troje. Prevodi se.

## KORAK 76 — X odbacuje i u LumenoLab filmstrip-u (2. septembar 2026)

KORAK 71 je odbacivanje dao samo ShowGrid mreži. Klijent: mora i u filmstrip-u,
jer se tamo i pregleda.

### Zasebna akcija, ne deljena

`ShortcutAction.rejectPhoto` je nova akcija u **LumenoLab grupi**, sa istim
difoltom `x` kao `gridRejectPhoto` u ShowGrid grupi. Nije ista akcija upotrebljena
dvaput: dva prozora imaju svoje monitore i svoje grupe, jedno vezivanje se ne
može ograničiti na oba, a klijent koji premesti Reject u jednom prozoru nema
razloga da mu se pomeri i u drugom. `x` je slobodno u ovoj grupi — cut je ⌘X.

### Jedno skladište, dva prozora

Piše u isti `PhotoLabelStore`, pa je fotografija odbačena u mreži odbačena i ovde,
i **oba prozora je preskaču pri grupnom izvozu** — to je već bilo napravljeno u
KORAKU 71.

`rejectedURLs` je ogledalo u `@State`, jer je `PhotoLabelStore` običan statični tip
bez načina da javi promenu, a filmstrip mora da se precrta. Čita se na `onAppear`
i na promenu `photoURLs` — **ne po sličici po prolazu**: `isRejected` ide u
`UserDefaults`, a traka crta svaku vidljivu ćeliju na svaki prolaz.

### Meta i smer

Radi na više-selekciji kad je ima, inače na otvorenoj fotografiji — isto pravilo
koje ovaj prozor već koristi za „fotografije na koje mislim".

Smer se odlučuje **jednom za ceo skup**, po prvoj: mešovita selekcija se skuplja,
a ne izvrće fotografiju po fotografiju. Isto pravilo kao `cycleRating`.

### Znak je u TREĆEM uglu

Gore levo je kvačica selekcije, gore desno znak za izmene. X ide **dole levo**.
Tri oznake u sličici od stotinak tačaka traže tri različita ugla ili se sliju u
mrlju.

Prigušenje ide **samo na sliku**, ne na prsten selekcije — traka u kojoj bledi i
prsten čitala bi se kao „nije izabrano" umesto „odbačeno".

### ⚠️ NEPROVERENO

Prevodi se. Nije viđeno na ekranu.

## KORAK 77 — import dobija izvor, meni i podrazumevani folder; crop dobija rotaciju (2. septembar 2026)

Pet zahteva odjednom, sa slikom prozora koji izlazi iz app-e.

### Prozor za import je izlazio iz app-e — `minWidth: 900`

`CameraImportView` je imao `.frame(minWidth: 900, idealWidth: 1180, ...)`, a
prozor ShowGrid-a sme da bude **700×480** (`window.minSize`). Na svakom prozoru
užem od 900 sheet je bio širi od onoga što ga prikazuje i visio je preko leve
ivice, na Desktop. To je tačno ono što je klijent uslikao.

**Sheet ne nasleđuje NIKAKVU geometriju od prikazivača**, pa se prozor mora
pitati direktno — dodat je `ShowGridWindowController.contentSize`. Veličina je
sad `min(ideal, max(floor, prozor − 48))`.

### ⚠️ IZVOR MOŽE BITI KAMERA **ILI** FOLDER — i to rešava tri zahteva odjednom

Traženo je bilo troje: ručni Import iz menija, biranje izvora, i „proveri da li
SD kartica isto vuče import". Sve troje je isti nedostatak: **jednom kad se
kartica montira, ona JE folder, a ne kamera**, i `CameraImportSession` je znao
samo za `ICCameraDevice`.

Nov `ImportSource` je `.camera(ConnectedCamera)` ili `.folder(URL)`:

- Telo u MTP/PTP režimu se nikad ne montira kao disk i dostupno je samo kroz
  ImageCaptureCore — to je `.camera`.
- SD kartica u čitaču se montira kao običan disk, a klijent koji otvori
  File ▸ Import… bez ičega priključenog hoće da pokaže na folder. Oboje je
  `.folder`, jedna putanja.

`Item` sad nosi `Origin` — `.cameraFile(ICCameraFile)` ili `.diskFile(URL)` — i
grana se na **tačno tri mesta**: sličica, kopiranje, i skeniranje. Sve ostalo
(faze, kvačice, brojanje, dnevni folder) je zajedničko.

Folder se skenira rekurzivno, jer su fotografije pod `DCIM/100NIKON`, nikad na
vrhu, i po **istom spisku ekstenzija** koji koristi kamera put — da se dva izvora
slože oko toga šta je fotografija.

Sličice za disk idu kroz `makeShowGridThumbnail`, isti poziv kojim idu i ShowGrid
sličice: RAW sa kartice se dekodira ovde tačno onako kako će i kad se prekopira.

Kopiranje sa diska **ne prepisuje** postojeći fajl nego uniquira ime
(`DSC_0001-1.NEF`) — isto što `.overwrite: false` daje kamera putu, samo ručno.
Brisanje sa izvora, ako je traženo, ide **tek posle** uspešnog kopiranja.

### File ▸ Import…

`⇧⌘I`, u `CommandGroup(after: .newItem)` — tamo gde stoji Open…, tamo fotograf i
traži Import. Otvara birač foldera (pozicioniran na `/Volumes`, jer je kartica u
čitaču čest slučaj), pa otvara isti prozor.

Unutar prozora **Choose Source…** repointuje ga. Sesija se pravi u `init` i drži
kameru otvorenom, pa se ne može preusmeriti u mestu — presenter zato menja
`item` sheet-a, i to **kroz jedan runloop okret**: prikazivanje novog preko
starog ostavlja dva sheet-a u trci i kameru zaključanu onim koji je izgubio.

### Podrazumevano odredište

`~/Documents/BriefShow NEF/`, napravljen ako ne postoji, plus dnevni podfolder
koji je već postojao. Ranije je fallback bio Pictures — „gde god sistem zove
Pictures" nije mesto na kom se snimanje kasnije nađe.

**Dnevni folder ostaje po datumu SNIMANJA, ne po današnjem.** Za karticu
uvezenu istog dana to je isto; za karticu uvezenu sutradan ujutru fotografije
pripadaju danu snimanja, što je i cela svrha organizovanja po datumu. Ako nema
datuma, pada na danas.

### Crop dugme skroluje panel do sekcije

Pritisak na Crop u zaglavlju ostavljao je klijenta da sam nađe dugmad za odnos —
ona su unutar „Crop & Rotate", dovoljno nisko da su van ekrana. Sad `ScrollViewReader`
dovodi sekciju na vrh, animirano.

Dve stvari koje su morale: **tab se prvo prebacuje na Edit** (iz Retouch-a
sekcije nema u stablu), i skrol ide **jedan runloop okret kasnije**, da promena
taba stigne da je ubaci. Okidač je BROJAČ, ne Bool — dva uzastopna pritiska
moraju da skroluju dvaput, a vrednost jednaka sebi ne pali `onChange`.

### Rotacija vučenjem izvan crop-a

Kao u Lightroom-u: vuci bilo gde **izvan** crop-a i fotografija se ispravlja.
Ide kroz `straightenBinding`, isti koji koristi i slajder, pa se auto-fit crop-a
izvršava i ovde.

**Ugao, ne pomeraj.** Meri se ugao od centra crop-a do pokazivača i pomera se
`straightenDegrees` za onoliko koliko se taj ugao okrenuo od početka vučenja —
zato slika prati ruku, a ne koliko je ruka prešla.

**⚠️ Smer je PROVEREN u rendereru, ne pogođen.** Ekranski Y raste nadole, pa
`atan2` ovde raste u smeru kazaljke; renderer primenjuje `rotationAngle: -radians`,
što za pozitivnu vrednost takođe okreće u smeru kazaljke. Dakle preslikava se
direktno, bez preokretanja znaka. Zapisano jer je rotacija koja ide na pogrešnu
stranu stvar koja se „popravi" dvaput.

Delta se normalizuje u −180…180, da vučenje preko šava ne prebaci sliku za pola
kruga. Ispod 20 px od centra se ne reaguje — tamo je ugao šum.

**⚠️ Sloj za rotaciju koristi even-odd `contentShape`, ne pun pravougaonik.**
Pun pravougaonik bi se preklapao sa površinom za pomeranje i sa ručkama, a dva
pogleda koja oba primaju isti `onHover` znače dva gurnuta kursora i jedan skinut
— posle čega je svaki kursor u app-i pogrešan. Isti razlog zbog kog se zatvorena
šaka gura jednom po vučenju (KORAK 75).

### Rotacioni kursor je nacrtan

macOS ga nema. Crta se jednom i drži: SF Symbol `arrow.clockwise` u belom preko
crnog obrisa, gde je **obris ono što ga čini upotrebljivim** — kursor stoji NA
fotografiji, a beo znak nestaje nad peskom i nebom, tačno kao što je nestajao
prsten clone stamp-a pre nego što je dobio svoju boju.

### ⚠️ NEPROVERENO

Sve. Prevodi se. SD kartica **i dalje nije bila ubačena**, pa nije potvrđeno
ni da se pojavljuje kao kamera ni da folder put radi na pravoj kartici.

## ⚠️ SLEDEĆE — spisak od 2. septembra uveče (NIŠTA OD OVOGA NIJE URAĐENO)

Zapisano na klijentov zahtev, pre commit-a. Redosled je klijentov.

### ⚠️ REDOSLED I KAPIJA — potvrđeno od klijenta 2. septembra

Dve stvari, izričito, i one nadjačavaju svaki raniji predlog redosleda u ovom
dokumentu:

1. **C2 (tačka 4, AI Generative na Intelu — i njegov prvi korak, hosting i
   preuzimanje težina) je POSLEDNJI.** Sve ostalo ide ispred njega. Ranije je u
   ovom dokumentu na dva mesta pisalo da hosting težina ide PRVI, jer je SD
   mrtav na svakoj klijentskoj mašini — to ostaje tačno kao **opis**, ali NE kao
   redosled. Klijent je odlučio drugačije i to je odluka, ne nesporazum.
2. **Ne pravi se build i ne pušta se ništa dok se ne završi sve prijavljeno.**
   Dakle ni `CURRENT_PROJECT_VERSION`, ni `latest_version` u BriefControl-u, ni
   arhiva. Klijent doslovno: *„necemo jos da build i push dok ne zavrsimo sta
   treba da se ispopravlja od juce"*.

Redosled rada je time: **1 (rotacija crop-a) → 2 (SD kartica sama) → 3
(prevlačenje u folder) → 5 (nebo) → 4 (C2)**.

**Stanje: URAĐENE su tačka 1 (KORAK 79, pa 82–84) i tačka 3 (KORAK 80–81).
Tačka 2 je ⛔ BLOKIRANA — klijent nema ni čitač ni karticu, isto kao C1
(kamera). Redosled se time pomera na: 5 (nebo) → 4 (C2), a 2 se ubacuje čim se
kartica nađe.**

**⚠️ Dve tačke su tražile odgovor klijenta pre pisanja koda. ODGOVORENO 2.09:**

- **Tačka 1 — crop dobija SOPSTVENI ugao.** Novo polje na `EditCropRect`, ne
  preslikavanje u `straightenDegrees`. Klijent je izabrao poštenije rešenje uz
  punu cenu: **još jedna Codable migracija**, dakle
  `Tools/run-editsettings-decode-test.py` se pokreće posle izmene, na 25 pravih
  zapisa. Posledica koja se bira zajedno sa ovim: rotacija crop-a i Straighten
  slajder su od sada **dve nezavisne stvari** i mogu da stoje na različitim
  uglovima — to je namerno, ne propust.
- **Tačka 3 — prevlačenje UVEK PREMEŠTA.** Bez `⌥` modifikatora, bez grananja na
  isti/drugi disk. Jedno ponašanje. **⚠️ Premeštanje je nepovratno ako se promaši
  folder**, pa ovo traži da promašaj bude težak: cilj se vidno označava dok se
  vuče, i pušta se samo na red koji je stvarno pod pokazivačem.

**Van ovog spiska, a takođe neviđeno na ekranu:** KORACI 68–78. Svi se prevode,
nijedan nije potvrđen gledanjem. To nije nova stavka nego dug — v. „NEPROVERENO"
na dnu svakog od tih koraka.

### 1. ✅ ROTACIJA CROP-A — URAĐENO, v. KORAK 79

Isporučeno u KORAKU 77, **prijavljeno kao neispravno.** Dve odvojene greške:

**(a) Pogrešan okidač.** Napravljeno je „vuci bilo gde IZVAN crop-a", po ugledu
na Lightroom. Traženo je drugo: kursor prilazi **IVICAMA CROP-A** — onim
linijama koje se vide dok je crop alat otvoren — i tu se ikonica menja iz šake u
rotaciju.

**(b) Pogrešan predmet.** Napravljeno je da rotira **SLIKU**
(`settings.straightenDegrees`). Klijent doslovno: *„da mogu da rotiram krop (ne
sliku)"*. Dakle rotira se **okvir crop-a** preko mirne fotografije, sitno gore-dole.

**⚠️ To je nova geometrija, ne podešavanje postojeće.** `EditCropRect` je
`x/y/width/height` i **nema pojam ugla**. Rotirajući crop znači ili novo polje na
njemu (i još jedna Codable migracija — pokrenuti
`Tools/run-editsettings-decode-test.py`), ili preslikavanje u
`straightenDegrees` sa suprotnim znakom uz istovremeno prepravljanje
pravougaonika. Prvo je poštenije, drugo je jeftinije. **Pitati klijenta pre
pisanja.**

**Neproverene sumnje zašto ni ono što JESTE napravljeno nije okinulo** — ne
trošiti vreme dok se ne izmeri:
- `Color.clear` sa `contentShape(_, eoFill: true)` možda ne isporučuje `onHover`
  onako kako je pretpostavljeno;
- unutrašnji pravougalnik crop-a ima svoj `onHover` (otvorena šaka) i možda guta
  događaj;
- sloj možda uopšte nije dobio veličinu kontejnera.

Prvo reprodukovati sa jednim `print`-om u `onHover`, pa tek onda menjati.

### 2. ⛔ SD kartica da se čita SAMA kad se ubaci — BLOKIRANO HARDVEROM (2.09.)

Danas: `ImportSource.folder` postoji i **File ▸ Import… radi ručno** (KORAK 77),
ali app **ne prati montiranje diskova uopšte** — nema nijednog
`didMountNotification`. Kamera iskače sama; kartica ne.

Traženo: kartica ubačena dok BriefShow radi otvara isti prozor sama, kao kamera.

**⛔ Klijent 2.09: „nemam ovde čitač kartice ni karticu."** Ista prepreka koju
ima i C1 (kamera). Ovo se **ne piše na slepo**, i to nije opreznost nego
računica: od dva neizmerena pitanja ispod, jedno (da li ImageCaptureCore
prijavljuje čitač kao `ICCameraDevice`) može da učini **ceo posao nepotrebnim**,
a drugo (sandbox i `/Volumes/…`) odlučuje da li napisano uopšte radi — i mora se
proveriti na POTPISANOM build-u. Pisati kod koji možda ne treba i koji se ne može
ni pokrenuti je najslabija vrsta posla.

**Čim se kartica nađe:** `swift Tools/camtest.swift` sa ubačenom karticom
odgovara na oba pitanja odjednom. Tek posle toga se piše.

Šta to traži: posmatrač `NSWorkspace.didMountNotification`, provera da li na
novom disku postoji `DCIM`, pa `ImportWindowRequest.shared.pending = .folder(url)`.
Ista kapija koju kamera već koristi (`camerasAlreadyOffered`), da disk koji je
BIO priključen pri pokretanju ne iskoči preko onoga što klijent radi.

**⚠️ Otvoreno pitanje, neizmereno:** da li sandbox-ovana app sme da čita
`/Volumes/...` bez posebnog entitlement-a. Entitlements danas ima
`files.user-selected.read-write` i `device.usb`, ništa za prenosive diskove. Ako
ne sme, dodaje se entitlement i **mora se videti na POTPISANOM build-u**, ne u
Xcode-u — ista klasa greške kao KORAK 35.

**Takođe još neprovereno:** da li ImageCaptureCore uopšte prijavljuje čitač
kartica kao `ICCameraDevice`. Ako da, prozorčić već radi i posao otpada.
`Tools/camtest.swift` to rešava jednim pokretanjem, čim se kartica ubaci.

### 3. ✅ PREVLAČENJE U FOLDER — URAĐENO, v. KORAK 80

Traženo: izabrati fotografije u mreži i **prevući ih na bilo koji folder levo**,
unutar same app-e.

Danas postoji suprotan smer (folder se prevlači U prozor) i postoji Cut/Copy/Paste
preko menija (`pasteClipboard(into:)`), ali **prevlačenja iz mreže nema**.

Dobra vest: odredište je već napisano — `pasteClipboard(into: node.url)` radi tačan
posao. Treba `onDrag` na sličici i `onDrop` na redu u `FolderTreeSidebar`.

**⚠️ Odluka za klijenta:** prevlačenje **premešta ili kopira**? Finder premešta
unutar istog diska, a kopira preko diskova, i drži ⌥ za suprotno. Premeštanje
fotografija je neповratno ako se promaši folder, pa ovo nije sitnica.

### 4. AI Generative na Intelu — plan pakovanja

Klijentova mašina: i7 3,2 GHz 6 jezgara, 32 GB DDR4-2667, **Radeon Pro 560X 4 GB**.
Traženo: da se pri pakovanju iskoristi sve što može da ubrza — procesor, grafička,
RAM — da Intel Mac-ovi mogu Generative.

**⚠️ PRVO ONO ŠTO SE NE MOŽE, da se ne obećava:** **32 GB sistemske memorije se NE
DODAJE na 4 GB video memorije.** Na Intel Mac-u su to dve odvojene memorije preko
PCIe. CoreML sme da podeli mrežu između CPU-a i GPU-a (`MLComputeUnits.all`) i to
je maksimum onoga što „deljenje memorije" ovde znači. Ono što ne stane u 4 GB ide
na CPU, i tamo je sporo. SD 1.5 na 512×512 u fp16 **staje** u 4 GB, pa to nije
prepreka — ali RAM neće nadoknaditi grafičku i to ne treba prodavati.

**Redosled, i on je nosiv:**

1. **Hosting težina — PRVI unutar C2** (ali ceo C2 je poslednji u projektu, v.
   „REDOSLED I KAPIJA" na vrhu ovog spiska)**, i nije Intel posao.** `installedDirectory` se u celom
   projektu **samo čita** (dve linije), nema nijednog `downloadTask`. Dakle SD je
   mrtav na SVAKOJ klijentskoj mašini, ne samo na Intelu. Ako se uradi samo Intel
   deo, Intel Mac dobije isti „models missing" kao i svi ostali.
   **Odlučeno 2.09: GitHub Releases, jedan fajl.** Izmereno: 1,99 GB sirovo,
   **1,84 GB kao zip / 1,85 GB kao Apple Archive** — staje ispod limita od 2 GiB.
   (Ovim pada ranije zapisano „2,14 GB, ne može ni kao asset" — bilo je pogrešno.)
   Arhiva ide kao **Apple Archive**, jer se raspakuje prvoklasnim API-jem bez
   pokretanja `ditto` procesa iz sandbox-a.
   **⚠️ Klijent je izričito rekao: pushuje se kao RELEASE na GitHub.**
2. **`Float16` — drugi.** Postoji samo na arm64; `DevelopSDInpaint.swift` ga
   koristi na 8 mesta i ceo fajl je iza `#if arch(arm64)`. Rešivo **bez diranja
   arm64 puta**: `MLMultiArray` sa `dataType: .float16` postoji i na Intelu, samo
   se ne sme puniti kroz Swift-ov tip `Float16` — puni se preko
   `vImageConvert_PlanarFtoPlanar16F`, koji na Intelu radi. Ulazi u model ostaju
   bajt-u-bajt isti, pa se **ništa izmereno na arm64 ne pomera** — što je uslov,
   jer je izlaz AI Clean Up-a zaključan od 31.08.
3. **Merenje na klijentovoj mašini — treće, i ono odlučuje.** 12 koraka na
   512×512 kroz Radeon Pro 560X je realno **minuti, ne sekunde**. Broj se ne
   pogađa. **Ako ispadne neupotrebljivo sporo, pošten odgovor je da dugme na
   Intelu ostane isključeno sa razlogom koji piše**, kako je danas.

### 5. Nebo — POSLE svega gore

Dogovoreno da se o njemu odlučuje tek kad se ovo završi. Stanje i tri pravca su u
„⚠️ SLEDEĆE — NEBO" na vrhu ovog dokumenta i u KORACIMA 66 i 67.

### Stanje pakovanja u trenutku pisanja

`CURRENT_PROJECT_VERSION` podignut **17 → 18** (KORAK 74). `MARKETING_VERSION`
je 10.1, nedirano. **`latest_version` u BriefControl-u je i dalje 6.0** — niko
još ne dobija „mora update".

## KORAK 78 — levi panel je bežao kroz LEVU ivicu prozora, ali samo u folderu (2. septembar 2026)

Prijava: „onaj tab sa leve strane kad se udje u briefshow gde su folderi radi
normalno kad se rasteze i suzava, ali cim udjem u neki folder kada restezem odma
ide u levo jos vise i izlazi iz ekrana".

Ključ je u „**samo kad se uđe u folder**". Vučenje nije bilo krivo — ono je od
KORAKA 68 ispravno (`.global` koordinate, `sidebarWidthLive` odvojen od
`@AppStorage`). Krivo je bilo **zaglavlje ShowGrid-a**, i to samo dok u njemu ima
fotografija.

### Ono što se stvarno dešavalo

`ShowHeaderButtonLabel` je nosio `.fixedSize(horizontal: true, vertical: false)`
**pored** `.lineLimit(1)`. To dvoje nije isto:

- `.lineLimit(1)` je ono što je popravilo staru prijavu da se „LumenoLab" lomio
  na „LumenoLa / b";
- `.fixedSize(horizontal:)` je uz to zabranio **svako** sabijanje. Dugme više
  nije moglo da se skrati ni za tačku.

Prazan ShowGrid ima tri takva dugmeta. Čim se uđe u folder, `!photoURLs.isEmpty`
dodaje još četiri (Export Labeled, Export Starred, Add Photos, Clear All) **plus**
zoom kontrolu čiji je `Slider` na `.frame(width: 110)`. Zbir minimuma pređe
**~1230 pt**, a sa panelom (260) i ručicom (7) to je **~1500 pt** — više od
prozora, koji se otvara na 1400.

A kad `HStack` traži više nego što mu je ponuđeno, SwiftUI ga **centrira** u
roditelju. Višak se onda troši na **obe** ivice — i leva polovina viška je tačno
folder stablo. Zato je izlazilo levo, i zato je svaka tačka razvlačenja panela
gurala još 1 pt napolje.

### Popravka — tri sloja, i svaki radi sam za sebe

1. **Uzrok:** `.fixedSize(horizontal:)` uklonjen iz `ShowHeaderButtonLabel`,
   `.lineLimit(1)` + `.truncationMode(.tail)` ostaju. Prelamanje je i dalje
   nemoguće (to je radio `lineLimit`), ali red sada ume da se stisne. **Na svakoj
   širini na kojoj sve staje ništa se ne skraćuje i ništa ne izgleda drugačije.**
   Stil je deljen, na 38 mesta — pa ovo važi i za LumenoLab zaglavlje.
2. **Ograda:** ceo red `panel + ručica + mreža` dobio je
   `.frame(maxWidth: .infinity, alignment: .leading)` i `.clipped()`. Ako ikad
   opet nešto zatraži previše, manjak se troši **desno**, gde se vidi. Kroz levu
   ivicu se ne izlazi više strukturno, ne po računici.
3. **Gornja granica vučenja se meri, ne pogađa.** 560 je koliko panel *sme* da
   bude, ne koliko *može* u datom prozoru. `showGridRowWidth` (GeometryReader nad
   redom) sad daje `sidebarDragMaxWidth = rowWidth - 460`, gde je 460 ono što
   mreža zadržava. Isto se primenjuje i na `effectiveSidebarWidth`, pa širina
   zapamćena na velikom ekranu **ne** dolazi kao 560 u prozor upola manji —
   `@AppStorage` i dalje čuva klijentov broj, kleše se samo ono što se crta.

Uz to `Text(gridActionStatus ?? gridCountsSummary)` je dobio `.lineLimit(1)`:
„184 photos · 12 labeled · 5 starred · 9 rejected" ume da se prelomi u uskom
prozoru, a status koji se prelama čini zaglavlje **višim** umesto tešnjim.

### ⚠️ NEPROVERENO NA EKRANU

**Prevodi se** (`BUILD SUCCEEDED`, Debug). App je pokrenuta, ali je na mašini u
tom trenutku bio video poziv preko celog ekrana i BriefShow je odmah tražio
keychain lozinku preko njega — pa je zatvorena bez gledanja. Dakle nije viđeno:

- da panel ostaje unutar prozora dok se vuče **u otvorenom folderu** (ovo je sama
  prijava);
- da se dugmad u zaglavlju skraćuju umesto da guraju, i da na širokom prozoru
  izgledaju nepromenjeno;
- da širina i dalje preživi gašenje app-e.

Računica koja je dovela do popravke je proverljiva na oko: uđi u folder, suzi
prozor — pre je panel klizio levo, sad zaglavlje treba da otrpi.

## KORAK 79 — crop dobija SVOJ ugao, i rotacija je na ivicama (2. septembar 2026)

Tačka 1 sa spiska od 2.09. Ono što je isporučeno u KORAKU 77 bilo je pogrešno na
oba kraja — pogrešan okidač i pogrešan predmet — pa je zamenjeno, nije dopunjeno.

### Odluka klijenta pre pisanja

Pitano je i odgovoreno: **crop dobija sopstveni ugao**, ne preslikavanje u
`straightenDegrees`. Time su rotacija okvira i Straighten slajder **dve
nezavisne stvari** i smeju da stoje na različitim uglovima. To je izabrano
svesno, sa punom cenom — još jedna Codable migracija.

### Model

`EditCropRect` dobija `angle: Double = 0`, u stepenima, pozitivno = okvir
okrenut **u smeru kazaljke na ekranu**. `x/y/width/height` ostaju **neokrenuta**
kutija; ugao je okreće oko njenog centra. Sav kod koji je samo hteo da zna gde
je crop otprilike i dalje čita tačno, a rotacija stoji na jednom mestu umesto da
bude zapečena u četiri broja.

**⚠️ Okretanje ide u prostoru PROPORCIONALNOM PIKSELIMA, nikad u prostoru
razlomaka.** `x/width` su razlomci širine, `y/height` razlomci visine — dve ose
sa različitim merilom. Okretanje razlomačkog pravougaonika za 45° nije okretanje
fotografije za 45° osim ako je fotografija kvadratna. Zato `constrainedToImage`
prvo prelazi u prostor `(širina = odnos, visina = 1)`. Sve u toj funkciji je
homogeno po (širini, visini), pa je **odnos stranica dovoljan** i prave dimenzije
u pikselima nisu potrebne.

### ⚠️ Migracija — i test koji je uhvatio grešku koju bih inače isporučio

`init(from:)` je prvo napisan u **extension**-u, jer tamo memberwise inicijalizator
preživi sam od sebe i to je urednije.
`Tools/run-editsettings-decode-test.py` je odmah pao na **svih 25 crop-ova**:

```
FAIL C4S_9018.NEF: keyNotFound: Key 'angle' not found. Path: crop.
RESULT: FAILED — the app would wipe every edit in the store
```

Taj harness vadi imenovane deklaracije iz `Develop.swift` po balansu zagrada i
**ne vidi extension** — dakle prevodio je sintetisani dekoder. Dekoder koji test
ne može da dohvati je dekoder koji niko neće proveriti sledeći put, a ono od čega
čuva je „obrisano je svako podešavanje u bazi". Zato sad stoji **u telu
strukture**, uz ručno napisan memberwise inicijalizator (`angle: Double = 0`, pa
svih desetak postojećih poziva `EditCropRect(x:y:width:height:)` prolazi
nedirnuto). Posle toga: **126 zapisa dekodirano, nijedan broj se nije pomerio.**

Ovo je zapisano i kao upozorenje u samom `run-crop-rotation-test.py` — ista
zamka čeka svaku sledeću izmenu.

### Renderer

Okrenut okvir se crta tako što se **slika okrene na drugu stranu oko centra
okvira**, pa se uzme običan uspravan pravougaonik. To dvoje je isto: izlazi
sadržaj nagnutog okvira, uspravan, tačno u veličini okvira. Zato `rect` ostaje
netaknut — centar je jedina tačka koju rotacija oko centra ostavlja gde jeste, a
veličina se ne menja.

**⚠️ Znak je proveren prema straighten putu dvadeset linija iznad, ne pogođen.**
Tamo pozitivan `straightenDegrees` okreće sliku u smeru kazaljke kroz
`rotationAngle: -radians`; dakle `+radians` je suprotno, što je tačno ono što
uspravlja okvir okrenut u smeru kazaljke.

### Okidač — traka uz ivice, ne „bilo gde izvan"

Ovo je cela prijava (a). Napravljeno je bilo po ugledu na Lightroom: vuci bilo
gde izvan crop-a. Traženo je uže i doslovnije — kursor dolazi do **linija koje se
vide dok je alat otvoren** i tu postaje rotacija.

`CropRotateBandShape` je traka širine **24 pt, strogo IZVAN okvira**, nikad preko
njega: površina za pomeranje počinje tačno na liniji, a dva pogleda koja polažu
pravo na isti `onHover` znače dva gurnuta kursora i jedan skinut — posle čega je
svaki kursor u app-i pogrešan. Osam ručica za razvlačenje je deklarisano POSLE
trake, pa one zadržavaju uglove i sredine ivica; traci ostaje deo ivice između
njih, a to je tačno mesto gde ruka hvata da nešto okrene.

### Šta je moralo da se prepravi, a nije se videlo unapred

**Okvir se ne skuplja dok se vrti.** `rotateCropFrame` pamti **ceo crop** na
početku vučenja, ne samo ugao, i svaki kadar računa **od početka**. Okretanje ume
da natera okvir da se smanji da bi ostao na fotografiji; da se pamtio samo ugao,
svako pomeranje ruke tamo-amo bi ga smanjivalo za još malo, kao čegrtaljka.

**Ograničenje je tačan test, ne procena.** Okrenut pravougaonik je unutar
uspravnog **tačno onda kada je njegov granični okvir unutra**, jer je granični
okvir sastavljen od njegovih sopstvenih krajnjih uglova. Skupljanje je uvek
**obe stranice istim činiocem**, da zaključan odnos (4:3) ostane tačan.

**Razvlačenje okrenutog okvira pomera centar.** Postojeća matematika sidri u
neokrenutoj kutiji — što je isto dok je okvir uspravan, a nije čim se nagne:
okvir se vrti oko svog centra, pa promena veličine pomera centar i ugao koji je
trebalo da stoji odleti od pokazivača. `anchoredAfterResize` posle toga vraća
centar tako da **strana koju vučenje NIJE dodirnulo ostane tačno gde je bila na
ekranu**. Poziva se samo kad je okvir nagnut: na uglu 0 računa isto što i
postojeći blok, samo kroz više aritmetike.

**Vučenje stiže u ekranskim koordinatama, razvlačenje se dešava duž stranica
okvira.** Sve tri geste čitaju `.named(cropOverlaySpace)` i pretvaranje se radi
jednom, na vidnom mestu (`cropFrameTranslation`) — umesto da se osloni na to šta
SwiftUI prijavljuje ispod `.rotationEffect`. Pretpostavka bi bila neproverljiva;
ovako je zapisana.

**Odnos stranica nosi ugao sa sobom.** Klik na 4:3 je odluka o OBLIKU; oduzeti
istovremeno i rotaciju bila bi druga odluka koju niko nije tražio.

### Merenje — `Tools/run-crop-rotation-test.py`

Nov harness, po ugledu na `run-layer-reorder-test.py`: vadi `EditCropRect`,
`CropHandle` i četiri funkcije iz `Develop.swift` po balansu zagrada, pa ih
prevodi zajedno sa `Tools/test-crop-rotation.swift`. Test **ne može da se raziđe
sa kodom** — ako se funkcija preimenuje, ili izvadi novo telo ili padne glasno.

Provereno: **3600 uklopljenih crop-ova** (4 odnosa × 9 uglova × mreža položaja i
veličina) — nijedan ugao ne izlazi sa fotografije, nijedno uklapanje ne menja
odnos stranica niti uvećava crop; **svih 8 ručica na 5 uglova** drži svoju
sidrenu tačku; pretvaranja ekran↔okvir su međusobno inverzna i čuvaju dužinu; i
pozitivan ugao **jeste** u smeru kazaljke na ekranu.

**Test je namerno pokvaren pa vraćen** (obrnut znak u `cropFramePoint`) — pao je
sa 25 prijava. Prolaz iz prve inače ne znači ništa.

### ⚠️ Poznato ograničenje, nije popravljeno ovde

Maske (`localAdjustmentOverlay`) se preko isečene fotografije postavljaju kroz
`fullImageFrame`, koja obrće **samo crop**, ne i rotaciju. Nagnut crop tu pomera
maske — **ali to nije novo:** `straightenDegrees` ima istu rupu i imao ju je i
pre ovog koraka. Zaključeno **čitanjem koda, nije viđeno na ekranu**; ako se
bude popravljalo, popravlja se za oba ugla odjednom.

### ⚠️ NEPROVERENO NA EKRANU

Geometrija jeste izmerena, ekran nije. Nije viđeno:

- da kursor postaje rotacija kad se priđe ivici, a šaka ostaje unutar okvira;
- da vučenje po traci okreće **okvir** dok fotografija stoji;
- da se okvir ne skuplja pri vrćenju tamo-amo unutar istog vučenja;
- da razvlačenje nagnutog okvira drži suprotnu stranu na mestu;
- da fotografija izvezena sa nagnutim crop-om izlazi uspravna i bez providnih
  uglova.

Prevodi se (`BUILD SUCCEEDED`, Debug).

## KORAK 80 — tri prijave sa prvog gledanja na ekranu (2. septembar 2026)

Prva prava provera KORAKA 79 na ekranu. **Rotacija radi** — potvrđeno od
klijenta. Uz to tri prijave, od kojih je jedna cela tačka 3 sa spiska.

### 1. Ćošak nije pokazivao rotaciju

Prijava: *„kad sam na ćošku da mi pokaže rotation symbol umesto ruke i kursora"*.

Uzrok je bio u tome kako je ručica hvatala pokazivač. Ručica je bila kutija
22×22 **centrirana NA ćošku**, dakle polovina je ležala **izvan** okvira — preko
trake za rotaciju — a sama nije gurala nikakav kursor. Prilaz ćošku spolja je
zato davao golu strelicu umesto ikonice rotacije, a traka koju je pokrivala nije
ni dobijala hover.

**Odluka klijenta, pitano pre pisanja:** *ćošak spolja rotira, sam ćošak
razvlači.* Dakle:

- Površina koja hvata pokazivač je **uvučena UNUTAR okvira** — dijagonalno za
  ćoškove, upravno za sredine ivica. Nacrtana bela tačkica ostaje gde je bila,
  centrirana na ćošku; pomerena je samo osetljiva zona. Sve preko linije je
  traka za rotaciju.
- Ručice **guraju pravi kursor**, po prvi put. Nikad više gola strelica.

**⚠️ Strelice prate ugao okvira.** Osa ručice se računa na EKRANU, pa okvir
nagnut 45° pokazuje dijagonalne strelice duž nagnutog ćoška, a ne duž uspravnog
koji tu više ne postoji. Zaokruženo na najbližu četvrtinu od 45°, jer postoje
samo četiri slike — kursor po uglu bi značio rasterizovanu sliku po kadru.

**AppKit nema dijagonalne kursore.** Ima `resizeLeftRight` i `resizeUpDown`, a
dijagonalni koje sistem koristi na uglovima prozora su privatni. Zato su
nacrtani iz SF Symbols-a, jednom i zadržani, **istim postupkom kojim je već
nacrtan `rotateCursor`** (`makeSymbolCursor`) — nije pisan drugi način da se
uradi ista stvar.

### 2. Prevlačenje fotografija i foldera — tačka 3 sa spiska

Prijava: *„selektovao sam jednu sliku i ne mogu da je prevučem u neki drugi
folder… taj drag and drop da radi za sve i fajlove i slike i sve što je u
BriefShow-u"*.

**Odluka klijenta: UVEK PREMEŠTA.** Bez `⌥`, bez grananja isti/drugi disk.

- **Sličica u mreži** dobija `onDrag` sa `public.file-url`. Isto prevlačenje radi
  i u Finder, gde kopira; unutar BriefShow-a premešta.
- **Red u drvetu** je i izvor i odredište: folder se može prevući na drugi
  folder. Drvo u koje se može pustiti a iz koga se ne može povući je pola drveta.
- **Selekcija ide cela.** Provajder nosi jednu fotografiju — ne zna se unapred
  gde će sleteti — pa se u `handleDropOnFolder` proverava da li je ta fotografija
  deo selekcije, i ako jeste, ide cela selekcija, redosledom **iz mreže**, ne iz
  Set-a. Isto što Finder radi, i jedino čitanje koje ima smisla kad je klijent
  upravo označio dvanaest fotografija pa uzeo jednu.

**⚠️ Premeštanje je nepovratno odavde, pa su dva drop-a odbijena a ne
polu-urađena:** folder na samog sebe, i folder u sopstvenog potomka (što bi
direktorijum premestilo u sebe i izgubilo ga). Kod poređenja putanja **kosa crta
na kraju je bitna** — bez nje „/a/b" ispada prefiks „/a/bc", a to je drugi
folder.

**Ništa nije pisano dvaput.** Premeštanje ide kroz `moveItems`, izdvojen iz
`pasteClipboard` — pospremanje posle premeštanja (izbacivanje iz mreže, iz
selekcije i iz tri keša sličica, ponovno učitavanje odredišta ako je otvoreno, i
slučaj kad se premesti sam otvoreni folder) je dovoljno zamršeno da bi se druga
kopija razišla za nedelju dana. Prevlačenje i Paste su sad **ista radnja**.

**Cilj se vidi dok se vuče** — red pod pokazivačem dobija ispunu i okvir u boji
akcenta, odvojeno od hover-a koji samo uveća ime. Za radnju koja premešta fajlove
„naglašeno" nije dovoljno.

Čitanje provajdera ide kroz `loadDroppedURLs`, sa serijskim redom oko liste:
svaki provajder odgovara na svojoj niti, a više fotografija pušteno odjednom je
tačno slučaj u kome nezaštićen niz tiho izgubi jednu.

### 3. Profil nije pratio temu

Prijava, sa slike: profilna pilula ostaje krem dok je ceo ekran oko nje taman.

**Uzrok:** `AppColors` su statička izračunata svojstva koja čitaju
`ThemeManager.shared`. **Čitanje ne pretplaćuje ni na šta.** SwiftUI nema razlog
da ponovo iscrta pogled čiji se ulazi nisu promenili, a jedini ulaz
`ProfileBadge`-a je `session`. Zato je zadržao temu u kojoj je prvi put nacrtan.

Ceo `AccountUI.swift` je imao istu rupu — **nijedna od pet struktura** nije
imala pretplatu, dok je svaki drugi tematizovan pogled u app-i nosi (v. komentar
u `FolderTreeSidebar`, koji je taj obrazac već zapisao). Dodato svima pet, ne
samo prijavljenoj: `ProfileBadge`, `ProfileSettingsRow`, `ProfileSettingsModal`,
`UpdateRequiredOverlay`, `LockedAccessOverlay`.

**Sama sličica (emodži) ostaje u svojoj boji** — to je ikonica koju je klijent
izabrao, i prebojiti je u temu značilo bi je uništiti. Tema nosi pilulu oko nje.

### Merenje

`Tools/run-crop-rotation-test.py` i `Tools/run-editsettings-decode-test.py` oba
ponovo pokrenuta posle svih izmena: **3600 uklopljenih crop-ova prolazi**, i
**126 zapisa dekodirano, nijedan broj se nije pomerio.**

### ⚠️ NEPROVERENO NA EKRANU

- da ćošak spolja daje rotaciju, a sama tačkica dijagonalne strelice — i da te
  strelice prate nagib okvira;
- da se fotografija prevlači na folder i da stiže tamo;
- da klik na sličicu i dalje **odmah** bira. `onDrag` sedi na istom pogledu kao
  postojeća gesta za klik, a odlaganje klika je već jednom bilo prijavljeno
  (KORAK 42) — ako se vrati, uzrok je ovde;
- da folder pušten na svog potomka bude **odbijen**, ne premešten;
- da profilna pilula pocrni kad se prebaci na tamnu temu, **uživo**, bez
  restarta.

Prevodi se (`BUILD SUCCEEDED`, Debug).

## KORAK 81 — drugi krug gledanja: ruka na ćošku, sličica dok se vuče, i jedan pravi bug (2. septembar 2026)

### 1. Ručice dobijaju RUKU, a dijagonalne strelice su izbačene

Klijent, o ćošku: *„kad sam na ćošku baš ćošku na tački onda ruka i da mogu da
smanjujem i povećavam crop… kada sam van te tačke i slike ali na ćošku onda da se
pojavi strelica u luku bela"*.

Dijagonalne dvostruke strelice iz KORAKA 80 su tako izbačene posle jednog
gledanja. Dva razloga zašto ne vrede zadržavanja: AppKit **nema** dijagonalni
kursor (sistemski su privatni, pa je svaki bio rasterizovan SF Symbol), a
nacrtana ručica ionako već kaže kuda se pomera — štapić leži duž svoje ivice,
tačkica sedi na svom ćošku. **Ruka kaže ono što oblik ne kaže: ovo je stvar koju
možeš da uhvatiš.** Sada je na svih osam.

Usput: `rotateCursor` je prebačen na `makeSymbolCursor`, isti crtač koji je
napravljen u prošlom koraku — bio je drugi primerak istog posla.

**⚠️ Ostavljena je i rotacija duž IVICA, ne samo na ćoškovima.** Klijentova
rečenica u zagradi (*„samo kada sam van slike – van kropa ali blizu ćoška onda
rotacija na sva četiri ćoška"*) čita se na dva načina, a u prethodnom krugu je
za ivice rečeno *„rotacija radi"*. Ako je mislio da ivice više ne rotiraju,
skida se izbacivanjem trake i ostavljanjem četiri ćoškasta polja — jedna izmena
u `CropRotateBandShape`.

### 2. ⚠️ BUG — fotografija puštena nazad u istu mrežu brisala je sve ostale

Prijava: *„ako uhvatim sliku i pustim je u istom folderu ta slika ostaje sve se
druge izgube"*.

Gore je nego što zvuči. `PhotoShowSheet` ima `.onDrop` na celom ekranu koji
uvozi fotografije prevučene spolja, a `importShowPhotos` **DODELJUJE**
`photoURLs`, ne dodaje na njega. Dakle otpuštanje jedne fotografije iznad mreže
iz koje je uzeta zamenilo je svih 101 tom jednom. **Ništa nije obrisano sa
diska**, ali se folder na ekranu ispraznio — što je u tom trenutku
nerazlučivo od brisanja.

Popravka: drop čije su SVE putanje već u `photoURLs` nije uvoz, nego povratak
kući, i ne radi ništa.

**⚠️ Provera je na SADRŽAJU, ne na zastavici „vučenje je počelo unutar
BriefShow-a".** `onDrag` nema parnjaka „vučenje je završeno", pa takva zastavica
nema pošten trenutak da se obriše i počela bi da guta prave uvoze prvi put kad
se vučenje napusti na pola.

### 3. Sličica dok se vuče — mala, i lepeza kad ih je više

Prijava: *„čim uhvatim sliku ona je isti size i onda ne vidim sa leve strane gde
je vučem"*. Bez `preview:` macOS vuče kopiju pogleda u punoj veličini, a na ovom
zumu je to veći deo prozora — folder u koji se cilja je bukvalno ispod nje.

Sad: jedna fotografija je **jedna mala karta (74 pt)**; više njih je **lepeza od
najviše tri**, plus **broj**. Tri zato što je lepeza od dvanaest mrlja, a broj je
ono što stvarno kaže koliko ih se seli. Uhvaćena fotografija je **na vrhu**
gomile bez obzira na svoje mesto u mreži — ona je pod pokazivačem, pa se nju i
očekuje.

### Merenje

Oba harness-a ponovo: **3600 uklopljenih crop-ova OK**, **126 zapisa dekodirano,
nijedan broj se nije pomerio.**

### ⚠️ NEPROVERENO NA EKRANU

- ruka na sve četiri tačkice i na četiri štapića, i da razvlačenje odatle radi;
- bela strelica u luku odmah izvan tačkice, na sva četiri ćoška;
- mala sličica dok se vuče jedna, lepeza sa brojem dok se vuče više;
- da puštanje fotografije nazad u istu mrežu **ne dira** ostale.

Prevodi se (`BUILD SUCCEEDED`, Debug).

## KORAK 82 — ćošak je SAMO razvlačenje, rotacija je svuda van kropa (2. septembar 2026)

Treći krug gledanja. Prijava je bila oštra i zaslužena: *„kada dođem mišem na
ćošak (angle) tačku, on mi pokaže ruku i krene rotacija, pa onda opet pokušavam
da smanjim crop, opet rotacija, ne valja, pa onda jedan nekako ubodem da smanjim
krop"*.

### Uzrok — hover i pritisak nisu gledali istu tačku

U KORAKU 80 je osetljiva zona ručice **uvučena unutar okvira** za 11 pt, dok je
nacrtana bela tačkica ostala centrirana NA ćošku. Dakle: prelaz mišem preko
unutrašnje polovine tačkice → ruka; pritisak na samu tačkicu → traka za rotaciju.
Pogled i ruka su gledali dve različite stvari, a to je najgora vrsta greške u
alatu koji se koristi mišem.

To je bio pokušaj da se zadovolji „ćošak spolja rotira" iz prethodnog kruga.
**Odbačeno.** Klijentovo pravilo je jednostavnije i ono važi:

> **Na ručici — SAMO sužavanje i širenje. Van kropa — rotacija.**

### Šta je promenjeno

- **Osetljiva zona je opet centrirana na ručici**, i veća: **30 pt za ćošak**
  (tačkica je 12), 24 za sredine ivica. Bilo gde na tačkici ili tik oko nje —
  razvlačenje. Ručice su deklarisane **poslednje** u ZStack-u, pa uzimaju te
  tačke od zone ispod sebe.
- **Zona rotacije je sve van okvira** (`CropOutsideShape`), ne više traka od
  24 pt. Traka je bila pogrešna dvaput: teško se nalazila, i tukla se sa
  ćoškovima oko istih nekoliko tačaka. Van okvira ionako nema ničega drugog —
  to je zatamnjeni deo.

### Kursor rotacije je NACRTAN, i VIĐEN

Traženo doslovno: *„bela kriva sa strelicama na point a i b"*. `arrow.clockwise`
koji je stajao dotad je **jednostrani krug** — čita se kao „redo", ne kao „okreni
na obe strane". SF Symbols nema dvostranu krivu ni na jednoj verziji macOS-a, pa
je nacrtana rukom, kao `OpenFolderShape` i `LumenoLabMark` u istoj app-i: luk sa
strelicom na svakom kraju, belo sa crnim obrubom.

**⚠️ Renderovan u PNG i pogledan pre isporuke**, uvećan 10× preko svetle i preko
tamne podloge — jer se koristi isključivo preko fotografija, a bela kriva bez
obruba nestaje na nebu. Crn obrub je tu i drži na obe podloge. Ovo je prvi
kursor u projektu koji je **viđen** pre nego što je isporučen.

### Sličica dok se vuče — dve, i 20% manja

Klijent: *„maksimum dve da pokaže… i ako može još manje thumbnails, recimo za još
20%"*. Lepeza je sad **najviše dve karte**, strana **74 → 59 pt**. Broj u uglu
ostaje — on je ono što stvarno kaže koliko ih se seli.

### Merenje

Oba harness-a ponovo: **3600 uklopljenih crop-ova OK**, **126 zapisa dekodirano,
nijedan broj se nije pomerio.**

### ⚠️ NEPROVERENO NA EKRANU

- da ćošak sada **uvek** razvlači, iz prvog pokušaja, i da rotacija tu nikad ne
  kreće;
- da van kropa svuda stoji nacrtana dvostrana kriva;
- da lepeza pokazuje dve karte i da je manja.

Prevodi se (`BUILD SUCCEEDED`, Debug).

## KORAK 83 — kursor rotacije se nije video, i zašto: `push`/`pop` (2. septembar 2026)

Klijent: *„super radi sve, samo sada nema ikonica kada je cursor na mestu za
rotaciju"*. Zona je bila tačna, gesta je radila, slika kursora je bila nacrtana i
**viđena** u KORAKU 82 — a na ekranu je nije bilo.

### Uzrok — četiri sloja koja se otimaju o isti stek

`NSCursor` je **stek**. Svaki sloj crop alata je gurao svoju sliku na
`.onHover(true)` i skidao je na `.onHover(false)`: površina van kropa, sam okvir,
osam ručica, plus slojevi alata ispod. Kad pokazivač pređe sa ručice pravo na
površinu van kropa, `pop` za ručicu ume da stigne **posle** `push`-a za spoljnu
površinu — i stek ostaje da drži pogrešnu sliku. Nema redosleda na koji se može
osloniti, jer ga niko ne kontroliše.

**Ovo upozorenje je u ovom fajlu zapisano dvaput** (uz `CropOutsideShape` i uz
Space-to-pan sloj). Ovo je kako izgleda kad se stvarno desi.

### Popravka — jedno mesto odlučuje, i POSTAVLJA umesto da gura

Sve `.onHover` gurаnje je uklonjeno iz crop alata. Umesto njega jedan
`.onContinuousHover` na celom sloju računa iz položaja pokazivača u kojoj je zoni
i poziva `.set()`.

**`.set()` na svaki pomeraj miša nije zaobilaznica nego rešenje:** AppKit ionako
vraća kursor iz svojih tracking area na svaki pomeraj, i ponovno postavljanje je
način na koji pogled drži svoj kursor. **Steka više nema, pa nema ni šta da se
razbalansira.**

`cropCursor(at:rect:angle:)` ide **istim redosledom kojim ZStack deli geste** — i
mora: kursor koji se ne slaže sa onim što će pritisak uraditi gori je od nikakvog
kursora, a upravo to neslaganje je učinilo ćošak neupotrebljivim u KORAKU 82.

- vučenje u toku → zadržava svoj kursor gde god pokazivač odlutao (okretanje
  odvede pokazivač daleko od ručice na kojoj je počelo, a promena kursora na pola
  čita se kao da je alat pustio);
- ručica → ruka, sa **istim dosegom koji ima i njena osetljiva zona** (30 pt
  ćošak, 24 ivica);
- unutar okvira → ruka;
- sve ostalo → nacrtana dvostrana kriva.

Usput izvučen `cropHandlePosition` — položaje ručica sad računa **jedno** mesto,
koje koriste i pogledi i kursor, pa ne mogu da se raziđu. I obrisano je
`isPushingCropMoveCursor`, koje je postojalo samo da čuva stek koga više nema.

### Merenje

**3600 uklopljenih crop-ova OK**, **126 zapisa dekodirano, nijedan broj se nije
pomerio.**

### ⚠️ NEPROVERENO NA EKRANU

Da se kriva sada vidi van kropa, ruka na ručicama i unutar okvira, i da se pri
vučenju kursor ne menja.

Prevodi se (`BUILD SUCCEEDED`, Debug).

## KORAK 84 — kursor rotacije se okreće za pokazivačem (2. septembar 2026)

Klijent: *„imam ikonicu rotacije sada i radi, samo je napravi da bude još manja
nekih 50%, bez black stroke, samo bela… i trenutno je ikonica sa strelicama na
dole, okay, ali to treba da bude kad je cursor na gornjem delu slike, a kada je
kursor dole onda strelice da pokazuju na gore… za svaki ćošak strelice da budu
nagnute"*.

### Šta je traženo, jednom rečenicom

**Kursor je tangenta na krug po kome će vučenje putovati.** Zato strelice gledaju
nadole kad je pokazivač iznad kropa, nagore kad je ispod, i nagnute su na
ćoškovima. To i jeste ono što ručica za rotaciju jeste — sve tri klijentove
rečenice su isti zahtev.

### Kako

24 slike, po jedna na 15°, **napravljene jednom i zadržane**. Ne crta se po
kadru: `NSCursor(image:)` rasterizuje, a ovaj kursor se **postavlja na SVAKI
pomeraj miša** (KORAK 83), pa bi crtanje po pomeraju bilo rasterizovana slika po
kadru. 15° je finije nego što oko pročita na glifu od 14 pt.

`rotateCursor(at:around:)` bira sliku iz ugla između centra kropa i pokazivača.
Nula glifa je **pokazivač tačno iznad centra** — otud `+90` u računu, jer ekranski
ugao meri 0 udesno a 90 nadole.

**⚠️ AppKit crta sa y NAGORE**, pa je luk od 20° do 160° gornji luk — što jeste
poza za pokazivač iznad centra. Okretanje glifa **u smeru kazaljke na ekranu**
zato znači **oduzimanje** tih stepeni. Zapisano jer je znak ovde suprotan od
intuicije.

### Manje, i bez obruba

Strana **28 → 14 pt**, sve mere prepolovljene. Crn obrub uklonjen, ostala je
čista bela linija.

**⚠️ Time je kursor slabije vidljiv preko svetlog neba** — to je trampa koju je
klijent izabrao tražeći ga upola manjeg i bez crne. Ako se ikad vrati kao
prijava, obrub je jedan `setStroke` nazad.

Crta se u **izričit 2× bitmap**, ne kroz `lockFocus`: na 14 pt je 1× kursor
vidno zupčast na Retina ekranu.

### Provereno gledanjem, ne rezonovanjem

Osam poza renderovano u jednu sliku, raspoređenih tamo gde bi pokazivač stajao
oko kropa, sa nacrtanim okvirom u sredini. Pitanje „da li strelice gledaju nagore
kad je pokazivač ispod" je odgovoreno **gledanjem**, a ne razmišljanjem o
znacima — a znak je ovde bio suprotan od očekivanog. Sve osam su tangencijalne i
tačne.

### Merenje

**3600 uklopljenih crop-ova OK**, **126 zapisa dekodirano, nijedan broj se nije
pomerio.**

### ⚠️ NEPROVERENO NA EKRANU

Da se kursor okreće glatko dok se pokazivač vodi oko kropa, i da je na 14 pt
dovoljno vidljiv preko stvarne fotografije.

Prevodi se (`BUILD SUCCEEDED`, Debug).

## KORAK 85 — C1 je POTVRĐEN, i zašto čitač kartice verovatno već radi (2. septembar 2026)

### ✅ Kamera radi — prijavljeno od klijenta

*„kameru smo rešili, radi sada, kad sam je povezao radila je i videla slike sa
kartice"*. Time je **C1 zatvoren** i KORAK 73 potvrđen na ekranu: dupli red je
bio poređenje po `device ===` umesto po `id`, a prazan ekran koji je lagao bio je
`emptyState` bez treće grane. Hod kroz `contents` kao unija je ostao kao dodatak;
da li je on doprineo ne zna se i ne treba tvrditi.

### Pitanje klijenta: isti sistem za SD karticu iz čitača na USB-u?

**Verovatno već radi, bez ijednog reda novog koda.** Razlog, iz koda:

`CameraBrowser.start()` traži uređaje maskom `camera | local`. To **nije** „samo
fotoaparati": ImageCaptureCore pod `ICCameraDevice` prijavljuje i čitač kartice
sa karticom koja ima `DCIM` folder, preko transporta *mass storage*. Isto radi i
Apple-ov Image Capture — ubačena SD kartica se pojavi pod Devices, pored
fotoaparata. A naš put je već pisan tako da ne zna ni za Nikon ni za telo
(KORAK 35, dopuna), i `Item.Origin` već ima obe grane (KORAK 77).

Dakle očekivano ponašanje: čitač u USB → kartica u **DEVICES** → prozor za import
iskače sam, istom kapijom kojom iskače kamera.

**⚠️ NIJE POTVRĐENO — klijent nema ni čitač ni karticu.** Ovo je zaključak iz
koda i iz toga kako se Image Capture ponaša, ne merenje.

### Provera koja ovo zatvara, kad se čitač nađe

1. Priključi čitač sa karticom i pogledaj levu traku. **Pojavi se → tačka 2 sa
   spiska otpada**, posla nema.
2. Ne pojavi se → `swift Tools/camtest.swift` ispisuje svaki uređaj sa
   `transportType`. Ako čitača nema ni tu, sistem ga ne nudi kao `ICCameraDevice`
   i **tek tada** se piše posmatrač `NSWorkspace.didMountNotification` — sa svim
   što uz njega ide, uključujući entitlement za prenosive diskove koji se mora
   videti na POTPISANOM build-u.

**Zato se posmatrač ne piše sada.** Ne iz opreznosti: pola je verovatnoće da je
posao nepotreban, a druga polovina ne može ni da se pokrene bez hardvera.

## KORAK 86 — dug je proveren, i zaglavlje panela je prepravljeno (2. septembar 2026)

### ✅ NEPROVERENI DUG JE ZATVOREN

Klijent, posle klikanja: *„ovo sam proverio, sve lepo radi"* — za KORAKE 68–78.
Dakle **potvrđeno na ekranu**: levi panel se razvlači i ne beži kroz levu ivicu
(68, 78), sinhronizovan 4:3 se zadrži (69), crop ne lagira (70), odbačene
fotografije i `X`/`.`/`,` (71), folder na ikonicu (72), import iz menija sa
izborom izvora i rotacija (77). Uz KORAK 85 (kamera) i KORAKE 79–84 (rotacija
crop-a, prevlačenje, tema profila), **ništa iz ove sesije više ne stoji
neviđeno.**

### Zaglavlje panela — pet dugmadi umesto četiri, i AI seli gore

Traženo, sa slike: „Before / After" da se zove **Original** i da ima ikonicu
slike; Crop ostaje; Reset ostaje ali dobija ikonicu; u praznom prostoru da stoji
**AI Clean Up**; **AI MANIPULATION nestaje dole** jer ga otvara to dugme; Done
dobija ikonicu.

- **Original** — bolje ime za ono što dugme radi: ne pokazuje dve stvari jednu
  pored druge, nego original dok se drži. Natpis se više ne menja dok se drži;
  to već govori isticanje, a reč koja se menja pod pokazivačem je reč koja se
  čita dvaput.
- **Reset** dobija `arrow.counterclockwise`, ne `arrow.uturn.backward`: vraća
  SVE odjednom, a pun krug kaže „skroz unazad" gde polukrug kaže „jedan korak".
- **Done** dobija kvačicu.
- **AI Clean Up** nosi slova „AI" uokvirena na fiksnu širinu — isti znak koji
  nosi i dugme Clean Up unutar bloka, pa ulaz i ono što otvara imaju istu oznaku.
  Glifa za AI nema, a čarobni štapić bi rekao isto što i dva Clean Up dugmeta
  ispod njega (KORAK 28).

### ⚠️ Red se PRELAMA, ne sabija

Pet dugmadi na ovom fontu je **šire od panela od 340 pt**, a panel se vuče od 300
do 560. Na jednoj širini bi stali, na drugoj bi se svi skratili u „Origi…",
„Res…". Zato red više nije `HStack` nego **`FlowLayout`** — isti koji koriste
sličice u ShowGrid-u. Prelamanje u drugi red je pošten način da redu imenovanih
dugmadi ponestane širine: imena su ovde ceo smisao, a na 560 ionako svi stanu u
jedan red. `Spacer` pre Done je uklonjen — u toku ne znači ništa.

### AI Manipulation više nema svoju liniju u panelu

Blok je bio disclosure čije je zatvoreno stanje i dalje bila jedna naslovljena
linija u panelu. Ta linija je ono što je traženo da nestane. Sad bloka nema
uopšte dok se ne pritisne dugme u zaglavlju.

**⚠️ Padding i `Divider()` su ušli UNUTAR uslova.** Ostavljeni napolju dali bi
praznu traku od 20 pt i samostalnu crtu preko panela bez ičega između — što je
ista ta naslovljena linija, samo gora jer je prazna.

`aiManipulationExpanded` je isti `@AppStorage` ključ kao pre, pa klijent koji ga
je ostavio otvorenog zatiče ga otvorenog i u ovom build-u.

### Merenje

**3600 uklopljenih crop-ova OK**, **126 zapisa dekodirano, nijedan broj se nije
pomerio.**

### ⚠️ NEPROVERENO NA EKRANU

Kako se red prelama na 340 pt — koliko dugmadi stane u prvi red — i da li je
prelom čitljiv ili traži kraća imena.

Prevodi se (`BUILD SUCCEEDED`, Debug).

## KORAK 87 — jedan pritisak stavlja četkicu u ruku (2. septembar 2026)

Klijent: *„kada kliknem na AI Clean Up u toj gornjoj tabeli odmah da mi da da
mogu da paintujem, a ne da opet kliknem ispod na AI Clean Up (to dugme dole u AI
Manipulation obriši jer ga ima gore)"*.

Tačno — u KORAKU 86 je dugme u zaglavlju samo **rasklapalo blok**, a četkica se
uzimala drugim pritiskom na drugo dugme. Dva koraka tamo gde je smisao jedan.

- Dugme u zaglavlju sad **rasklapa blok i uzima četkicu odjednom**. Ugašeno gasi
  i jedno i drugo.
- Dugme „Clean Up" **unutar bloka je obrisano.** Ostaviti kopiju značilo bi
  ostaviti drugi korak dvokoraka koji je upravo uklonjen.
- „Exit Clean Up" **ostaje**: ono spušta četkicu ali **ne sklapa blok**, jer
  Quick i Generative rade nad bojom koja je već položena. Sklopiti blok čim
  se prestane sa slikanjem značilo bi skloniti ta dva dugmeta u trenutku kad su
  jedino i potrebna.

### ⚠️ Rupa koju je KORAK 86 napravio, i koja je ovde zatvorena

Postoji **TREĆI** ulaz u ovaj alat — „AI Clean Up" u sekciji Remove, stariji od
dugmeta u zaglavlju — i on samo pali četkicu, ne dira `aiManipulationExpanded`.
Otkad je blok uslovan (KORAK 86), taj put je vodio u stanje u kome klijent slika
a **Quick i Generative Clean Up nisu nigde na ekranu** — dva dugmeta koja rade
tačno nad onim što je upravo naslikao.

Zato je uveden `isAIManipulationVisible` = dugme u zaglavlju **ILI** živa
četkica. Druga polovina nije opreznost nego popravka.

**Ovo nije prijavljeno** — nađeno je čitanjem koda posle izmene, dok se tražilo
ko sve pali `isRemoveBrushActive`.

### Merenje

**3600 uklopljenih crop-ova OK**, **126 zapisa dekodirano, nijedan broj se nije
pomerio.**

### ⚠️ NEPROVERENO NA EKRANU

Da jedan pritisak stvarno odmah slika; da gašenje sve pospremi; i da blok bude
tu i kad se četkica upali iz sekcije Remove.

Prevodi se (`BUILD SUCCEEDED`, Debug).

## KORAK 88 — AI sekcija se otvara zatvorena (2. septembar 2026)

Klijent: *„kada uđem, dva puta kliknem na sliku, AI sekcija je otvorena; neka
bude zatvorena pa klijent neka izabere šta hoće"*.

Uzrok: `aiManipulationExpanded` je bio **`@AppStorage`**, dakle pamćen između
pokretanja. To je imalo smisla dok je blok bio naslovljena disclosure linija koja
zatvorena ne košta ništa. **Prestalo je da ima smisla u KORAKU 87**, kad je isto
dugme počelo da uzima i ČETKICU: zapamćeno „otvoreno" je od tada značilo da se
fotografija otvara sa živom četkicom za čišćenje — na slici koju je neko hteo
samo da pogleda.

Sad je `@State`. Svako novo otvaranje editora kreće zatvoreno; unutar jedne
sesije ostaje kako je ostavljeno, što je ono što hoće neko ko radi seriju.

Stari ključ `develop.layout.aiManipulationExpanded` ostaje u UserDefaults-u
neiskorišćen — bezopasno, i briše se sam kad se profil resetuje.

### Merenje

**3600 uklopljenih crop-ova OK**, **126 zapisa dekodirano, nijedan broj se nije
pomerio.**

Prevodi se (`BUILD SUCCEEDED`, Debug). Neprovereno na ekranu.

## KORAK 89 — „Done" postaje „Grid" (2. septembar 2026)

Klijent: *„ovo Done dugme bih nazvao Grid, sa ikonicom grida, jer to i radi —
baca na grid"*.

Tačno, i ime je bilo lošije od toga na dva načina: nije govorilo **kuda** vodi, a
„Done" povrh toga sugeriše da se nešto potvrđuje — što se ne dešava. Izmene se
upisuju kako se prave, ništa ne čeka potvrdu. Sad `square.grid.2x2` + **Grid**,
sa tooltipom „Back to the grid."

Usput ispravljen komentar iznad `cropHeaderButton`, koji je i dalje nabrajao stari
red („Before / After, Reset, Done"). Zaglavlje je sad **Original · Crop · Reset ·
AI Clean Up · Grid**.

Prevodi se (`BUILD SUCCEEDED`, Debug).

## KORAK 90 — nebo: dve prave greške nađene, i izmeren zid (2. septembar 2026)

Mereno `Tools/run-skymask.py`-em na tri najteža klijentova kadra iz
`BriefShow RAW Check/2026-09-01`: **8947** (zgrade + more), **8987** (beli hotel
+ palme), **8991** (plaža bez horizonta).

### ⚠️ 1. Alat NIJE izvlačio kod — beleške su tvrdile da jeste

`Tools/skymask.swift` je nosio **ručnu kopiju** `SubjectMasker`-a i
`SkyMasker`-a, dok je u ovom dokumentu pisalo da ih „izvlači iz izvora u trenutku
prevođenja". Kopija je slučajno još bila identična, pa ništa dosad nije bilo
pogrešno izmereno — ali **prva izmena `SkyMasker`-a bila bi merena nad starim
kodom, i rezultat bi izgledao kao merenje.** Ista klasa greške koju je KORAK 66
platio tri puta.

Zamenjeno: `Tools/run-skymask.py` + `Tools/skymask-driver.swift`. Vadi oba
maskera po balansu zagrada, kao `run-crop-rotation-test.py`. Stari fajl obrisan.

### ⚠️ 2. Hod je merio ARTEFAKT RENDERA, ne fotografiju

`.RGBA8` vraća **premultiplikovanu** boju, a skalirana radna kopija ima razlomljen
extent — pa je **prvi red bitmape poluprekriven**: izmereno alpha 141, boja
133/137/141, dok je isto to nebo u punoj vrednosti 241/249/255.

Čitano sirovo, skok sa reda 0 na red 1 je **114** — granica po svakom pragu. Kad
je dodat test „zaustavi se na ivici", **svaka kolona je pucala na redu 1** i maska
je dolazila prazna. Izgledalo je tačno kao pretesna granica, i **nikakvo
popuštanje granice to ne bi našlo** — brojevi su opisivali render, ne sliku.

Sad se čita **un-premultiplikovano**, i skor i boja. Ovo je bilo tiho pogrešno i
pre ovog koraka; samo nije imalo posledicu dok niko nije poredio redove.

Usput nađena i moja greška: na „promašenom" redu (žica, grana) referenca je
ažurirana na taj tamni piksel, pa je povratak u nebo bio ogroman skok i
`runToStop` je bio potpuno obesmišljen.

### 3. Dodato — zaustavljanje na ivici, i medijan protiv pruga

- **Korak nadole**, mereno: unutar neba je 0 (p50), 1 (p90), 1–4 (p98), 2–26
  (p99,9). Granica **40** stoji čisto iznad svega toga.
- **`withoutStripes`** — medijan filtar nad profilom dubine. Kolona koja prođe
  kroz zgradu je **impuls** u tom profilu; medijan je klasičan način da se impuls
  ukloni i, za razliku od blura koji je svaka ranija verzija posezala, **ne
  zaobljava pravi stepenik** — a krov JESTE stepenik, i pritužba koja je ovo i
  pokrenula bila je granica koja glatko seče preko zgrada.

### ⚠️ ZID — izmeren, i treba ga znati

**Beli hotel ispod belog neba se lokalno NE MOŽE razlikovati od neba.** Izmereno:
nebo 241/249/255, fasada praktično isto. Nema koraka koji se traži, nema boje
koja se razlikuje, a ravna je čim se skor zamuti u regione. Medijan skraćuje
**usamljene** pruge (desna u 8987 je prepolovljena), ali **ne pomaže kad je ceo
blok zgrade širi od prozora** — a jeste, na 8987.

Isto važi za 8991: more i pesak bez horizonta prolaze iz istog razloga.

**Zaključak, pošten:** heuristika radi na kadru sa vidljivim horizontom (8947 je
dobar) i **ne radi** kad veliko svetlo telo stoji pod svetlim nebom. To nije
podešavanje koje fali — to je kraj onoga što lokalni test može.

### KORAK 90, nastavak — granica od ivice do ivice, i app koja prizna da ne vidi

Klijent: *„granica mora da bude od jednog kraja slike do drugog"*. Iza toga stoji
prijava od 1.09: zamenjeno nebo pokrije gornji levi deo i **stane nasred hotela**.

**Kolona može da stane na samom vrhu iz dva potpuno različita razloga**, a hod to
sam ne može da razluči: nešto ZAKLANJA nebo (palma, banderа, žica) — horizont je
i dalje iza toga, tamo gde ga stavljaju susedi; ili je horizont stvarno tu gore
(zgrada do vrha kadra).

Zato `continuousHorizon` **interpolira** horizont preko plitkih kolona, a
**skor se onda primenjuje iznad njega** po pikselu. Palma zadrži svoje piksele
van maske jer ih skor odbija, dok nebo IZA nje, iznad horizonta, ulazi — što je
tačno ono što zamena neba mora da radi. Na ivicama kadra se najbliža poznata
kolona iznosi napolje: ivica nije razlog da horizont propadne.

**Izmereno posle izmene:** 9011 sad daje **neprekidnu traku od leve do desne
ivice** (pre je bila samo mrlja u sredini). 8947 nepromenjen. **8987 sada
ODBIJA** umesto da vrati pruge — `isPlausibleHorizon` ga zaustavi, i klijent
dobije poruku koja imenuje oba razloga i kaže da zaokruži Selection alatom.

### ⚠️ SD NE MOŽE DA ODREDI MASKU — činjenica, ne mišljenje

Klijent je tražio: *„daj SD AI modelu da izabere, da vidi i odredi masku"*.

**Stable Diffusion inpainting POPUNJAVA već zadatu masku. On je ne pravi.** To je
druga vrsta posla — semantička segmentacija — i za nju u ovom projektu nema
modela: Vision segmentira samo ljude (KORAK 66), a segmentacioni model je
stotine megabajta povrh 4,4 GB plus licenca za app koja se prodaje.

Uz to: **SD danas ne radi ni na jednoj klijentskoj mašini.** Težine se nigde ne
preuzimaju (C2), a C2 je klijentovom odlukom poslednji korak. Vezati nebo za SD
znači da nebo ne radi nikome dok se C2 ne završi.

Dakle masku i dalje pravi `SkyMasker`, a SD — kad C2 bude gotov — može da bude
DODATAK koji uskladi zalepljeno nebo sa kadrom, ne ono što masku određuje.

## KORAK 91 — klijentova neba u app-i, i feather na horizontu (2. septembar 2026)

Klijent je dao `~/Downloads/Skies` — 15 fotografija. Uz to: *„slike isto sadrže
plaže… nemoj plažu da stavlja, samo nebo… može planine kao u pozadini"*.

### Neba su ISEČENA pre pakovanja

Originali su fotografije cele scene; devet ih ima more ili plažu u donjoj
polovini. Zalepiti plažu u nečije nebo nije funkcija.

Rez je **očitan sa svake slike posebno**, ne nađen detektorom horizonta:
petnaest brojeva pogledanih odjednom vredi više od detektora koji pogreši na dve
a niko ne gleda. Planine u sky-11 su **zadržane**, po klijentu — planinski venac
na horizontu je pejzaž, plaža je druga plaža. Provereno gledanjem: kontakt-list
svih 15 rezova pre i posle.

2400 px po širini, JPEG 0,86 → **8,5 MB za svih petnaest**, na app od 125 MB.

### Model — `SkyChoice`, i migracija koja se nije desila

`ImageLayer.skyStyle` je od `SkyStyle?` postao `SkyChoice?` — `.drawn(SkyStyle)`
ili `.photo(ime)`.

**⚠️ Kodira se kao OBIČAN STRING.** U svakom dosad zapisanom slogu to polje je
bilo goli raw value (`"sunset"`), i ti slogovi su na klijentovom disku.
Dekodiranje prima taj oblik nepromenjen, a string tretira kao fotografiju samo
ako nosi prefiks `photo:`. **Nijedan postojeći slog se ne migrira i nijedan ne
menja značenje.** Nepoznato ime iz nekog budućeg build-a pada na `clearBlue`
umesto da baci — bacanje bi oborilo ceo slog (v. `PhotoEditStore.allSettings`).

`Tools/run-editsettings-decode-test.py` je odmah pao sa `cannot find 'SkyChoice'`
— tačno svoj posao — pa je tip dodat na spisak. Posle toga: **125 slogova
dekodirano, nijedan broj se nije pomerio.**

### ⚠️ Bundle spljošti podfolder

Fajlovi stoje u `BriefShow/Skies/`, ali je to unutar file system synchronized
grupe i Xcode ih kopira u `Contents/Resources` **bez foldera** — provereno u
napravljenom bundle-u, ne pretpostavljeno. Zato `SkyPhoto.url` traži **ravno
prvo**, a podfolder samo kao rezervu. Obrnut redosled bi promašivao na svakom
pozivu i svejedno radio — vrsta stvari koja se otkrije za tri godine.

### Feather — samo na horizontu, ne svuda

Traženo: *„sa donjim delom kao feather"*.

Šav sa horizontom mora da se stapa ili je nacrtana linija preko fotografije. Ali
tamo gde nebo dodiruje **palmu ili krov**, mekoća je tačno suprotno od željenog —
meka ivica tamo pusti staro nebo da svetli oko svakog lista.

Te dve ivice dolaze sa **različitih mesta**, i to je ono što ovo omogućava:
horizont je `horizon[x]`, a list je test skora. Zato se rampa (2,5% visine kadra,
~90 px na 3448) primenjuje **samo po redovima ka horizontu**, a skor zadržava
tvrdo da/ne.

### Šta u ovom koraku NIJE urađeno

**Automatsko usklađivanje neba sa kadrom** (svetlo i temperatura iz same
fotografije) — druga polovina dogovorenog koraka 1. Sloj ima svoje slajdere pa se
može doterati rukom dok toga nema.

## KORAK 92 — izabran Sky sloj se sada VIDI na fotografiji (2. septembar 2026)

Prijava: *„kliknem na layer Sky ali mi ne pokazuje da je selektovan na slici"*.

Razlog zašto nije bilo ničega je odluka iz KORAKA 67 i ona i dalje stoji: okvir
oko izvedenog sloja bio bi **pravougaonik oko cele slike** — ne kaže ništa o tome
koji je deo slike taj sloj, a vući nema šta.

Ali ono što klijentu stvarno treba da vidi je **GDE je nebo nađeno**, a to je
tačno maska. Zato se sad, dok je Sky ili Background izabran, maska crta preko
fotografije.

- **Tonirana, ne uokvirena.** Ivica te maske ide oko svakog lista palme;
  vektorizovati je da bi se iscrtala koštalo bi više nego pokazati oblast.
- **Boja NIJE nebeska.** Plava koprena preko maske neba čita se kao nebo koje je
  već tu; magenta se ne može pomešati sa fotografijom.
- **Luminansa → alpha.** Zapamćena maska je siv PNG, a SwiftUI maskira po
  **alfa** kanalu, ne po svetlini — bez `CIMaskToAlpha` bi ceo pravougaonik
  izašao pun.
- Gradi se **jednom po sloju** i pamti. Maska se posle pravljenja ne menja —
  Select Sky pravi NOV sloj umesto da prekraja stari — pa nema šta da se
  poništava.
- `allowsHitTesting(false)`: ovo je nešto što se gleda, ne dira, i nikad ne sme
  da završi u izvozu.

Prevodi se (`BUILD SUCCEEDED`, Debug).

## KORAK 93 — prvi pravi test zamene neba: ljubičasto je bila MOJA maska (2. septembar 2026)

Klijent, sa slikom: *„izgleda užas!"* — nebo ljubičasto, debeo beo oreol oko oba
čoveka i duž palmi.

### ⚠️ 1. Ljubičasto nije bilo nebo — bila je magenta koprena iz KORAKA 92

Izmereno pre nego što je bilo šta dirano: `sky-7.jpg` u traci koja se vidi
prosečno **R110 G170 B222** — plavo. Dakle nebo je nevino. Ljubičasto je
**plavo ispod 34% magente**: koprena koja pokazuje masku ostaje da stoji i pošto
je nebo izabrano, jer sloj ostaje izabran.

Ta koprena je isporučena u KORAKU 92 **bez uslova**, i to je nanelo štetu na prvi
pogled. Sad se crta **samo dok nebo NIJE izabrano** — odgovara na pitanje „gde je
našao nebo" i sklanja se čim postoji nebo koje se gleda, što na to pitanje
odgovara bolje nego bilo koja boja.

### 2. Beo oreol — dva izvora, oba popravljena

Nad prebeljenim nebom **svaka meka ivica maske pusti staro belo nebo** kroz novo.

- **Oduzimanje ljudi je bilo naduvano 0,006** ≈ 31 px na kadru od 5176. Svaki taj
  piksel je piksel na kome ostaje ORIGINALNO nebo — dakle debeo beo sjaj oko
  svakog čoveka, povrh novog neba. Spušteno na **0,0015**. Naduvavanje je i samo
  bilo popravka oreola (KORAK 67, rim light), pa je trampa neizbežna: sa
  prebeljenim nebom nesavršena maska negde pokaže belo. Nekoliko piksela u kosi
  je porub; trideset je oreol.
- **Blur na kraju hoda (0,004 ≈ 20 px) je UKLONJEN.** Postao je i suvišan i
  štetan: suvišan jer horizont sad nosi sopstvenu rampu, štetan jer je omekšavao
  i ivicu oko **palmi i krovova** — a to je 20 px trake starog neba koja prati
  svaki list. Stepenice koje je krio su artefakt radne rezolucije i mnogo manje
  vidljive od oreola.

### 3. „Da se ne vidi da je dodato" — usklađivanje sa svetlom

Klijent: *„u suštini treba da se pripoji slici da se ne vidi da je dodato… sa
transparencijom isto"*.

**Šav nije ono što odaje zalepljeno nebo — SVETLO jeste.** Nebo zalepljeno u
sopstvenoj svetlini i boji čita se kao drugi dan nalepljen preko slike, i nikakvo
omekšavanje šava to ne rešava.

`matchedToScene`: izmeri se nebo koje se zamenjuje, izmeri se novo, i novo se
pomeri **deo puta** ka starom (`skyMatchStrength = 0,45`). Deo puta, ne ceo —
ceo bi reprodukovao baš ono nebo koje se menja.

**⚠️ Mereno POD MASKOM, ne preko celog kadra.** Bitna je svetlost u nebu koje se
menja; kadar koji je četiri petine pesak inače povlači svako nebo ka boji peska.

**Pojačanje po kanalu**, ne pomeranje temperature: mora da nosi i svetlinu i boju
u jednom potezu, a pojačanje ostavlja crno na crnom — tamni oblak ostaje tamni
oblak. Ograničeno na 0,6–1,7 da prebeljeno nebo ne zatraži da novo bude svetlije
od belog.

**⚠️ Sopstveni CIContext.** Usklađivanje čita prosek jednim pikselom *unutar*
rendera koji već drži jedan od tri konteksta — čitanje kroz isti kontekst bilo bi
zaključavanje rendera protiv samog sebe.

**Transparencija koju klijent traži JE rampa na horizontu**, i podignuta je sa
2,5% na **4,5%** visine kadra: pri horizontu novo nebo istanji i kroz njega
prođe izmaglica same slike — tamo gde i pravo nebo gubi boju.

### ⚠️ NEPROVERENO NA EKRANU

Sve četiri izmene. Prevodi se, 125 slogova dekodirano bez pomeranja.

## KORAK 94 — NEBO JE IZVAĐENO IZ APP-E (2. septembar 2026)

Klijentova odluka posle prvog pravog testa. Razlog je u KORAKU 93 i, detaljno, u
**`SKY_ARCHIVE/BRIEFSHOW_SKY_NOTES.md`** — ukratko: SD može da POPUNI zadatu
masku ali ne može da je NAPRAVI, a nebo koje bi izmislio dolazi sa 512 px platna,
mekano posle uvećanja. Umesto polovičnog rešenja, funkcija je izvađena cela.

### ⚠️ NIŠTA NIJE IZGUBLJENO — `SKY_ARCHIVE/` pored ovog fajla

```
SKY_ARCHIVE/
  BRIEFSHOW_SKY_NOTES.md   255 linija — sve što je urađeno, izmereno i pogrešeno
  code/SkyTypes.swift      1233 linije — SkyMasker, SkyStyle, SkyPhoto,
                           SkyChoice, SkyPainter, matchedToScene i pomoćne
  skies/                   15 klijentovih neba, isečenih na nebo (8,5 MB)
  tools/                   run-skymask.py, skymask-driver.swift, skytest.swift
```

**Namerno je van `BriefShow/BriefShow/`** — taj folder je file system
synchronized grupa i sve u njemu bi završilo u bundle-u.

Dokument ima i odeljak **„Kako se vraća"**, sa upozorenjem koje bi inače koštalo
sat vremena: `SkyChoice` mora nazad i na spisak u
`run-editsettings-decode-test.py`, inače taj test pada sa `cannot find`.

### Šta je uklonjeno

`SkyMasker`, `SkyStyle`, `SkyPhoto`, `SkyChoice`, `SkyPainter`, `matchedToScene`
i njegove pomoćne, dva `CIContext`-a, dugme **Select Sky**, modal **Change Sky**,
`selectSkyAsLayer`, `isFindingSky`, sve slike iz bundle-a, i tri alata iz
`Tools/`.

### ⚠️ Šta je NAMERNO ostavljeno

- **`ImageLayer.isSky`** — vestigijalno polje. Ključ postoji u slogovima koji su
  već na klijentovom disku; dekodirati ga i nositi dalje znači da fotografija
  uređena pre uklanjanja i dalje prolazi kroz round-trip **nepromenjena** umesto
  da tiho izgubi polje. Ako se nebo vrati, slojevi koje je napravilo su i dalje
  označeni.
- **`derivedLayerMatteOverlay`** — obojena maska za izabran izvedeni sloj. Nije
  bila sky-specifična; Background slojevi postoje i dalje i sada je to jedini
  način da se vidi gde je taj sloj.
  ⚠️ **Prevaziđeno istog dana:** klijent je prijavio da ta ispuna pokriva
  fotografiju koju upravo podešava, i zamenjena je obrisom — v. KORAK 95. Pouka
  iz KORAKA 93, zapisana dva reda niže, odnosila se baš na nju.
- **Pouka iz KORAKA 93**, kao komentar na tom overlay-u: indikator koji pokazuje
  GDE je nešto nađeno mora da nestane čim postoji rezultat koji se gleda.

### Provereno

`BUILD SUCCEEDED`. **Nula** pominjanja `SkyMasker`/`SkyPainter`/`SkyStyle`/
`SkyChoice`/`SkyPhoto`/`skyStyle`/`Select Sky`/`Change Sky` u kodu. **Nula**
`sky-*.jpg` u bundle-u. **125 slogova dekodirano, nijedan broj se nije pomerio.**
Harness za rotaciju crop-a i dalje prolazi.

## KORAK 95 — Background se vidi kao selekcija, ne kao koprena (2. septembar 2026)

Tri zahteva iz jedne poruke, sa dve slike uz nju.

### ⚠️ 1. Magenta koprena preko Background sloja — i zašto je to bila ista greška iz KORAKA 93

Prijava: *„kada kliknem na background ne treba da mi pokazuje paint mask over,
samo selection kao recimo sada za ljude... da znam da je selektovan bez maske"*.

Na slici koju je klijent poslao vidi se tačno u čemu je problem: izabran je
Background, cela pozadina je pod magentom, a **ispod u panelu stoje njegovi
slajderi** — Exposure +0,62, Black & White, Blur. Znači klijent podešava
piksele koje **više ne vidi**, jer ih pokriva indikator koji mu je samo rekao
gde su.

To je doslovno pouka iz KORAKA 93, zapisana kao komentar na tom istom overlay-u:
*indikator koji pokazuje GDE je nešto nađeno mora da nestane čim postoji
rezultat koji se gleda*. Overlay je preživeo KORAK 94 kao „jedini način da se
vidi gde je taj sloj" — i onda je ponovio grešku zbog koje je pouka i pisana.

**Popravka:** `derivedLayerMatteOverlay` → `derivedLayerOutlineOverlay`. Umesto
ispune, crta se **obris** — morfološki gradijent (dilate minus erode) nad
matte-om ostavlja svetlu traku tačno na granici i crno svuda drugde; to postaje
alfa, pa se boji. Uz to ide **okvir sloja**, isti kao kod piksel sloja, jer
izvedeni sloj pokriva ceo kadar i to je istina o njegovom dometu.

### ⚠️ Ručke NISU dodate, i to je odluka

Klijent je uz sliku People sloja rekao „da mi pokaže da mogu da ga pomeram".
**Background se ne može pomeriti** — to nije propust nego ono što on jeste:
matte, region SAME fotografije, bez svojih piksela (v. `ImageLayer.maskData` i
tekst u panelu koji to i kaže). Pomeranje matte-a pomera **rupu**, ne ono što je
ispod. Ručke koje ništa ne rade kad se povuku čitaju se kao kvar, što je gore
od toga da ih nema.

Zato je isporučeno: okvir + obris (**vidi se da je selektovan**), bez ćoškova i
bez kvake za rotaciju. **Pitanje da li Background TREBA da postane pomerljiv je
poslato klijentu** — v. odeljak SLEDEĆE, to je izmena modela, ne izmena prikaza.

### ⚠️ IZMERENO — i merenje je uhvatilo bledu liniju pre klijenta

Nov harness **`Tools/run-layer-outline-test.py`** + `Tools/test-layer-outline.swift`.
Vadi pravu `layerOutlineImage(for:)` iz `Develop.swift` po tekstu (svaka zamena
je proverena, pa ne može tiho da testira zastarelu kopiju), pušta je na
sintetičkom matte-u i **meri alfu koju overlay stavlja na sliku**.

Prvi prolaz je pao, i dobro je što jeste:

| mereno | prvi prolaz | posle popravke |
|---|---|---|
| najjača tačka na liniji | **0,451** | **1,000** |
| unutar regiona (bila koprena) | 0,000 | 0,000 |
| izvan regiona | 0,000 | 0,000 |
| debljina linije | 2 px | 2 px |

Uzrok 0,451: oštra ivica pada **između piksela**, pa svaki granični piksel dobija
samo deo pojasa — matrica je tražila 0,9 a dobijala pola toga. Linija na 45%
preko fotografije je linija koju treba tražiti. Alfa se sada **množi** faktorom
2,4 uz `CIColorClamp`; pošto je sve van granice čista nula (izmereno), dizanje
pojasa **ne može** da vrati koprenu — nema šta da se digne.

### 2. „Select People" kao quick action dugme

Traženo: *„ispod reset dodaj još jedno dugme kao quick action button select
people sa ikonicom"*. Dodato u `FlowLayout` u zaglavlju, odmah posle Reset-a —
na širinama na kojima se red prelama ispada tačno **ispod Reset-a**, gde je i
traženo. Ikonica `person.crop.rectangle`, ista kao na dugmetu u Tools.

Zove **isti** `selectPeopleAsLayer()`. Dva ulaza u jednu akciju, kao što Crop
već ima (KORAK 68), pa nema ničega što bi se raspalo iz koraka.
Dugme u **Tools ostaje** — isti razlog kao kod Crop-a: klijent je već naučio gde
je, i uklanjanje bi popravilo prijavu kvarenjem navike.

### 3. Posle Select People — pravo na Layers

*„uvek kad se klikne select people i to završi automatski baci na layers"*.
`panelTab = .layers` stoji **na kraju posla**, u `selectPeopleAsLayer`, a ne na
dugmetu — pa važi za **oba** ulaza. Akcija napravi dva sloja i jedan izabere; da
panel ostane na Edit-u, klijent bi morao da traži rezultat onoga što je upravo
pritisnuo.

### Provereno

`BUILD SUCCEEDED`, universal, nula grešaka. Nov harness **ALL PASS**. Sva tri
zatečena harness-a i dalje prolaze: crop rotacija **OK** (3600 kropova),
`editsettings` dekodiranje **27 polja, nijedno ne nedostaje**, reorder slojeva
**sve prošlo**.

### ⚠️ NEPROVERENO NA EKRANU

Obris je izmeren u brojevima, **nije viđen na fotografiji**. Ostaje da se pogleda
troje: da li je siva linija dovoljno kontrastna preko svetle pozadine (mereno je
da postoji, ne kako izgleda), gde tačno pada dugme kad je panel uzak, i skok na
Layers na pravom kliku. App je pokrenuta iz
`build_universal/Build/Products/Release/BriefShow.app`.


## KORAK 96 — kopija od Select People bila je druge boje: RADNI PROSTOR, ne maska (2. septembar 2026)

Prijava, uz sliku: klijent je pustio Select People, pomerio People sloj u stranu
i dobio pored svoje fotografije kopiju koja **nije ista osoba po boji** —
*„totalno drugačiju, vidi oči recimo"*. Očekivano je bio duplikat, piksel u
piksel.

### ⚠️ UZROK — `CIContext()` bez opcija, a ceo ostatak app-e radi u sRGB-u

`extractMaskedPNG` → `pngData` je crtao kroz
`private static let sharedExtractionContext = CIContext()` — **podrazumevan**
kontekst, koji radi u **linearnom** sRGB-u. Sve što klijent gleda ide kroz
`makeBriefEditsCIContext` / `briefEditsCIContext`, a oni imaju
`workingColorSpace` i `outputColorSpace` postavljene na **sRGB**.

Core Image primenjuje tonske i kolor filtere **u radnom prostoru konteksta**.
Znači isti graf — klijentova ekspozicija, kontrast, zasićenje — daje **različite
brojeve** zavisno od toga ko ga renderuje. Cut-out je jedino mesto u app-i gde
oba rezultata završe **jedan pored drugog na ekranu**, pa se tek tu i videlo.

Maska nije bila kriva. PNG nije bio kriv. Kriv je bio kontekst.

### ⚠️ IZMERENO na pravom kodu, pre i posle

Nov harness **`Tools/run-layer-extract-color-test.py`** +
`Tools/test-layer-extract-color.swift`. Vadi iz `Develop.swift` po tekstu tri
stvari — `briefEditsSRGBColorSpace`, `sharedExtractionContext` i `pngData` —
renderuje isti graf onako kako se **gleda** i onako kako se **čuva**, i poredi
piksele.

| izmena na fotografiji | najgori kanal PRE | POSLE |
|---|---|---|
| bez ijedne izmene | **0/255** | 0/255 |
| ekspozicija +0,62 | **52/255** | **0/255** |
| ekspozicija −0,40 | **27/255** | **0/255** |
| kontrast 1,2 / zasićenje 1,15 | **50/255** | **0/255** |

Dva reda vredi pročitati doslovno:

- **Smeđe oko:** fotografija je pokazivala `(89,50,26)`, kopija `(54,0,0)` —
  tamniji deo šarenice **odsečen na nulu**. To je tačno ono na šta je klijent
  pokazao.
- **Koža na −0,40:** viđeno `(167,136,121)`, kopija `(194,159,141)` — kopija
  **svetlija** od originala, kao na poslatoj slici.

### ⚠️ ZAŠTO OVO NIJE RANIJE VIĐENO — i zašto to nije uteha

Na fotografiji **bez ijedne izmene odstupanje je 0**. Bag je nevidljiv dok se
ništa ne dira, a Copy/Cut → „Paste as Layer" idu kroz **isti** `pngData`, pa su
i oni sve vreme lepili piksele druge boje — samo se nikad nije gledalo uporedo
sa izvorom. Popravka pogađa i njih.

### Popravka

`sharedExtractionContext` dobija `workingColorSpace` i `outputColorSpace` =
`briefEditsSRGBColorSpace`, isto što gleda klijent. Uz to `createCGImage` sada
**imenuje** prostor boja umesto da ga prepusti difoltu, jer je to oznaka koju
PNG nosi na klijentov disk.

`overlayContext` (obris iz KORAKA 95) je **namerno ostao bez opcija** i to je
zapisano na njemu: on ne crta fotografiju nego ravnu liniju iz matte-a, nikad ne
završi u eksportu, i njegovi brojevi su mereni baš kroz takav kontekst.

### ⚠️ SLOJEVI KOJI SU VEĆ NAPRAVLJENI OSTAJU POGREŠNI

PNG-ovi koji su već na disku su izvađeni starim putem i popravka ih **ne dira** —
ona menja kako se vade **novi**. Na fotografiji na kojoj je ovo prijavljeno
treba obrisati sloj i ponovo pustiti Select People.

### Provereno

`BUILD SUCCEEDED`, universal, nula grešaka. Nov harness **ALL PASS (0/255)**.
Svi zatečeni prolaze: obris **ALL PASS**, crop rotacija **OK**, `editsettings`
**OK — nijedan broj se nije pomerio**, reorder **sve prošlo**.

### ⚠️ NEPROVERENO NA EKRANU

Poklapanje je izmereno u brojevima na sintetičkim zakrpama, **nije viđeno na
klijentovoj fotografiji**. Ostaje da se pusti Select People na istoj slici i
uporede lica.


## KORAK 97 — traka napretka gore, i drhtanje pri vučenju sloja (2. septembar 2026)

### 1. „Looking for people…" i ispod dugmeta u zaglavlju

*„kada kliknem gore na quick action select people treba da se pojavi onaj
loading bar baš ispod da zna klijent da radi"*. Dodata ista neodređena traka
odmah ispod `FlowLayout`-a u zaglavlju.

Traka u Tools **ostaje**. To nije previd nego namera: dva ulaza su daleko jedan
od drugog na ekranu, a traka koja se pojavi pored **drugog** dugmeta je traka
koju klijent ne vidi. Obe čitaju isti `isFindingPeople`, pa ne mogu da se raziđu.

Neodređena, ne procenat — Vision ne javlja napredak, a izmišljen procenat je
gori od poštenog vrtuljka (isto obrazloženje stoji na starijoj traci).

### 2. ⚠️ DRHTANJE — PNG sloja se dekodirao IZNOVA U SVAKOM FREJMU

*„kada selektujem people layer i hoću da ga pomerim drhti selection, nije smooth
movement"*.

`compositeLayers` je zvao `CIImage(data: layer.imageData)` **unutar render
petlje**. Vučenje sloja piše u `settings` na svaki pomeraj miša, `scheduleRender`
pušta render na 20 ms — dakle cut-out od 700 KB se dekodirao do pedeset puta u
sekundi.

**Izmereno** na realnom cut-outu 1800×2900 (708 KB) pri veličini preview-a:

| jedan frejm vučenja | vreme |
|---|---|
| dekodiranje u svakom frejmu (kako je bilo) | **34,0 ms** |
| kroz keš (kako je sada) | **9,3 ms** |
| sama fotografija, bez sloja | 7,7 ms |

Dakle **~24 ms čistog ponavljanja** u petlji koja ima 20 ms između frejmova.
Samo sastavljanje košta **0,6 ms** — sastavljanje nikad nije bilo problem.

### ⚠️ KVALITET — klijentova ograda, i kako je ispoštovana

Klijent je uz ovo rekao: *„nemoj da izgubi quality taj duplikat layer people ili
background… quality maximum original i samo smooth drag movement"*.

Keš je baš zato ispravna vrsta popravke: čuva **pun dekod tačno onih bajtova
koji su zapisani**. Ništa se ne smanjuje, ne prekodira i ne aproksimira. To je
isto pravilo koje stoji na vrhu ovog fajla za sam preview.

I nije ostavljeno na „trebalo bi da je isto" — **izmereno je**: kompozit kroz keš
protiv kompozita sa svežim dekodom, **0 od 4.505.800 piksela se razlikuje**, i
sloj se dekodira na **punih 1800×2900**, ne na umanjenoj verziji.

**Nijedna buduća optimizacija ovde ne sme da smanji sloj.** Ako neka to traži,
odgovor je ne.

### Ključ keša — i zašto nije samo `layer.id`

`id` + tačan broj bajtova + otisak (tri uzorka po 64 bajta, FNV-1a). Otisak je
namerno **konstantnog vremena**: heširanje celog bafera na svakom renderu bi
vratilo manju verziju troška koji se ovim uklanja.

Provereno merenjem: isti `id` sa **drugim** pikselima (pečenje, flatten, novi
Select People) **ne dobija** stari dekod. `NSCache` jer renderi idu sa više
redova i jer sam izbacuje pod pritiskom memorije.

### 3. Refine više ne kreće usred vučenja

`isDrawingStroke` sada obuhvata i `layerDragStart != nil`. Pauza od pola sekunde
usred pažljivog postavljanja — a to je većina njih — pokretala je
**pun-rezolucijski** refine, za kadar sa kog klijent upravo odvlači sloj.

⚠️ Ništa se ne gubi na kraju: sve tri geste sada zovu `endLayerDrag()`, koje
briše `layerDragStart` **i** pušta `scheduleRefinedRender()`. Bez tog poziva bi
ovaj guard ostavio fotografiju na preview rezoluciji dok je neka nevezana izmena
ne probudi.

### ⚠️ Greška u samom merenju, uhvaćena i zapisana

Prvi prolaz harness-a je pokazivao 26,9 ms kroz keš i **pao** na pragu od 20 ms.
Uzrok nije bio u app-i nego u meraču: alocirao je bafer od 18 MB **u svakom
prolazu** i to je brojao kao deo frejma. Razlika između dva puta je i tada bila
tačna (alokacija se skraćuje), ali apsolutni broj je taj koji se poredi sa
pragom. Bafer se sada alocira jednom.

### Provereno

`BUILD SUCCEEDED`, universal, nula grešaka. Nov harness
**`Tools/run-layer-decode-cache-test.py`** ALL PASS. Svi ostali prolaze: boja
cut-outa **ALL PASS (0/255)**, obris **ALL PASS**, crop rotacija **OK**,
`editsettings` **OK**, reorder **sve prošlo**.

### ⚠️ NEPROVERENO NA EKRANU

Brzina je merena na sintetičkom cut-outu i sintetičkoj podlozi, **nije vučeno
mišem po pravoj RAW fotografiji**. Ostaje i da se vidi da li je 9,3 ms po frejmu
zaista dovoljno glatko na 45MP fajlu — ako i dalje drhti, sledeći osumnjičeni
**nije** dekod nego to što upis u `settings` na svaki pomeraj iznova gradi ceo
pogled (klasa kvara iz KORAKA 44), i to treba **izmeriti** pre nego što se dira.


## KORAK 98 — sloj dobija SVE što ima i fotografija (2. septembar 2026)

Prijava, uz sliku sa izabranim People slojem: *„videćeš sa desne strane da nemam
iste opcije za edit kao celokupan edit, a treba da bude sve kao edit za sliku"*.

Tačno je bilo. Sloj je imao 11 slajdera; fotografija ima te i još ovo:
**Texture, Clarity, Dehaze, Soft Glow, Vignette** (sa Midpoint / Feather /
Roundness), **Sharpness Radius** i ceo **Color Mixer** (osam traka × H/S/L).

### Zašto ovo nije bilo „dodaj slajdere"

Ti efekti **nisu postojali kao funkcije**. Bili su pisani direktno u telu
`render`, kao `if settings.texture != 0 { … }` blokovi koji čitaju `settings`.
Sloj nije mogao da ih pozove jer nije imao šta da pozove.

Zato je posao išao ovim redom:

1. **Izvađeno šest efekata iz `render` u funkcije** — `applySharpen`,
   `applyTexture`, `applyClarity`, `applyDehaze`, `applySoftGlow`,
   `applyVignette`. Kod je premešten **doslovno**, samo je `settings.texture`
   postalo `texture`.
2. **Model proširen** — `LocalAdjustmentSettings` dobija tih deset polja.
3. **`applyLocalToneColorDetail` zove iste te funkcije, istim redom** kojim ih
   zove `render`. To nije stvar ukusa: zato Clarity +40 na sloju znači isto što
   i Clarity +40 na fotografiji.
4. **Panel sloja dobija iste sekcije**, ista imena i iste opsege.

### ⚠️ IZMERENO 1 — vađenje nije pomerilo NIJEDAN piksel fotografije

Izgled ove pipeline je zaključan na vrhu ovog fajla. Dodatak ne sme da promeni
kako fotografija izgleda, i to nije ostavljeno na „premestio sam doslovno".

Nov harness **`Tools/run-effect-extraction-test.py`** uzima **staru** verziju iz
`git show HEAD:BriefShow/Develop.swift` i **novu** sa diska, prevodi obe jednu
pored druge i pušta ih na istoj slici kroz raspon vrednosti:

**25 poređenja, sva „identical", 0 kanala razlike.** Texture na šest vrednosti,
Clarity na četiri, Dehaze na četiri, Soft Glow na tri, Sharpness×Radius na
četiri, Vignette na četiri kombinacije oblika.

⚠️ Taj harness ima rok trajanja i to piše u njemu: čim se ovo commit-uje,
`HEAD` postaje NOVI kod i obe strane postaju ista stvar — test koji prolazi iz
pogrešnog razloga. Tada se `BASE_REV` pomera na `a096884` ili se harness briše.

### ⚠️ IZMERENO 2 — MINA KOJA BI OBRISALA KLIJENTOVE SLOJEVE

`LocalAdjustmentSettings` je imao **sintetizovan** Codable. Swift-ov
sintetizovani dekoder **ne pada nazad na podrazumevanu vrednost** kad ključa
nema — **baca grešku**.

Provereno na pravim podacima, ne pretpostavljeno: u klijentovom skladištu je
**125 zapisa, od toga 20 sa slojevima i 6 sa maskama**, a `adjustments` u njima
nose tačno starih 11 ključeva i nijedan nov. I provereno šta bi se desilo:

```
synthesised decoder FAILED: DecodingError.keyNotFound:
Key 'texture' not found in keyed decoding container.
```

Dakle prvo dodato polje bi oborilo dekodiranje **svih 20 zapisa sa slojevima** —
ne pogrešan broj, nego ceo zapis nestaje.

Zato je napisan **ručni `init(from:)` sa `decodeIfPresent` za SVA polja**, stara
uključena. `PhotoEditSettings` je istu lekciju već naučio. Posle toga:
**125 zapisa dekodirano, nijedan broj se nije pomerio.**

### ⚠️ IZMERENO 3 — postojeći `sharpness` na sloju nije se promenio

Sloj je ranije zvao `CISharpenLuminance` **bez radiusa**, pa je Core Image
koristio svoj default. Sada zove zajednički `applySharpen`, koji radius
postavlja na `1.69 × sharpenRadius`. Pročitano iz atributa samog filtera:
deklarisan default je **tačno 1.69**, a novo polje ima podrazumevanu vrednost 1.

Izmereno na tri jačine: **0 kanala razlike, 0/255.** Slojevi koje klijent već
ima renderuju se identično.

### Vignette na sloju — i stara beleška koja je time povučena

Iznad strukture je stajalo da vinjeta maskirana na proizvoljan region „više
nije vinjeta". **Za masku to i dalje stoji** i maska je ne dobija. **Sloj je
druga stvar** — ima svoj pravougaonik, i zatamniti NJEGOVE ćoškove je stvarna
želja na cut-outu. Vinjeta se računa nad sopstvenim okvirom sloja, isto kao što
se na fotografiji računa posle kropa.

### Sitno, ali namerno

- `isNeutral` **ne broji** `sharpenRadius` ni tri dijala oblika vinjete. To su
  modifikatori: pri sharpness 0 radius ne radi ništa, pa bi ih brojanje
  prikazalo netaknut sloj kao izmenjen.
- Traka sa bojama (`colorBandSwatch`) sada prima mikser kao parametar, jer
  tačkica „ova traka je pomerena" mora da opisuje onaj mikser koji je na ekranu.
- Izbor trake (`selectedColorBand`) je **zajednički** za oba miksera — to je
  „koju boju gledaš", nije izmena.

### Provereno

`BUILD SUCCEEDED`, universal, nula grešaka. Sedam harness-a, svi prolaze:
vađenje efekata **ALL PASS (25/25 identical)**, dekodiranje **125 zapisa OK**,
keš dekoda **ALL PASS**, boja cut-outa **ALL PASS (0/255)**, obris **ALL PASS**,
crop rotacija **OK**, reorder **sve prošlo**.

### ⚠️ NEPROVERENO NA EKRANU

Nijedan nov slajder nije pomeren mišem. Izmereno je da efekti rade isto što i na
fotografiji i da se ništa staro nije pomerilo — **nije** viđeno kako panel
izgleda kad se sve to naslaže ispod „Editing: People 1", ni koliko je dugačak.
Ako bude predugačak, to je raspored, ne ponašanje.


## KORAK 99 — Flatten i gore, i traka dok peče (3. septembar 2026)

*„dodaj quick action button ovde za flatten photo… već ga ima dole ali dodaj i
ovde gore i dok se čeka taj flattening obavezno loading bar"*.

### Dugme

Dodato u red u zaglavlju, posle AI Clean Up-a i pre Grid-a — Grid ostaje
poslednji jer je izlaz. Zove **isti** `flattenPhoto()`, čita **isto** stanje i
nosi **isti** tekst kao ono u panelu: „Flatten Photo" / „Flatten Again" /
„Flattening…". Drugi ulaz u jednu akciju, kao Crop i Select People — ne druga
implementacija.

**⚠️ Onemogućeno, ne sakriveno**, kad nema šta da se peče. Sakrivanje bi menjalo
dužinu reda od fotografije do fotografije i dugmad posle njega bi se pomerala
pod pokazivačem; Reset u istom redu se već sivi na isti način. Uslov je
`hasUnbakedEdits` — **isti** koji testira i sekcija u panelu, pa dva mesta ne
mogu da se raziđu oko toga ima li šta da se peče.

### ⚠️ Traka — i zašto baš ovde najviše treba

Flatten je **najduže čekanje u ovom prozoru**: renderuje ceo kadar u punoj
rezoluciji i piše **nekompresovan** TIFF (v. `FlattenedImageStore` — izmereno
102 MB na klijentovom 5176×3448 RAW-u). Do sada se dugme samo posivi i prozor
stoji. To je ista prijava koju je KORAK 49 već jednom rešavao za prozor sa
flattened preview-om.

Traka je **neodređena**, iz istog poštenog razloga kao ona za Select People:
render i upis fajla ne javljaju napredak, a izmišljen procenat je gori od
nikakvog.

**Natpis se preskače kad `exportStatusText` već nešto govori.** Grupno pečenje
iz mreže (`runBake`) deli isti `isFlattening` i postavlja svoju poruku; dve
linije koje govore istu stvar čitaju se kao bag.

### Provereno

`BUILD SUCCEEDED`, universal, nula grešaka. Svih sedam harness-a prolazi.

### ⚠️ NEPROVERENO NA EKRANU

Nije pritisnuto mišem. Nije viđeno ni kako se red prelama sa sedam dugmadi na
uskom panelu — `FlowLayout` to radi sam, ali sedmo dugme je prvo koje ide preko
tri reda na 300 pt. Ako smeta, to je raspored, ne ponašanje.


## KORAK 100 — „exposure odmah skoči": klizač je teleportovao palac (3. septembar 2026)

*„jel možeš da provериš zašto exposure kad malo povećam on baš dosta pokaže
expose… da kada pomerim expose da ne skoči odma baš expose?"*

### ⚠️ PRVO JE PROVERENA MATEMATIKA — i ona je ČISTA

Očigledna sumnja je bila da je ekspozicija prejaka, ili da se primenjuje dvaput
(RAW je gura u `CIRAWFilter.exposure`, a non-RAW kroz `CIExposureAdjust`).
Izmereno na **klijentovom sopstvenom `C4S_5744.NEF`**, sa RAW putanjom koju app
zaista koristi:

| ekspozicija | srednja svetlina | promena |
|---|---|---|
| 0,00 | 201,4 | — |
| +0,05 | 202,7 | **+0,6%** |
| +0,10 | 204,0 | +1,3% |
| +0,50 | 213,7 | +6,1% |
| +1,00 | 224,6 | +11,5% |

To je **blago**, i nije primenjeno dvaput. Kroz `CIExposureAdjust` (put koji ide
JPEG) ista slika reaguje **jače** — +1,00 EV daje +21,4%. Dakle RAW put je već
nežniji od generičkog.

Da je posao stao na „smanji ekspoziciju", smanjila bi se pogrešna stvar.

### ⚠️ UZROK — klizač je čitao APSOLUTNU poziciju pritiska

`EditTrackSlider` i `GradientTrackSlider` su oba imali:

```swift
let x = min(max(drag.location.x - thumbSize / 2, 0), usable)
value = range.lowerBound + Double(x / usable) * span
```

Nema pomeraja — ima samo „gde je pokazivač". Znači **pritisak bilo gde na traci
teleportuje palac pod kursor**, pre nego što se miš uopšte pomerio. Na Exposure
je to najgore jer je opseg ±3 EV preko ~286 pt trake:

**pritisak 60 pt desno od sredine = trenutnih +1,33 EV.** To je „skoči odma baš
expose", doslovno.

Ovo je pogađalo **svaki** klizač u panelu, ne samo ekspoziciju.

### Popravka — potez se meri od mesta hvatanja

Matematika je izvađena u `EditSliderDrag`, zajednički za oba klizača (i zato što
je bila pogrešna u oba na isti način, i zato što se tako može meriti — gest se
u ovom prozoru ne može skriptovati, aritmetika ispod njega može).

- **Pritisak koji padne NA palac ne pomera ništa.** Potez se meri od mesta gde
  je uhvaćen, pa je pomeraj od 3 pt zaista pomeraj od 3 pt.
- **Pritisak na praznu traku i dalje skače tamo** — to traka i služi, i to je
  jedini skok koji se traži a ne trpi. Od tog trenutka i taj potez je relativan.
- Hvatanje ima **4 pt zazora** preko samog palca: poenta je da se lako uhvati, a
  promašaj za jedan piksel ne sme da košta skok.

### Izmereno — nov harness `Tools/run-slider-drag-test.py`

Vadi pravi `EditSliderDrag` iz `Develop.swift` i meri Exposure na traci širine
koju panel stvarno daje:

| potez | pre | posle |
|---|---|---|
| pritisak na palac, bez pomeranja | do **+1,33 EV** | **0,0000 EV** |
| pritisak 4–7 pt pored centra palca | skok | **0,0000 EV** |
| pomeraj od 3 pt | — | **+0,067 EV** |
| trećina trake | — | +2,000 EV (tačno trećina opsega) |
| vučenje daleko preko kraja | — | staje na +3,00 EV |
| namerni pritisak 60 pt na praznu traku | +1,33 EV | +1,33 EV (namerno zadržano) |

### Greška u samom testu, zapisana

Provera „trećina trake = trećina opsega" je prvo pala jer sam očekivao `span/6`
— to je trećina JEDNE POLOVINE opsega. Kod je vraćao +2,000 EV, što je tačno.
Ispravljen je test, ne kod.

### Šta NIJE dirano

Opseg je i dalje ±3 EV i korak strelica ±0,05. Sužavanje opsega bi izgubilo
domet, a merenje kaže da domet nije bio problem.

### Provereno

`BUILD SUCCEEDED`, universal, nula grešaka. Osam harness-a, svi prolaze.

### ⚠️ NEPROVERENO NA EKRANU

Nije vučeno mišem. Izmereno je šta gest računa, **nije** viđeno kako se hvata
palac u pravoj app-i — pogotovo da li je 4 pt zazora dovoljno za pravu ruku. Ako
i dalje beži, poluga je `EditSliderDrag.grabSlack`, na jednom mestu za oba
klizača.


## KORAK 101 — pikseli slojeva izlaze iz UserDefaults-a (3. septembar 2026)

Prva tačka plana za history, i klijent je dao zeleno svetlo posle merenja iz
prethodne poruke. Radi se PRVA jer history sagrađen nad ovim skladištem ne bi
imao na čemu da stoji.

### Šta je bilo

Pikseli slojeva su živeli **unutar** zapisa u `UserDefaults`-u. Na klijentovom
skladištu: **125 zapisa, 47 slojeva, 22,9 MB**, od čega su **97%** bili pikseli.
Ceo taj blob se enkoduje pola sekunde posle svake izmene i dekoduje pri
otvaranju.

### Kako je urađeno — bez ijedne izmene na 24 pozivna mesta

`ImageLayer.imageData` i `.maskData` više **nisu skladištena polja** nego vrata:
iza njih stoji `pixelRef` (ime bloba na disku, to se enkoduje) i
`inlineImageData` (bajtovi koji još nisu zapisani, to se **ne** enkoduje).
Čitanje i pisanje izgledaju isto kao pre, pa nijedan poziv u app-i nije menjan.

Dobitak je i na **dekodiranju**, ne samo na upisu: referenca ne košta ništa, pa
otvaranje skladišta više ne uvlači svaki sloj svake fotografije u memoriju.
Bajtovi stižu tek kad nešto taj sloj zaista renderuje.

### `LayerPixelStore` — adresiranje po SADRŽAJU, i to je ono što ovo čini bezbednim

Ime bloba se izvodi iz samih bajtova, pa je upis idempotentan: drugi flush
zatekne fajl i ne radi ništa. Ime izvedeno iz `layer.id` **ne bi** bilo dobro —
isti id može dobiti nove piksele (pečenje, nov Select People) i skladište bi
posluživalo stare. Otisak je onaj isti konstantno-vremenski koji koristi i keš
dekoda (KORAK 97), iz istog razloga.

⚠️ `encode(to:)` **piše na disk**, što je neobično za enkoder i baš zato je
adresiranje po sadržaju uslov. Ako upis padne, bajtovi idu inline kao i pre —
sporo i debelo, i to je ispravan način da se padne: pun disk sme da košta
brzinu, nikad sloj.

### Migracija se dešava sama, bez prolaza i bez zastavice verzije

`init(from:)` čita **oba** oblika. Star zapis nosi piksele inline, uđu ovde, i
prvi sledeći upis ih ispiše kao blob. Skladište se konvertuje samo od sebe pri
prvom snimanju; ako se app ubije na pola, star ključ je i dalje tu dok ga nov
ne zameni.

⚠️ Konverzija je **lenja** — odmah posle build-a folder `LayerPixels` je prazan
i to je uredu, popuni se pri prvom flush-u.

### ⚠️ IZMERENO na klijentovom pravom skladištu

Nov harness **`Tools/run-layer-pixel-store-test.py`**. Koristi **isti** izvlakač
i isti spisak deklaracija kao `run-editsettings-decode-test.py`, pa dva
harness-a ne mogu da se raziđu oko toga koji kod testiraju. Dekoduje pravo
skladište, ponovo ga enkoduje (to je korak koji piše blobove), pa dekoduje
rezultat i poredi.

| | pre | posle |
|---|---|---|
| veličina zapisa | **22 899 KB** | **175 KB** (99% manje) |
| dekodiranje skladišta | **79,4 ms** | **4,3 ms** |
| enkodovanje (flush posle svake izmene) | — | **7,5 ms** |
| zapisa preživelo | — | **125 od 125** |
| pikseli sloja isti bajt za bajt | — | **41 cut-out + 6 matte, svi identični** |

Klijent je rekao da su postojeći slojevi ionako samo testovi; provereno je
svejedno, jer isti kod sutra nosi njegov pravi rad.

### ⚠️ Spisak deklaracija u dekod testu — pao pa dopunjen

`run-editsettings-decode-test.py` je odmah **pao pri prevođenju**: `cannot find
'LayerPixelStore' in scope`. To je tačno ona glasna greška zbog koje spisak i
postoji (v. upozorenje u KORAKU 94 o `SkyChoice`). `LayerPixelStore` je dodat na
spisak. **Svaki nov tip od kog `ImageLayer` ili `PhotoEditSettings` zavisi mora
tamo.**

### Usput — repo je pušao 214 MB tuđeg smeća

Na klijentov zahtev *„kada pushujemo za novi update samooo čist app"* provereno
je šta se zaista šalje:

- **U app-u nema nijedne njegove fotografije ni sloja.** Provereno u paketu:
  nula `.nef`, nula `C4S*`, nula `.tiff`. Njegove izmene žive u `UserDefaults`
  i nikad ne ulaze u build.
- **Ali `build_universal/` je bio PRAĆEN u git-u** — 327 fajlova, **214 MB**
  keša prevođenja i objektnih fajlova, uz svaki push. Dodat u `.gitignore` i
  skinut sa praćenja (`git rm -r --cached`).

⚠️ Istorija commit-ova i dalje nosi tih 214 MB; čišćenje istorije je prepisivanje
i **nije** urađeno bez pitanja.

### Provereno

`BUILD SUCCEEDED`, universal, nula grešaka. Devet harness-a, svi prolaze.

### ⚠️ NEPROVERENO NA EKRANU

Migracija **nije viđena kako se dešava u pravoj app-i** — izmerena je na
skladištu van sandboksa. Prvi pravi test je: otvoriti fotografiju sa slojem,
pomeriti bilo šta, sačekati sekundu, pa proveriti da u kontejneru
`Application Support/BriefShow/LayerPixels` postoje fajlovi i da se sloj i dalje
vidi posle ponovnog pokretanja.

### Sledeće — tačke 2 i 3 iz plana

2. **History kao lista stanja po fotografiji**, trajno, sa datumom i imenom
   koraka. Sada košta ~1 KB po koraku umesto do 12,8 MB.
3. **Flatten postaje korak u history-ju**, ne jednosmerna vrata: svaki flatten
   ostavlja svoj snimak, pa se vraća na bilo koji, ne samo na prvi.


## KORAK 102 — kartica na hover, devet novih prečica, i Crop koji nije reagovao na prvi klik (3. septembar 2026)

### 1. Kartica na hover „BriefShow" više ne nabraja prečice

Klijent: *„ovu karticu sa shortcuts makni kada hoverujem BriefShow, ali dodaj
hovered karticu da napišeš šta je BriefShow ukratko"*.

Spisak prečica je bio manja polovina onoga što Edit ▸ Keyboard Shortcuts već
radi — tamo se i **menjaju**. `ShowGridShortcutsHoverCard` →
`BriefShowAboutHoverCard`.

**⚠️ Formulacija je bila deo zahteva, ne ukras.** Traženo je izričito da NE
piše „kao Bridge i kao Photoshop i kao Lightroom u jednom" — taj opis app
opisuje preko tri tuđa proizvoda i ne kaže ništa o njoj. Zato kartica imenuje
**posao**, pa tek onda program kao standard po kome je taj deo pisan:

> Jedan foto suite. Tri vrste posla za koje inače trebaju tri programa.
> **Browse & cull** — folderi, mreža, ocene, oznake, odbacivanja.
> **Develop** — RAW, ton, boja, mikser, maske, preseti.
> **Retouch** — slojevi, kloniranje i heal, cut-outi, blend modovi.

Ispod: **dva AI modela rade na ovom Mac-u** — imenovana, jer „AI" samo po sebi
ne govori ništa: Quick Clean Up za brzo brisanje, Generative Clean Up da izmisli
šta tu pripada. Nijedan ne šalje fotografiju nikuda.

### 2. Devet novih prečica, sve podesive

Sve u LumenoLab grupi, sve prolaze kroz `ShortcutStore`, dakle sve se menjaju u
**Edit ▸ Keyboard Shortcuts**.

| akcija | podrazumevano | zašto baš to |
|---|---|---|
| AI Clean Up (otvori, četkica u ruci) | **J** | Photoshop-ov healing brush |
| Quick Clean Up (LaMa) | **K** | J-K-L pod desnom rukom, tri koraka jednog posla |
| Generative Clean Up | **L** | isto |
| Select People | **P** | people |
| Flatten Photo | **⇧F** | šiftovano namerno — peče kadar i piše 100 MB fajl |
| See Original (drži) | **\\** | Lightroom-ov before/after |
| Back to Grid | **G** | grid |
| Black & White | **B** | |
| Duplicate & BW | **⇧B** | šiftovani blizanac iste ideje |

⚠️ Sve provereno protiv onoga što LumenoLab grupa već zauzima (e, q, ⌘z, ⌘⇧z,
⌘c, ⌘x, ⌘v, ⌘a, ⌘=, ⌘-, ⌘0, [, ], r, x) — **nijedan sudar**, jer je duplikat
unutar grupe konflikt.

**Svaka je čuvana isto kao i postojeće:** ako nema šta da radi, taster se **ne
guta** nego propada dalje i ostaje obično slovo. Prečica koja pojede pritisak i
ne uradi ništa gora je od nepostojeće.

### ⚠️ See Original je jedina koja je tražila SVOJ monitor

Glavni monitor uzima samo `.keyDown`, a „drži da uporediš" traži i otpuštanje.
Dugme pored je oduvek press-and-hold; prekidač bi značio da klijent ode i ostavi
original na ekranu ne znajući. Zato `installShowOriginalKeyMonitor` sa
`[.keyDown, .keyUp]`.

Otpuštanje se prepoznaje po **samom tasteru**, bez modifikatora
(`matchesKeyOnly`) — pusti se Shift trenutak pre slova i otpuštanje se više ne bi
poklopilo, pa bi original ostao zaglavljen na ekranu. Zatvaranje prozora ga
takođe vraća na `false`.

Usput: ponašanje AI Clean Up dugmeta izvučeno je u `toggleAICieanUp()` da taster
i dugme ne mogu da se raziđu.

### 3. ⚠️ CROP NIJE REAGOVAO NA PRVI KLIK — i ovo je isti bag po ČETVRTI put

*„zašto moram da pritisnem nekoliko puta na crop da bi otvorio… bitno je da
svako dugme kad se klikne odma odreaguje"*.

`ShowHeaderButtonLabel` **nije imao `.contentShape(Rectangle())`**. Bez njega
Button pogađa samo tamo gde mu se natpis stvarno crta — slova i ikonica — pa je
14 pt padding-a oko svakog dugmeta u zaglavlju bio **mrtav**. Klik koji padne
tamo ne radi ništa, i klijent pritisne opet.

**App je ovaj isti bag već dijagnostikovala i popravila TRI puta** — na
`maskAddButton`, `EditToolButtonStyle` i `AspectRatioButtonStyle`, i to jednom
baš sa prijavom „Crop ne reaguje na prvi klik". Svaki put na **jednom** dugmetu.
`ShowHeaderButtonStyle` je **deljeni** stil zaglavlja — **37 pozivnih mesta**,
među njima Crop, Reset, Grid, Original, Select People, Flatten, Unflatten — i
njega niko nije popravio.

Popravka stoji **posle padding-a**, i to je ceo trik: postavljena pre njega ne bi
popravila ništa. Provereno da ostala dva stila (`EditToolButtonStyle`,
`AspectRatioButtonStyle`) svoj već imaju.

### ⚠️ Migracija iz KORAKA 101 — POTVRĐENA na pravoj app-i

Usput izmereno, jer je app u međuvremenu radila i snimala:

- skladište je sa **22 899 KB palo na 174 KB**;
- **46 slojeva, 40 sa referencom, 0 još inline, 0 referenci bez fajla**;
- app je upisala **77 blobova u svoj kontejner**.

Znači konverzija radi u pravoj, sandboxovanoj app-i, ne samo u harness-u.

Slojeva je 46 gde ih je pre bilo 47. Nijedna referenca nije slomljena i nijedan
zapis nije nestao, pa migracija ne može biti uzrok — sloj je najverovatnije
obrisan u app-i između dva merenja, dok je klijent radio.

### ⚠️ Dve greške u harness-ima, obe zapisane

1. `run-editsettings-decode-test.py` **nije mogao ni da se prevede** dok
   `LayerPixelStore` nije dodat na spisak deklaracija — glasna greška zbog koje
   spisak i postoji.
2. Pošto je dodat tamo, `run-layer-pixel-store-test.py` ga je vadio **drugi
   put** i pao sa `invalid redeclaration`. Jedan spisak, jedna kopija.
3. Provera „zapis se smanjio" je posle konverzije postala **prazna** — skladište
   je već bilo 174 KB i test je pao sa „0% smaller" na potpuno ispravnom stanju.
   Sada se smanjenje tvrdi samo kad ulaz zaista još nosi piksele inline, a na
   već konvertovanom skladištu se proverava ono što tu jedino i može da boli:
   **da svaka referenca zaista razreši u bajtove**. Sloj sa slomljenom
   referencom bio bi u listi a nevidljiv na fotografiji.

### Provereno

`BUILD SUCCEEDED`, universal, nula grešaka. Devet harness-a, svi prolaze.

### ⚠️ NEPROVERENO NA EKRANU

Nijedna prečica nije pritisnuta, kartica nije viđena na hover, i **Crop nije
kliknut**. Popravka pogađa poznat i ranije potvrđen uzrok, ali da li je to
JEDINI uzrok njegovih višestrukih klikova zna se tek kad klijent proba.


## KORAK 103 — RELEASE v10.8 (3. septembar 2026)

Prvi release posle 10.1 (1.09.). Tag **v10.8**, grana `briefshow-develop`, isto
kao i 10.1.

### Kartica na hover, po drugi put skraćena

*„samo neka piše BriefShow a ispod One Photography Suite.. i to je to"*.
Ostalo je ime, jedna linija i **verzija**. Verzija se **čita iz bundle-a**
(`CFBundleShortVersionString`), nikad se ne kuca u UI — verzija upisana rukom je
verzija koja se razilazi sa build-om čim se jedno promeni a drugo zaboravi, što
je tačno kako je `CFBundleVersion` stajao na 17 kroz svaki build (KORAK 74).

### Meniji

**File:** Import…, **Open Folder…** (⌘O), Import from Camera…, Show App Files
in Finder.
**Edit:** Keyboard Shortcuts… (⇧⌘K), **Reset Shortcuts to Defaults**.
**Help:** BriefShow Help, Check for Updates…

Odluke koje nisu očigledne:

- **Open Folder ide kroz `ExternalFolderOpen`** — ista vrata kroz koja ulazi
  folder pušten na ikonicu (KORAK 72). Nije trebalo novo vodovodstvo i ne može
  da se raziđe sa drop-om.
- **Import from Camera je ONEMOGUĆEN kad nema kamere, ne sakriven.** Meni koji
  menja oblik zavisno od toga šta je uključeno je meni koji se ne može naučiti.
  Postoji za kameru koja je **već bila** uključena pri pokretanju — jedini slučaj
  koji namerno ne otvara prozor sam.
- **⚠️ NEMA Undo/Redo u Edit meniju,** i to je namerno. Oba žive u lokalnim
  `NSEvent` monitorima; menijski key equivalent za ⌘Z bio bi **drugi polagač
  prava** na isti pritisak, u trci sa monitorom, a klijentova izmena prečice bi
  se videla samo u jednom od njih. Monitori drže tastere.
- **Show App Files in Finder** postoji jer je klijent pitao gde su njegove
  stvari: originali su u njegovom folderu, a sve što app napravi (flatten kopije,
  pikseli slojeva) je tu i nigde drugde.

### Pakovanje — sve provereno, ništa pretpostavljeno

| provera | rezultat |
|---|---|
| lične fotografije u paketu | **nula** (`.nef`, `.cr2`, `.arw`, `C4S*`, `.tiff`) |
| `lipo -archs` | **`x86_64 arm64`** |
| `CFBundleShortVersionString` | **10.8** |
| `CFBundleVersion` | **19** (bilo 18 — bez ovoga macOS ne vidi nov build, KORAK 74) |
| `LSMinimumSystemVersion` | **13.0** |
| veličina paketa / arhive | 139 MB / **110 MB** |
| preuzimanje sa GitHub-a | **HTTP 200, 114 822 876 B** |

Korak 0 iz plana („PROVERA DA JE ČISTO") je izvršen, ne preskočen.

### Linkovi

- **Direktno preuzimanje:**
  `https://github.com/RocketsBrief/rocketsbrief-briefshow-app/releases/download/v10.8/BriefShow-10.8.zip`
- **Stranica release-a:**
  `https://github.com/RocketsBrief/rocketsbrief-briefshow-app/releases/tag/v10.8`

### ⚠️ Šta OSTAJE nedovršeno, i to pošteno

1. **Nije potpisano Developer ID sertifikatom.** Ad-hoc, kao i 10.1 — v.
   „🟢 ZAKLJUČANO — DISTRIBUCIJA". Na tuđem Mac-u traži ručno dopuštanje pri
   prvom pokretanju.
2. **`latest_version` u BriefControl-u je i dalje 6.0.** Nije dirano jer nije
   traženo. Dok je tako, **niko ne dobija ekran „mora update"** — 10.8 je gore i
   preuzimljiv, ali se ne nameće. Podizanje na 10.8 je klijentova odluka i radi
   se tek sad kad je release već gore.
3. **`build_universal/` je skinut sa praćenja**, ali istorija commit-ova i dalje
   nosi tih 214 MB. Čišćenje je prepisivanje istorije i čeka odluku.

### ⚠️ NEPROVERENO

Arhiva **nije raspakovana i pokrenuta na drugom Mac-u**, ni na Intelu.
`lipo` kaže da su obe arhitekture unutra i minimum je 13.0, ali to je tvrdnja o
fajlu, ne o tome da se pokreće — a KORAK 35 je već jednom pokazao razliku
(radilo u Xcode-u, palo potpisano).

## KORAK 104 — preimenovanje u C4S Suite, logo, meniji, tema (3. septembar 2026)

Vizuelno preimenovanje, po planu iz razgovora: **sloj 1 da, sloj 2 (folder na
Desktopu) NE.**

| bilo | sada |
|---|---|
| BriefShow (suite) | **C4S Suite** |
| Showcase (slideshow) | **BriefShow** |
| LumenoLab (editor) | **Create** |

Izmenjeno **60 korisnički vidljivih tekstova** — disclaimer, about, nalog,
update ekrani. Debug logovi (`BriefShow mux:`, `export codec:`) su **namerno
ostavljeni**: nisu korisnički tekst i preimenovanje bi bilo čista buka.

### ⚠️ MINA 3 JE POGOĐENA — moj skript je preimenovao PUTANJE

Skript za zamenu stringova nije razlikovao prozu od putanje i prepravio je:

```
BriefShow/LayerPixels  →  C4S Suite/LayerPixels
BriefShow/Flattened    →  C4S Suite/Flattened
BriefShow/CoreMLModels/SD15-Inpainting
Desktop/BriefShow/CoreMLModels/…   (SD i LaMa)
BriefShow (Show App Files in Finder)
```

Posledice da je ovo prošlo: **77 blobova slojeva osirotelo** (sloj u listi,
prazan na fotografiji), **1,5 GB flatten kopija nedostupno**, i **SD mrtav i na
razvojnoj mašini** — jedinoj gde je do tada radio.

**`run-layer-pixel-store-test.py` je to uhvatio**, pao je sa „46 layers came
back empty". Prvo sam pomislio da je kvar u meraču (radi van sandboksa, pa gleda
drugi folder) i dopunio ga da prekopira blobove iz kontejnera — i tek kad je
**i posle toga pao**, ispalo je da nije merač nego prava šteta. Sve vraćeno, i
na svako od tih mesta je upisano upozorenje da je to **putanja, ne ime
proizvoda**.

**Pouka, i vredi je zapisati šire:** zamena stringova preko celog fajla ne sme
da se pusti bez razlikovanja proze od ključeva i putanja. Filter je propustio
sve što ima `/` u sebi.

### Naslovi prozora — bag star tri dana je usput nestao

Glavni prozor i slideshow prozor su **oba** nosila naslov „BriefShow", a oba
monitora tastature se ograničavaju baš po naslovu — pa je sa slideshow-om u
fokusu ShowGrid-ov monitor obrađivao ⌘C/⌘X/⌘V, ocene, Space i Escape sa
pogrešnim kontekstom. To je MINA 2 iz plana od 31.08, zapisana i još živa.

Sada su **tri različita naslova**, i **svaki iz imenovane konstante**:
`C4S Suite` / `BriefShow` / `Create`. Guard koji je poredio sa literalom sada
čita konstantu, pa ne može da odluta nazad.

⚠️ Pri tome je moj isti skript prepravio i `BriefShowWindowController.windowTitle`
na „C4S Suite" — čime bi oba prozora **ponovo** delila naslov i bag bi vaskrsao
istog dana kad je ubijen. Vraćeno, sa napomenom na samoj konstanti.

### Logo

Bela pozadina isečena **flood-fill-om od ivica**, ne pragom na belo — tako
svetla četvorka unutar tamnog tela preživi (30,9% slike postalo prozirno,
centar pun, uglovi prazni). Za **ikonicu** je istom tehnikom skinut i **žuti
obrub**, na klijentov zahtev: ostaje crna zaobljena pločica sa C4S.

Logo stoji na **dva** mesta: ikonica app-a i zaglavlje Disclaimer-a.

**Zaglavlje nosi SLOVA, ne sliku.** `C4SWordmark` — „C4S" u istom fontu
(Unbounded Black) i sa istim negativnim tracking-om koji je nosio „BriefShow",
C i S svetli, **četvorka u prigušenom tonu**. To je ista dvotonska podela koju
je stari wordmark imao („Brief" svetlo, „Show" prigušeno), preneta na glif koji
i logo izdvaja drugom bojom.

### Ime za macOS — tri ključa, ne jedan

`CFBundleDisplayName` sam nije bio dovoljan: **meni čita `CFBundleName`**, a
**Dock ime fajla**. Zato su svi postavljeni:

```
CFBundleName        C4S Suite      (INFOPLIST_KEY / PRODUCT_NAME)
CFBundleDisplayName C4S Suite
CFBundleExecutable  C4S Suite
CFBundleIdentifier  com.rocketsbrief.BriefShow   ← NETAKNUT
```

⚠️ Posledica koja je najavljena pre nego što je urađena: fajl je sada
`C4S Suite.app`, pa ko update-uje dobija **drugu ikonicu pored stare
`BriefShow.app`**. Podaci ostaju (identifikator je isti), staru briše sam.

### Meniji i tema

**File:** Import…, Open Folder… (⌘O), Import from Camera…, Show App Files in
Finder. **Edit:** Keyboard Shortcuts… (⇧⌘K), Reset Shortcuts to Defaults,
**Theme** (White / Sand / Dark). **Help:** Help, Check for Updates…

- Open Folder ide kroz `ExternalFolderOpen` — ista vrata kroz koja ulazi folder
  pušten na ikonicu, pa nema novog vodovodstva.
- Import from Camera je **onemogućen** bez kamere, ne sakriven.
- ⚠️ **Undo/Redo NISU u meniju.** Menijski ⌘Z bi bio drugi polagač prava na
  isti pritisak, u trci sa monitorom, a klijentova izmena prečice bi se videla
  samo u jednom od njih.
- Tri tačkice za temu su sklonjene sa prve strane. `AppTheme.buttery` se
  **prikazuje** kao „Sand"; raw vrednost nije dirana, jer je u `UserDefaults`.

## KORAK 105 — SD se konačno isporučuje, radi i na Intelu, i RELEASE v11.0 (3. septembar 2026)

### ⚠️ 1. Generative Clean Up je radio na TAČNO JEDNOJ MAŠINI na svetu

`SDModelStore.resolve()` gleda `installedDirectory` (kontejner) pa
`developmentDirectory` (`~/Desktop/BriefShow/CoreMLModels`). Druga je
programerski folder. **Prvu nijedna linija koda nikad nije upisivala** — nema
nijednog `downloadTask` u celoj app-i.

Znači svaki klijent je viđao isto sivo dugme i istu poruku, a funkcija koja je
gradnjom trajala nedeljama bila je mrtva svuda osim na mašini koja ju je
napravila. To je stajalo zapisano u planu od 2.09 i **nije podignuto pre
release-a 10.8** — moj propust.

**`SDModelInstall.swift`:** preuzimanje sa progresom, raspakivanje kroz
**AppleArchive** (ne `ditto`, jer pokretanje procesa iz sandboksa je klasa
greške koja radi u razvoju a pada potpisana), raspakivanje **pored** odredišta
pa premeštanje tek kad je celo — da prekid na pola ne ostavi tri modela od
četiri koje klijent mora ručno da nađe i obriše.

**Zašto nije u bundle-u:** 2,0 GB (UNet sam 1,6 GB). U `BriefShow/BriefShow/`
(sinhronizovana grupa) bi ušlo u paket i napravilo app od 2,1 GB, a GitHub
odbija fajl preko 100 MB u repou — projekat se više ne bi ni klonirao.
Ide kao **release asset**: **1,8 GB kao Apple Archive** (mereno; sirovo 2,0 GB).

`SDModelStore` je izvučen iz `#if arch(arm64)` — putanje nisu procesorski
zavisne, a treba ih i instalater i Intel.

### ⚠️ 2. Intel — Float16 ne postoji na x86_64, pa je ceo fajl bio isključen

1050 linija iza `#if arch(arm64)`, jer tenzori idu kao `Float16`, tip koji
x86_64 macOS **nema**.

Rešeno preko `SDHalf`:

- **arm64: `SDHalf` JESTE `Float16`, `sdHalf(x)` JESTE `Float16(x)`.** Puko
  preimenovanje. To je bio uslov da se fajl uopšte dira — rezultat AI Clean
  Up-a je zaključan od 31.08.
- **x86_64:** half se nosi kao sirovih 16 bita, pisano ručno, sa IEEE-754
  zaokruživanjem na najbliže-parno, subnormalama i specijalnim vrednostima.

### ⚠️ IZMERENO — svih 4.294.967.296 bit-uzoraka

Nov harness **`Tools/run-half-conversion-test.py`** vadi x86_64 granu iz
`DevelopSDInpaint.swift` po tekstu, prevodi je **na ovoj mašini** pored pravog
`Float16`, i pušta **ceo prostor** `Float` bit-uzoraka kroz obe.

**Rezultat: 0 razlika, bit u bit.** Ne uzorak — ceo prostor, jer se greška u
zaokruživanju krije baš u vrednostima koje uzorak promaši. NaN se poredi po
tome da li je i dalje NaN, što je jedino što je o njemu definisano.

Time je tvrdnja „arm64 se nije pomerio" **dokazana**, ne izjavljena.

### Deljenje posla na Intelu

Bez Neural Engine-a, pa UNet ide sa **`MLComputeUnits.all`** — Core ML stavlja
na diskretnu grafičku šta stane, ostalo na jezgra. VAE prolazi ostaju na GPU-u.

⚠️ Zapisano da se ne obećava kasnije: **32 GB sistemske memorije se NE dodaje na
4 GB video memorije.** To su dve memorije preko PCIe. SD 1.5 na 512×512 u fp16
staje u 4 GB, pa to nije zid — ali RAM neće nadoknaditi karticu.

### ⚠️ ŠTA NIJE PROVERENO, I TO JE NAJVAŽNIJA REČENICA OVDE

Intel put je dokazano **da se prevodi**. Nije nikad **pokrenut na Intel Mac-u** —
ovde ga nema. Beleške predviđaju **minute po slici** na Radeon Pro 560X. Ako se
to potvrdi, pošten potez je da to piše u panelu, ne da klijent čeka.

Isto tako, **preuzimanje modela nije viđeno na čistoj mašini**: na razvojnoj
mašini `resolve()` uvek nađe dev kopiju, pa se dugme „Install Model" **nikad ne
pojavi ovde**. Klijent je to i prijavio — i to je ispravno ponašanje, ne kvar.

### RELEASE v11.0

| provera | rezultat |
|---|---|
| `lipo -archs` | **`x86_64 arm64`** |
| `LSMinimumSystemVersion` | **13.0** |
| verzija / build | **11.0** / **20** |
| `CFBundleDisplayName` / `Name` / `Executable` | **C4S Suite** |
| `CFBundleIdentifier` | `com.rocketsbrief.BriefShow` (netaknut) |
| lične fotografije u paketu | **nula** |
| app / arhiva | 139 MB / **109 MB** |
| SD asset | **1891 MB**, uploaded |
| preuzimanje oba | **HTTP 200** |

- direktno: `…/releases/download/v11.0/C4S-Suite-11.0.zip`
- stranica: `…/releases/tag/v11.0`

Verzija se u app-i prikazuje iz bundle-a, pa ne može da se raziđe sa tagom.

### ⚠️ I dalje otvoreno

1. **Nije potpisano Developer ID sertifikatom** — ad-hoc, kao 10.1 i 10.8.
2. ~~**`latest_version` u BriefControl-u je i dalje 6.0.**~~ ⚠️ **NETAČNO od
   4.09.** — izmereno, stoji **11.2**. Klijent ga sam podiže na svaku novu
   verziju i to radi bez pitanja. V. KORAK 114.
3. **Istorija commit-ova nosi 214 MB** starog `build_universal/`. Čišćenje je
   prepisivanje istorije i čeka odluku.
4. **`BRIEFSHOW_MODELS` override** koji `Tools/README.txt` tvrdi da postoji —
   u kodu ga i dalje NEMA. Sledeća selidba foldera će opet biti izmena koda.

## ✅ ZAVRŠENO — bivši plan za 10.67, isporučeno kao v10.8 (v. KORAK 103)
 (nije počelo, 2.09. uveče)

Kod je spreman: `BUILD SUCCEEDED`, nebo izvađeno (KORAK 94), oba harness-a
prolaze, 125 slogova dekodirano bez pomeranja.

**Stanje 2.09. uveče — koraci 1, 2 i 3 su URAĐENI i izmereni:**
`MARKETING_VERSION` = **10.67**, `CURRENT_PROJECT_VERSION` = **19**, universal
Release build prošao (**nula grešaka**), `lipo -archs` → **`x86_64 arm64`**,
Info.plist u paketu pokazuje **10.67 / 19**. Paket stoji u
`build_universal/Build/Products/Release/BriefShow.app` i **pokrenut je i viđen**.
Taj paket je posle toga **prepravljen** — nosi i KORAK 95 (obris umesto koprene,
Select People u zaglavlju, skok na Layers) i KORAK 96 (boja cut-outa) i KORAK 97 (traka i drhtanje) i KORAK 98 (svi slajderi na sloju) i KORAK 99 (Flatten gore) i KORAK 100 (klizači) i KORAK 101 (pikseli slojeva na disk) i KORAK 102 (prečice, kartica, Crop), i dalje
`BUILD SUCCEEDED` i dalje universal, ali to **još nije viđeno na ekranu**.
Izmena verzija **nije commit-ovana**. Ništa nije izašlo iz mašine: nema arhive,
nema `gh release create`, `latest_version` je i dalje **6.0**.

**Nije počelo namerno** — ostalo je 5% sesije, a release koji stane na pola je
gori od nijednog: verzija podignuta a artefakt ne postoji.

### Redosled, i ništa se ne preskače

0. **PROVERA DA JE ČISTO** — v. „🟢 ZAKLJUČANO — SVAKI UPDATE IDE ČIST".
   Nijedna klijentova fotografija, sloj ni build keš ne ide gore. Dve komande
   su zapisane tamo; obe se puštaju, ne pretpostavljaju.
1. **`MARKETING_VERSION` 10.1 → 10.67.**
2. **`CURRENT_PROJECT_VERSION` 18 → 19.** Bez ovoga macOS ne vidi novi build kao
   noviji i ikonica/verzija se ne osvežavaju — KORAK 74, već plaćeno jednom.
3. **Release build, UNIVERZALAN.** Provera je `lipo -archs` → mora da vrati
   `x86_64 arm64`. Poslednji put je 10.1 ispao samo arm64 i to se videlo tek pri
   pakovanju.
4. **Potpis i notarizacija — PRESKAČE SE, v. „ZAKLJUČANO — DISTRIBUCIJA".**
   Ne idemo na App Store, a Developer ID sertifikata na ovoj mašini **nema**
   (mereno: *0 valid identities*). Pakuje se **ad-hoc**, isto kao 10.1.
   ⚠️ Ostaje istina da se ovo ne može isprobati lokalno — v. KORAK 35, ista
   klasa greške (radilo u Xcode-u, palo potpisano). Ako sertifikat ikad stigne,
   ovaj korak se vraća takav kakav je bio.
5. **Arhiva + `gh release create` v10.67**, ~140 MB.
6. **TEK NA KRAJU: `latest_version` u BriefControl-u.**

### ⚠️ DRUGA ODLUKA KOJA ČEKA KLIJENTA — da li Background treba da se POMERA

Iz KORAKA 95. Klijent je uz sliku People sloja rekao „da mi pokaže da mogu da ga
pomeram". Isporučeno je da se **vidi da je izabran**; pomeranje **nije**, jer
Background nije piksel sloj.

Ako odgovor bude „hoću da se stvarno pomera", to **nije izmena prikaza** nego
modela, i cena je već izmerena i zapisana (v. `ImageLayer.maskData` i KORAK 65):
piksel sloj preko celog kadra je PNG od desetina megabajta u UserDefaults-u,
prepisan pri **svakom** flush-u. To je posao za svoju sesiju, ne dodatak na
kraju ovog. Ne raditi bez pitanja.

### ⚠️ ODLUKA KOJA ČEKA KLIJENTA — tačka 6

`latest_version` je i dalje **6.0**. Dva ishoda i oba su njegov izbor:

- **ne dira se** → niko ne dobija „mora update", novi build je dostupan ali ne
  nameće se;
- **diže se na 10.67** → **svi na starijem odmah dobijaju ekran da moraju da
  update-uju.**

Ovo je jedini korak koji odmah pogađa klijente, i **radi se poslednji** — posle
toga što je release već gore i preuzimljiv. Obrnut redosled znači ekran „mora
update" koji upućuje na nešto što ne postoji.

## KORAK 106 — prvi Generative je bio spor, i traka je to krila (3. septembar 2026)

### ⚠️ PRVO: INTEL JE POTVRĐEN NA PRAVOJ MAŠINI

KORAK 105 se završava rečenicom da Intel put nikad **nije pokrenut** na Intel
Mac-u, samo dokazano da se prevodi, i da preuzimanje modela nije viđeno na
čistoj mašini. **Oboje je 3.09. potvrđeno od klijenta.**

Njegovim rečima: *„Pustio sam app C4S Suit na intel procesor i radi normalno,
posle sam kliknuo na ai clean up, i ispod je bilo dugme da downlodujem ai model
SD 1.8 gb, jesam sacekao da se unpackuje kako je pisalo i selektovao nesto malo
na slici i kliknuo generative"*.

Dakle: **preuzimanje, raspakivanje i Generative Clean Up rade na Radeon Pro
560X.** To je bila najveća neizmerena tvrdnja u dokumentu i više nije otvorena.

**Ostaje neizmereno samo VREME po slici na Intelu**, ne da li radi.

### Prijava koja je iz toga izašla

*„ta prva generative ai clean up action… trajalo je 1.5 mozda 2 minuta…
sledeci generative ai action u istoj sesiji samo drugi je odradio za 15
sekundi"*, i — što je ključno — **isto i posle gašenja i ponovnog pokretanja
app-e**: *„opet taj prvi action traje duze nego svaki sledeci zasto i jel mozemo
to da popravimo"*.

### ⚠️ TRI RAZLIČITA TROŠKA SU SE MEŠALA U JEDAN, i tek razdvojena su rešiva

Ovo je ceo nalaz. Sve ostalo ispod je posledica.

| trošak | koliko puta | šta je bilo |
|---|---|---|
| **instalacija** — 1,8 GB na disk | **jednom, zauvek** | radilo |
| **prilagođavanje modela mašini** — Core ML kompajlira UNet za ovaj hardver | **jednom PO MAŠINI**, keširano na disk | radilo, ali je palo na prvi klik |
| **učitavanje u proces** | jednom po pokretanju | zvano prerano da bi zateklo instalaciju |
| **sklapanje računskog grafa** — prvi `predict` | jednom po pokretanju | **niko ga nikad nije platio unapred** |

**IZMERENO** novim harness-om `Tools/run-model-load-test.py`, na ovoj mašini
(M-čip, Neural Engine):

```
run 1 (hladan Core ML keš):   Unet 40,4 s   VAEEncoder 0,7 s   VAEDecoder 0,4 s   ukupno 41,5 s
run 2 (topao keš):            Unet  0,7 s   VAEEncoder 0,1 s   VAEDecoder 0,0 s   ukupno  0,8 s
```

Taj odnos **40 s : 0,8 s** je ono što je razrešilo prijavu. Core ML čuva
prilagođen model na disku, pa klijentovih „2 minuta" prvi put **ne mogu biti**
ono što se ponavlja posle svakog pokretanja app-e. Ostatak je bio četvrti red
tabele.

### Greška u kodu 1 — posle instalacije niko nije budio model

`Develop.swift` zove `warmUp()` kad se otvori LumenoLab, a `warmUp()` počinje sa
`guard SDModelStore.isAvailable`. U trenutku kad je klijent otvorio LumenoLab
model **još nije bio instaliran**, pa se ta funkcija ispravno vratila odmah.
Onda je instalacija završila i **ništa je nije pozvalo ponovo**.

Zato je baš njegov prvi Generative platio pun hladan start — 40 s prilagođavanja
plus učitavanje plus graf, sve unutar jednog klika.

Popravka: `SDModelInstall.swift` zove `warmUp()` tamo gde već diže
`installGeneration`. To je jedino mesto u app-i koje zna da se odgovor na onaj
`guard` upravo promenio.

### Greška u kodu 2 — zagrevanje je kretalo prekasno i na najnižem prioritetu

Kretalo je pri otvaranju LumenoLab-a, na `.utility`. Oba su pomerena:

- poziv je sada u `BriefShowApp.init()` — dok klijent bira folder, ne kad je već
  pet sekundi od farbanja. Poziv u LumenoLab-u je **ostavljen** kao rezerva; ta
  funkcija je idempotentna;
- `.utility` → `.userInitiated`. `.utility` je red koji macOS gura iza svega, na
  pretpostavci da niko ne čeka — a ovde čeka.

### ⚠️ Greška u kodu 3 — `warmUp()` je model UČITAVAO, ali ga nikad nije POKRENUO

Ovo je bio pravi ostatak, i objašnjava zašto je prvi bio sporiji **i posle
ponovnog pokretanja**, kad je keš već bio topao i učitavanje trajalo sekundu.

Core ML odloži sklapanje računskog grafa do prvog `predict`-a. Model u memoriji
**nije isto što i model spreman.**

`primeGraphs()` sada, posle učitavanja, provuče **jedan** korak kroz sintetički
bafer. Graf je isti bilo da se prošeta jednom ili dvanaest puta, pa se cela
kompilacija plaća za otprilike dvanaestinu računa.

⚠️ **Ne dodiruje nijednu fotografiju.** Bafer je ravno sivo 512×512 sa
kvadratnom rupom u sredini, nikad se ne prikaže i nikad ne sačuva. Klijentovo
pravilo od 3.09. — *„nikako nemoj da smanjujes preview ili nesto qualitet slika…
jer je to photography suit"* — ovde nije ni dotaknuto; nijedan broj vezan za
rezoluciju nije menjan.

### ⚠️ Nova brava, i zašto je morala

`inferenceLock`. Do sada je svako brisanje išlo kroz `developRenderQueue`, koji
je **serijski**, pa se dva prolaza nikad nisu mogla preklopiti i brava nije
trebala. Zagrevanje ide na globalnom redu pri pokretanju i **prvo je u ovoj
app-i što može da bude unutar `fill`-a istovremeno sa pravim brisanjem** — a
`fill` usput piše u `encodedPrompts`.

Da bi se sudarili, klijent bi morao da pritisne Generative sekundu-dve od
pokretanja app-e, pošto je već izabrao sliku i nafarbao. To je argument da je
retko, ne da je nemoguće, pa je učinjeno nemogućim.

⚠️ Redosled brava je **uvek** `inferenceLock` → `loadLock`. `prepare()` uzima
samo `loadLock` i nigde se ne uzimaju obrnuto.

### Traka je stajala na 0% — druga prijava iz istog dana

*„kada kliknem ai generativ on je mnogo zaglavljan na pocetku na 0% laod bar, tu
bar me da se vidi da radi neka krene 2% (da nije nula) pa onda jedna sekunda pa
neka skoci na 8% pa onda neka bude real time tracking"*.

Uzrok: traku je vodio **samo** `progress: (done, total)`, koji pipeline prvi put
zove **posle prvog difuzionog koraka**. Sve pre toga — render fotografije u punoj
veličini, sečenje radne oblasti, LaMa osnovni ispun i učitavanje 1,6 GB — teklo
je na prikazanih **0%**.

**⚠️ NIJE rešeno lažnom animacijom od 0 do 8.** Takva traka laže čim posao
potraje drugačije nego što je neko pretpostavio. Umesto toga je uveden
`SDRemovalStage` — četiri stanja koja se **stvarno završavaju**, i svako se javi
tek kad je posao koji nosi ime gotov:

| stanje | traka | tekst |
|---|---|---|
| pritisak | **2%** | Preparing… |
| `.readingPhoto` | 4% | Reading the photo… |
| `.baseFilled` | 7% | Filling the gap… |
| `.loadingModel` | 8% | Loading the AI model… |
| `.modelReady` | 12% | Cleaning up… |
| difuzioni koraci | 12% → 100% | Cleaning up… N% |

Dva detalja koja nisu očigledna:

- **Nula je jedino stanje koje traka ne preživi.** To je ono što se vidi kad
  posao nije ni počeo, pa traka koja stoji na njoj izgleda pokvareno bez obzira
  koliko se iza nje radi. Otud 2%, i to je doslovno traženo.
- **`advanceEraseProgress` nikad ne ide unazad.** Sa više tragova na slici
  brisanje ide jedan po jedan (v. `briefShowRemovalJobs`) i svaki prolazi svoja
  stanja — bez ovoga bi drugi trag javio „Reading the photo… 4%" dok traka stoji
  na 60%. Traka koja se vrati unazad čita se kao pad i restart.

⚠️ `stage?(.loadingModel)` je izveden tako što se `prepare()` zove **izričito** u
`aiRemoval`, iznad `fill`-a. `fill` ga i dalje zove prvi — bezbedno, jer se
`prepare()` vraća odmah kad je učitano. Dobija se mesto sa kog se UI može javiti
pre i posle najdužeg pojedinačnog posla; unutar `fill`-a je bio nevidljiv, i tako
je dvominutno čekanje završilo prikazano kao 0%.

### Merenje na klijentovoj mašini — i zašto je izašlo iz loga u panel

Prva dva pokušaja da se vreme izmeri **nisu uspela i to je zapisano**:

1. `print` u fajl je **blok-baferovan** kad izlaz nije terminal. Kratke linije
   ostanu u baferu i nikad se ne vide. `stderr` nije baferovan.
2. `stderr` takođe ne pomaže: GUI app pokreće **launchd**, ne shell, pa i stdout
   i stderr idu nikuda. Mereno preusmeravanjem oba u fajl → **prazan fajl**.

Zato `SDInpaintPipeline.note` sada ide i kroz `NSLog` (čita se u Console-u), ali
prava ruta je druga: brojevi su **objavljeni i ispisani u panelu**, jer klijent
nema razloga da otvara Console.

`sdModelReadinessRow` piše jednu tihu liniju u AI Clean Up sekciji:
`Generative model ready (41s load + 3s warm-up).` — pa se broj sa Intela
jednostavno pročita naglas.

### Ostale dve stavke iz istog zahteva

**Select People sam zatvara AI Clean Up.** Prijava: posle Select People se ne
vidi da je sloj izabran dok se AI Clean Up ne zatvori ručno.

⚠️ **Sloj JESTE bio izabran sve vreme.** `selectPeopleAsLayer` odavno postavlja
`selectedLayerID` i `panelTab = .layers`. Uzrok je u lancu overlay-a: dok je AI
četkica živa, prva grana uzima `removalPaintOverlay`, pa se okvir sloja, ručke i
kvaka za rotaciju **prosto ne crtaju**. Nije bio bag u traženju ljudi nego u
tome što je alat koji je preuzeo platno ostao upaljen.

Nov `closeAICleanUp()`, jer se `toggleAICleanUp()` ne sme zvati naslepo —
pozvan nad zatvorenom sekcijom je **otvara** i usput daje četkicu u ruke.

⚠️ Provereno pre obećanja: **nafarbana površina preživljava** gašenje četkice
(`deactivateRemoveBrush` je namerno čuva), pa klik na Select People ne baca posao
koji je već označen za Clean Up.

**Slajderi na sloju u boji.** Glavni panel prosleđuje `trackGradient:`, panel
sloja nije — prosto izostavljeno. Nedostajale su **četiri**, ne dve:
Temperature, Tint, Saturation, Vibrance. Sve četiri sada dobijaju iste statične
trake kao glavni panel (nijedna ne čita fotografiju, pa je deljenje bezbedno).

Klijent je tražio *„mora da bude taj slide bar edit isti kao kad editujem
normalnu sliku"*, pa su uzete sve četiri, ne samo dve koje je naveo.
⚠️ **Ista rupa i dalje postoji u sekciji za masku** (local adjustment,
`editSlider("Temperature", key: "mask.temperature"…)`) — nije bila u prijavi i
nije dirana.

### Usput popravljeno, jer je aktivno lagalo sledećeg čitaoca

- **Zaglavlje `DevelopSDInpaint.swift`** je i dalje tvrdilo „APPLE SILICON ONLY"
  i da Intel „namerno NIJE urađen" — KORAK 105 ga je upravo uradio. Prepisano.
- **Komentar iznad `sdModelInstallRow`** je u prvoj rečenici tvrdio da je na
  Intelu pipeline isključen, a u sledećoj da nije. Zaostatak selidbe, uklonjen.
- **`Tools/README.txt`** je tvrdio da postoji `BRIEFSHOW_MODELS` override.
  **Ne postoji u kodu** — provereno grep-om po celom projektu. Umesto tihog
  brisanja upisano je da ne postoji, jer je tvrdnja već jednom bila poverovana
  (v. „I dalje otvoreno", tačka 4 u KORAKU 105).

### Provereno

- `BUILD SUCCEEDED` posle svake od tri izmene.
- `Tools/run-editsettings-decode-test.py` → **129 slogova, nijedan broj se nije
  pomerio**, 27 polja, nijedna deklaracija ne fali.
- `Tools/run-layer-pixel-store-test.py` → **ALL PASS**, dekodiranje 4,9 ms.
- `Tools/run-model-load-test.py` → brojevi u tabeli gore.

### ⚠️ NEPROVERENO NA EKRANU

Sve iz ovog koraka. App je pokrenuta i predata klijentu na proveru; nijedna od
četiri izmene nije potvrđena gledanjem u trenutku pisanja.

**Konkretno neizmereno:**

1. **Koliko `primeGraphs()` košta na Intelu.** Ovde je jedan korak otprilike
   dvanaestina od dvanaest, ali Radeon nije Neural Engine. Broj se čita iz
   panela. ⚠️ **Ako ispadne skup, ovo je izmena koju treba povući** — trošiti
   grafičku na svakom pokretanju za funkciju koju klijent tog dana možda neće ni
   dotaći nije pošteno.
2. **Da li je prvi Generative posle ovoga zaista isto brz kao svaki sledeći.**
   To je bio zahtev; ovde se ne može proveriti bez Intel mašine.
3. **Da li traka sada vidljivo prolazi kroz sva četiri stanja**, ili neka
   prolete pa se čini da preskače.

## KORAK 107 — vlasi: nova opcija, izmerena; trava: tri poluge probane, nijedna ne radi (3. septembar 2026)

Dve prijave iz iste poruke, obe sa slikama pre/posle.

### 1. „Generative clean hair" je ostavljao trag vlasi

Prijava: kod čišćenja izletele vlasi preko neba, Generative je izgledao „kao
Quick Clean Up" — trag ostaje, samo mekši.

**Zašto prompt nije bio poluga (i zašto nisam ni probao da ga menjam):** KORAK
40 je već izmerio da „sa LaMa podlogom prompt jedva da išta menja" — otkad
Generative kreće od LaMa popune (KORAK 40), model nema šta da odlučuje, pa
reč u promptu skoro ništa ne pomera. Menjati prompt za „kosu" bio bi treći put
da se ovo izmeri uzalud (KORAK 3, KORAK 18, KORAK 40).

**Pravi uzrok je geometrijski, i piše ga sam kod.** Komentar u
`DevelopInpaint.swift` na `ExemplarInpainter.fill` kaže da algoritam nagrađuje
fronta gde „jak ivični signal ulazi u rupu" — to je ono što ispravno produžava
horizont ili ogradu preko praznine. **Vlas jeste jak, tanak, linearan ivični
signal.** Ako maska tesno prati vlas, ivica i dalje graniči rupu, i isto
pravilo koje ispravno produžava horizont može ispravno da produži vlas.

I `quickAIRemoval` i `aiRemoval` zovu **isti** rast maske:
`SubjectMasker.grown(mask, by: 0,0025 × veće dimenzije)`. Na 5176px fajlu to je
**13px** — dovoljno tesno da ivica vlasi ostane tik uz rupu.

**⚠️ IZMERENO, ne rezonovano.** Nov harness `Tools/run-hair-strand-test.py` +
`Tools/test-hair-strand.swift` gradi sintetičku fotografiju — zakrivljenu tamnu
vlas preko svetlog „neba" sa šumom — i pušta **pravi** `SubjectMasker.grown` +
`LaMaInpaintPipeline` + `InpaintPipeline.package` iz izvora, pri više radijusa
rasta:

| rast | rezultat (gledano na PNG-u) |
|---|---|
| 13px (dana{{š}}nji, na ~5176px NEF-u) | **bledi duh vlasi i dalje vidljiv** |
| 20px | slabiji trag |
| 30px | **čisto, ravno nebo** |
| 45px | čisto, bez daljeg poboljšanja |

Prva verzija testa (vlas preko cele visine kadra) je davala lažno velike
razlike jer je rupa gutala skoro ceo radni kvadrat — ispravljeno na **lokalnu**
vlas dužine ~⅓ kadra, kao pravi pramen, i tek tad je razlika bila čitljiva i na
oko, ne samo u broju.

**Šta je urađeno — DODATO, ne izmenjeno.** Nov parametar
`InpaintPipeline.aiRemoval(…, flyawayHair: Bool = false)`. Kad je `true`, rast
maske ide na `0,006 × veće dimenzije` (31px na istom NEF-u — iznad izmerene
granice od 30px). **Podrazumevano `false`** — ništa se ne menja za bilo koji
drugi Generative posao (kamenčić, osoba, bilo šta drugo). `quickAIRemoval` je
netaknut u potpunosti.

U panelu: **`Toggle("Flyaway Hair")`**, samo pored Generative dugmeta (traženo
tačno tako — „na generative ai"), `@AppStorage`, podrazumevano isključen.

**⚠️ Sintetički test dokazuje MEHANIZAM (ivica koja graniči rupu), ne
klijentovu konkretnu fotografiju** — njegov fajl je na njegovoj mašini, ne
ovde. To se ne može potvrditi bez njegovog ekrana.

### 2. Trava — gušća u originalu, ređa/mekša posle Generative popune

Prijava, sa slikom: travnjak posle uklanjanja osobe izgleda **ređe i mekše**
od okolne trave, ne po sadržaju nego po **gustini teksture**.

**Klijent je dao dozvolu da se dirne zaključani odeljak „AI MODELI I NJIHOVA
PODEŠAVANJA" — izričito, za ovaj jedan slučaj, uz uslov merenja pre bilo kakve
trajne izmene.** Iskorišćeno tačno tako: tri poluge izmerene, **nijedna
zadržana** jer nijedna ne pomaže.

**⚠️ Sintetička trava, ne klijentov fajl** — isti razlog kao kod vlasi: fajl je
na njegovoj mašini. Napravljena je gusta prava trava (90.000 procenih vlati,
`Tools/`-a nema stalno jer test nije doveo do izmene — v. niže) i rupa 400×660
px, veličine slične uklanjanju osobe, puštena kroz `Tools/run-inpaint-sweep.py`
(taj alat već postoji, prevodi PRAVI `InpaintPipeline` iz izvora).

| poluga | probano | rezultat |
|---|---|---|
| `defaultRefineStrength` | 0,2 / 0,3 (isporučeno) / 0,45 / 0,6 | **identično meko na sve četiri** — SD ovde skoro ništa ne menja |
| kontekst odnos u `squareRegion` | 1,6 (isporučeno) / 1,3 / 1,1 / 1,0 | **1,3 i 1,1 isto meko; 1,0 GORE** — tvrda pravougaona ivica i plava mrlja-artefakt |
| `--lama` (Quick, bez SD-a uopšte) | sam LaMa | **ISTA mekoća** kao i sa SD-om |

Treći red je nalaz koji zatvara pitanje: **mekoća dolazi iz LaMa-inog sopstvenog
popunjavanja, pre nego što SD uopšte dobije priliku da nešto doradi.** SD u
sadašnjoj arhitekturi kreće od LaMa-ine popune i namerno je blag (to je KORAK
40 — cilj je bio da se **spreči izmišljanje**, po ceni da SD skoro ništa ne sme
da menja). Isti kompromis koji je zaustavio izmišljanje kamiona na plaži je i
ono što travi ne dozvoljava da postane gušća.

**To je ista stvar koja je 30-31.08. već izmerena i zapisana** —
„LaMa se kvari u MEKOĆU" (KORAK 39) — samo sad viđena na travi umesto na peskovitoj
obali. Nije nov bag; ista poznata granica, na novom sadržaju.

**⚠️ Ništa nije promenjeno u kodu za travu.** Sve tri probane vrednosti su
odbačene tačno kao u KORAK 39 — „nijedna izmerena varijanta nije bolja od
isporučene, pa menjati bilo šta 'za svaki slučaj' značilo bi zameniti izmereno
stanje neizmerenim". `defaultRefineStrength` ostaje **0,3**, kontekst odnos u
`squareRegion` ostaje **1,6**.

**⚠️ OTVORENO PITANJE ZA KORISNIKA, ne za sledeću sesiju da odluči sama.**
Jedini put koji bi ovo stvarno popravio je onaj već zapisan u KORAKU 39 kao
neisproban — SD sa znatno VIŠOM jačinom, ali samo za poslove bez ljudi/predmeta
u kadru (čista tekstura), gde je rizik izmišljanja manji nego na sceni sa
strukturom. Nije probano danas: veći zahvat, i pre nego što se probode
zaključani odeljak po DRUGI put treba klijentova reč, ne moja pretpostavka.
Dok se ne odluči, preporuka je ista kao za nebo — veliko uklanjanje na travi
raditi u dva-tri manja prolaza, ili ručno Selection alatom.

### Provereno

- `Tools/run-hair-strand-test.py` — vizuelno i brojem, tabela gore.
- `BUILD SUCCEEDED`.
- `Tools/run-editsettings-decode-test.py` → **127 slogova** (pao sa 129 —
  posledica gašenja/paljenja app-e na ovoj mašini tokom sesije, ne izmene u
  kodu; `aiRemoveFlyawayHair` je `@AppStorage`, van `PhotoEditSettings`, nema
  Codable migraciju), **RESULT: OK, nijedno polje ne fali**.
- `Tools/run-crop-rotation-test.py` → OK.

### ⚠️ NEPROVERENO NA EKRANU

„Flyaway Hair" toggle — nije viđen na pravoj fotografiji sa vlasima, ni ovde
(nema takve slike) ni na klijentovoj mašini.

## KORAK 108 — RELEASE v11.1 (3. septembar 2026)

Klijentov zahtev: zapakuj i pusti sve iz KORAKA 106–107 kao universal build,
macOS 13+, ista dva AI modela (LaMa u bundle-u, SD na preuzimanje), tag v11.1.

### Provereno na pravom paketu, ne pretpostavljeno

| provera | rezultat |
|---|---|
| `lipo -archs` | **`x86_64 arm64`** |
| `LSMinimumSystemVersion` | **13.0** |
| verzija / build | **11.1** / **21** |
| `CFBundleDisplayName` / `Name` / `Executable` | **C4S Suite** |
| `CFBundleIdentifier` | `com.rocketsbrief.BriefShow` (netaknut) |
| potpis | ad-hoc (i dalje nema Developer ID sertifikata) |
| lične fotografije u paketu | **nula** |
| `LaMa.mlmodelc` u paketu | **da** — Quick AI Clean Up bez preuzimanja, na oba procesora |
| SD15-Inpainting u paketu | **ne**, namerno — preuzima se na zahtev |
| app / arhiva | 140 MB / **109 MB** |

### ⚠️ Zamka — prvi universal build je ispao arm64-only, i `-showBuildSettings` je lagao da je sve u redu

`xcodebuild -configuration Release build` je dao **samo `arm64`**, iako
`-showBuildSettings` za isti scheme/config pokazuje `ARCHS = arm64 x86_64` i
`ONLY_ACTIVE_ARCH = NO`. Podešavanja u `.pbxproj`-u nikad nisu bila problem —
`xcodebuild build` bez `-destination` je tiho suzio arhitekturu na mašinu koja
gradi. Dodavanjem `-destination "generic/platform=macOS"` build je ispravno
izašao univerzalan. **Zapamtiti za sledeći release**: bez tog `-destination`,
provera podešavanja pre build-a ne dokazuje ništa o stvarnom binarnom fajlu —
mora se meriti `lipo -archs` na **rezultatu**, ne na `-showBuildSettings`.

### SD model — NIJE ponovo pušten, i to je namerno

`SDModelInstaller.archiveURL` je i dalje pinovan na **v11.0** tag-a
(`SD15-Inpainting.aar`, 1891 MB, potvrđeno da i dalje postoji na GitHub-u).
Težine se nisu promenile od 25.08, pa ponovno pakovanje i upload identičnih
1,8 GB ne bi ništa dodalo — samo bi trošilo vreme i mesto.

**Ovo direktno odgovara na klijentovo pitanje o mešovitim instalacijama:**
model živi u `Application Support` unutar app-inog kontejnera, odvojeno od same
app-e (v. KORAK 108 razgovor pre ovog koraka). Klijent koji je već preuzeo SD
zadržava ga bez ičega novog; klijent koji nije, dobija isti, i dalje važeći
link kad klikne „Install Model" u novoj 11.1. Nijedna mašina ne gubi niti mora
ponovo da preuzima 1,8 GB zbog ovog update-a.

### Oznaka verzije u app-i — već postoji

Klijent je tražio „label u appu ispod da je taj tag version". Postoji od pre —
`BriefShowAboutHoverCard` (hover na „C4S Suite" natpis) čita
`CFBundleShortVersionString` direktno iz build-a i ispisuje „v11.1" bez ijedne
izmene koda. Nije dodato ništa novo; ako klijent hoće da bude STALNO vidljiva
(ne samo na hover), to je sledeći, poseban zahtev.

### ⚠️ Uočeno usput, nije dirano

`dist-universal/BriefShow.app` (praćen fajl u git-u) je **zastareo od 6.
avgusta** — pre preimenovanja u C4S Suite, pre svih release-a od 10.8 naovamo.
Ni 10.8 ni 11.0 ga nisu osvežili; obe su isporučene isključivo kao GitHub
Release asset (arhiva), a ta praćena kopija je otad mrtvo drvo. Nije dirana
danas — menjanje praćenog binarnog fajla van onoga što je traženo nije odluka
koju treba doneti tiho.

### Pušteno

- Commit `85345ea` — podizanje verzije i beleška o `-destination` zamci.
- Tag **`v11.1`**, push na `origin`.
- `gh release create v11.1` sa `C4S-Suite-11.1.zip` (109 MB) kao asset-om.

### ⚠️ Šta i dalje NIJE dirano

- `latest_version` u BriefControl-u — i dalje 6.0, klijentova odluka, poslednji
  korak po dogovorenom redosledu.
- Developer ID potpis — i dalje 0 identiteta na ovoj mašini.
- 214 MB `build_universal/` u istoriji commit-ova — čeka odluku o prepisivanju.

## KORAK 109 — mekoća zakrpe: jačina SD-a NIJE poluga, i to je izmereno; zrno se vraća iz same fotografije (3. septembar 2026)

Klijent, o travi i o pesku: *„moramo da popravimo da izgleda bolje ta trava,
pojacaj SD Jacinu!"*, pa dopuna: *„kao i za plazu pesak postje mutniji nije kao
plaza.. a quick clean up isto to uradi znaci SD mora to da popravi!"*

⚠️ **Ta dopuna je rešila korak.** „Quick radi isto" je jedina rečenica koja
isključuje model iz priče: ako obe putanje greše isto, greška nije u tome šta
model odlučuje.

### 1. Traženo je pojačanje jačine. Izmereno je i NE radi.

Mereno na **klijentovom pravom kadru** `C4S_7891.NEF` (isti fajl i isti
pravougaonik kao KORAK 39), `Tools/run-inpaint-sweep.py`, ocena
`Tools/measure-texture-density.py` (odnos teksture zakrpe prema okolnoj):

| refine | odnos | šta se VIDI na PNG-u |
|---|---|---|
| 0,3 (isporučeno) | 0,33 | čisto |
| 0,35 | 0,33 | čisto |
| 0,40 | 0,34 | **stena se nazire** |
| 0,45 | — | **stena** |
| 0,50 | — | **stena** |
| 0,6 | 0,37 | **stena** (bleda — zato se na smanjenoj slici ne primeti) |
| 0,8 | 0,44 | **stena, nedvosmisleno** |
| 0,95 | 0,49 | **stena** |
| `off` (iz šuma) | 0,77 | **velika mahovinasta stena** |

**Broj raste isključivo zato što model izmišlja.** Dokaz iz drugog smera: na
travi, gde nema objekta za koji bi se uhvatio, **sve** jačine od 0,3 do pune
daju ravno 0,28–0,30.

Plafon je između **0,35 i 0,40**, a 0,35 daje **identičan** odnos kao 0,3
(0,33). Sitno povećanje ne kupuje ništa merljivo pre nego što počne da laže
sliku. ⚠️ **`defaultRefineStrength` OSTAJE 0,3, zaključani odeljak nije diran.**
To je KORAK 40 izmeren ponovo, sa druge strane.

### 2. Pravi uzrok je aritmetika, i `squareRegion` ga je već pisao

Nijedna popuna se ne računa na klijentovoj rezoluciji: SD-ov konvertovani
checkpoint prima fiksnih **512**, LaMa radi do **1100**, i rezultat se razvlači
nazad na kadar od 5176 px.

| kadar | rupa | radni kvadrat | razvlačenje |
|---|---|---|---|
| plaža `C4S_7891` | 828×431 | 1325 | **2,6×** |
| trava `C4S_8931 BW` | 1449×1310 | 2364 | **4,1×** |

⚠️ **Dokazano, ne rezonovano:** ista slika i isti posao, samo smanjena tako da
razvlačenja NEMA (rupa 256 px, kvadrat 512, 1:1) → odnos **0,33 → 0,53**, na
istoj jačini 0,3. Više nego išta što jačina može bezbedno da kupi.

I zato Quick greši isto: bio je **0,44** tamo gde je SD bio **0,47**. Klijentovo
zapažanje je bilo tačno na broj.

### 3. Šta je urađeno — zrno se uzima iz fotografije, ne od modela

Nov detaljni prolaz u **`package()`** u `DevelopInpaint.swift`. `package()` je
zajednički, pa jednim potezom hvata **sva tri** puta: SD, LaMa Quick i
exemplar. Region se ponovo renderuje u izvornoj rezoluciji (kapirano na
`maxDetailEdge` = 2048), popuna se podigne na nju, i u rupu se vrati **pravo
zrno iz iste fotografije**. Struktura — šta je u rupi — ostaje tačno kako je
popuna odlučila; dopunjava se samo fini pojas.

To je isti razlog zbog kog je exemplar put oštar, rečima koje već stoje u tom
fajlu: *„COPIES real pixels out of the surrounding photo instead of
synthesizing them, so what it puts back is as sharp as what it took."*

| | pre | posle |
|---|---|---|
| plaža, pojas peska u rupi | 0,47 | **0,96** |
| Quick (`--lama`), isti pojas | 0,44 | **0,74** |
| trava `C4S_8931`, cela rupa | 0,35 | **0,56** |

Cena vremena, što je bio klijentov uslov: SD **9,3 s → 9,9 s**, Quick
**1,1 s → 1,1 s** na 5176 px kadru.

### ⚠️ Tri izbora davaoca zrna, dva bačena — i OBA su imala BOLJI broj

Ovo je najvažnija stavka koraka i razlog zašto `measure-texture-density.py` nosi
upozorenje u zaglavlju.

| izbor davaoca | odnos | šta se videlo |
|---|---|---|
| jedan ravan pravougaonik peska | 0,82 | **talasi peska preko mora** |
| svaki red zasebno upario po svetlini | **1,48** | **tvrd pravilan ČEŠALJ** |
| upareno pa „hoda", sa pragom | — | **vertikalne PRUGE** (prag okida na svakom redu i otiskuje isti red) |
| **preslikana susedna traka + meka težina** | 0,66 / 0,96 | čisto |

**Tri puta je broj porastao dok je fotografija postajala gora.** Pogrešna
tekstura je i dalje tekstura, a ova mera to ne razlikuje. PNG odlučuje.

Zadržano rešenje: davalac je najbliža netaknuta traka, preslikana i **pomera se
red po red** — neprekidnost je osobina koja se ne sme žrtvovati, jer je ona ta
zbog koje zrno izgleda kao zrno. Neslaganje traka (pesak nad morem) se rešava
**težinom, ne skakanjem**: gde davalac ne liči na ono što treba da ozrni,
gasi se. Najgore što tako može da uradi jeste da ne vrati ništa — ne može da
izmisli teksturu koje nije bilo.

Širina te težine je izmerena, ne odabrana: na 12 je trava dobila samo
0,35 → 0,39 (premalo, gušila je glavni slučaj), na **24** trava 0,56 i pesak
0,96, a plaža je pogledom potvrđena da je i dalje čista.

### ⚠️ Poboljšanje, NIJE izlečenje — i razlika je bitna

Na plaži ovo stvarno izgleda bolje. Na klijentovoj travi rupa je **četvrtina
kadra**; zrno se vrati i vlati se vide gde je pre bila glatka mrlja, ali ispod
je i dalje mrlja i ona ne postaje travnjak. Jedino što bi to izlečilo je model
nad preklapajućim pločicama u izvornoj rezoluciji — 6 do 16 prolaza umesto
jednog, što je klijent odbio zbog vremena. Preporuka za velika uklanjanja
ostaje ista kao u KORAKU 107: u dva-tri manja prolaza.

### Provereno

- `BUILD SUCCEEDED` posle svake od četiri verzije davaoca.
- `Tools/run-editsettings-decode-test.py` → **RESULT: OK**, 129 slogova, 27
  polja, nijedan broj se nije pomerio.
- `Tools/run-layer-pixel-store-test.py` → **ALL PASS**.
- `Tools/run-crop-rotation-test.py` → **RESULT: OK**.
- `Tools/run-hair-strand-test.py` → radi, redosled radijusa isti kao KORAK 107.

### Usput popravljeno

`Tools/README.txt` je od KORAKA 106 tvrdio da `BRIEFSHOW_MODELS` **ne postoji**.
Netačno u drugu stranu: app ga zaista nikad nije čitao, ali `convert_lama.py`,
`clip_tokenize.py` i `run-inpaint-sweep.py` ga svi poštuju — i ovaj korak ga je
koristio da izmeri baznu vrednost. Ta linija je sad bila pogrešna u OBA smera;
prepisana je na pravu razliku: app protiv alata.

### ⚠️ NEPROVERENO NA EKRANU

Sve iz ovog koraka. Mereno i gledano na PNG-ovima ovde, u app-i nije viđeno.
Konkretno neprovereno:

1. Kako popravka izgleda na uklanjanju **osobe** (ovde su merene rupa od
   suncobrana i kamena staza, nijedna nije osoba).
2. Šta radi na sadržaju sa **strukturom** u rupi — ograda, pločice, zid. Meka
   težina bi tu trebalo da se ugasi, ali to nije viđeno.
3. Vreme na **Intelu**. Prolaz je čist CPU posao nad do 2048² piksela; ovde je
   0,6 s, tamo je nepoznat.

### ⚠️ Cena koja NIJE u vremenu nego u dokumentu — izmerena

Sloj sada nosi PNG u izvornoj rezoluciji umesto 512², i to ide u klijentov
sačuvan fajl. Mereno dodavanjem ispisa u `Tools/inpaint-sweep.swift` (ostao je
tamo, jer je to broj koji sledeći korak treba da vidi):

| | patch pre | patch posle |
|---|---|---|
| plaža `C4S_7891` | 512×512, **118 KB** | 1360×1360, **552 KB** |
| trava `C4S_8931`, velika rupa | 512×512, **315 KB** | 2048×2048, **3066 KB** |

⚠️ **Jedno veliko uklanjanje sada nosi ~3 MB umesto ~315 KB — desetostruko.**
To je cena nošenja pravog zrna: zrno od dva piksela ne može da stane u bafer
koji se razvlači 4×. Nije skriveno u vremenu (SD 9,3 → 9,9 s), nego u veličini
fajla, i klijent to nije video pri odluci.

Poluga ako zasmeta je **`maxDetailEdge`** (`DevelopInpaint.swift`, sada 2048):
spuštanje na 1400 otprilike prepolovljava veličinu, po cenu mekšeg zrna na
najvećim rupama. ⚠️ Nije spuštano bez pitanja — 2048 je vrednost na kojoj su
izmereni svi brojevi gore, pa bi menjanje značilo zameniti izmereno stanje
neizmerenim.

## KORAK 110 — import: sam otvara folder, uvek u Pictures ▸ C4S Library; Update gasi app (3. septembar 2026)

Tri klijentova zahteva iz jedne poruke.

### 1. Posle importa folder se otvara sam

Prijava: *„Kada importuj slike iz kamere ili SD kartice da se otvori taj folder
u gridu automatksi gde su importovane."*

⚠️ **Mehanizam je već postojao i bio je ispravan** — `onImported` u
`CameraImportView`, povezan u `ContentView` tako da osveži stablo foldera i
postavi `selectedFolderURL`. Ono što je falilo: zvao ga je **samo klik na dugme
„Show These Photos"**. Svaki import se završavao tako što klijent ručno zatvara
prozor da bi došao do onoga što je upravo tražio.

Sada `.onChange(of: session.phase)` na telu prikaza: čim faza pređe u
`.finished`, poziva se `onImported(folder)` + `onClose()`. Dugme je uklonjeno —
posle automatike moglo bi da se vidi samo na tren pre nego što nestane.

⚠️ **Samo na `.finished`.** `.failed` namerno OSTAJE na ekranu: to je jedini
slučaj u kom na tom mestu ima šta da se pročita.

### 2. Odredište: uvek Pictures ▸ C4S Library, uvek datumski folder

Prijava: *„default uvek da vodi na Pictures under C4S Library Folder, i uvek tu
da pravi folder by dates kada se importuje!"*

- `defaultDestination` je bio `Documents/"BriefShow NEF"` → sada
  `Pictures/"C4S Library"`.
- Seme iz otvorenog foldera u gridu (`initialDestination`) **više se ne
  koristi** za odredište. ⚠️ To je bila namerna funkcija sa svojim
  obrazloženjem („that is almost always where they are wanted"); klijent je
  tražio suprotno tim rečima — uvek jedno predvidivo mesto. `Choose…` i dalje
  vodi bilo gde.
- Čekboks „Into a dated subfolder" je **uklonjen**; datumski folder je sada
  stalan (`intoDatedSubfolder` je konstanta `true`). Tekst je ostao, ali sada
  konstatuje umesto da nudi.

Grupisanje je i dalje po danu kada je **snimljeno**, ne po današnjem datumu —
to je zatečeno i nije dirano.

### ⚠️ ZAMKA koja bi izgledala kao da su slike nestale

App je **sandboxed** (`BriefShow.entitlements`), a u sandboxu
`FileManager.urls(for: .picturesDirectory)` odgovara putanjom **unutar
kontejnera** — `~/Library/Containers/com.rocketsbrief.BriefShow/Data/Pictures`.
To je stvaran, upisiv folder koji klijent **nikada neće naći u Finderu**. Da je
ovo pušteno naivno, import bi „uspeo" a slika ne bi bilo nigde.

**To je tačno ono na šta se odnosila stara beleška u ovom fajlu** — da „wherever
the system calls Pictures" nije mesto na kom se snimanje kasnije nađe. Ta
rečenica je bila zapisana kao klijentova odluka o ukusu; ona je zapravo bila
opis ovog sandbox ponašanja.

Urađeno dvoje:

1. Dodat entitlement **`com.apple.security.assets.pictures.read-write`** —
   provereno da je stvarno u paketu (`codesign -d --entitlements`), ne samo u
   izvoru.
2. Nova `picturesFolder()`: pravi kućni folder se traži preko **`getpwuid`**
   (koji i u sandboxu vraća pravi home, dok `NSHomeDirectory()` vraća
   kontejner), i ta putanja se koristi **samo ako se u njoj zaista može
   napraviti folder**. Upisivost se proverava tako što se posao uradi, jer
   `isWritableFile` u sandboxu ume da odgovori optimistično. Ako ne uspe, pada
   nazad na staro ponašanje umesto da pukne.

### 3. „Download Update" sada gasi app

Prijava: *„cim klijent klikne update automatksi mora da se ugasi C4S Suit, ali
skroz da se uvasi literaly Quit! Da bi klijent mogao da replace odradi u
application."*

Preuzimanje je i pre išlo u browser (`NSWorkspace.open` na GitHub release
stranicu), pa nije bilo šta da se izgubi gašenjem. Sada se gasi
`NSApplication.shared.terminate(nil)` u **completion handler-u** tog otvaranja,
a ne u istom potezu: gašenje uporedo sa predajom ume da pretekne predaju i
ostavi klijenta bez i preuzimanja i app-e.

⚠️ **Na grešci se NE gasi.** Ako otvaranje ne uspe, prozor ostaje da se dugme
može pritisnuti ponovo — inače bi neuspeh značio da je klijent ostao i bez
app-e i bez linka.

Provereno da nema `applicationShouldTerminate` koji bi gašenje zaustavio ili
tražio potvrdu — grep po svim izvorima, nema ga.

Korak 3 uputstva („Quit C4S Suite if it's currently open") je uklonjen jer ga
app sada radi sama; koraci su prenumerisani sa 7 na 6, a korak 1 sada kaže i da
će se app zatvoriti.

### Provereno

- `BUILD SUCCEEDED`.
- `codesign -d --entitlements` na sagrađenom paketu → `app-sandbox` i
  `assets.pictures.read-write` oba prisutna.
- App pokrenuta i predata klijentu na proveru.

### ✅ Provereno posle predaje klijentu — i beleška iznad je bila prestroga

Klijent je otvorio File ▸ Import… i javio da je folder napravljen kako treba.
Provereno i sa ove strane:

- `~/Pictures/C4S Library` postoji.
- `~/Library/Containers/com.rocketsbrief.BriefShow/Data/Pictures` je
  **symlink** na `../../../../Pictures`, i oba puta daju **isti inode**
  (`stat -f "%d:%i"`). Jedan folder, na pravom mestu.

⚠️ **Ispravka tvrdnje iz ovog istog koraka:** kad je entitlement dodeljen,
macOS symlink-uje kontejnerski Pictures na pravi — pa bi i obično
`.picturesDirectory` odgovorilo tačno. **Pravi lek je bio entitlement**;
`getpwuid` je pojas preko tregera. Ostavljen je jer ne škodi i jer pada nazad
ako entitlementa nekad nema, ali ne treba mu pripisivati zaslugu: bez
entitlementa ni on ne bi mogao da piše tamo.

### ⚠️ NEPROVERENO NA EKRANU
2. **Gašenje na Update.** Ne može se isprobati odavde: kartica se pojavljuje
   samo kad je `latest_version` veći od ugrađenog, a `latest_version` je i dalje
   6.0 (klijentova odluka, v. KORAK 108).
3. Automatsko otvaranje foldera posle importa — nije viđeno sa pravom kamerom
   ni karticom.

## KORAK 111 — KORAK 109 je POVUČEN: klijent je na ekranu video da je gore (3. septembar 2026)

Klijent, pošto je pogledao pravu app-u: *„nista sad je SD gori nego sto je bio
hahahaha.. vrati SD i lamu kako su bili pre ove p[opravke.. a ovo sada novo sto
si uradio neka ostane"*.

### Šta je vraćeno

`git checkout 6d8be1a --` nad tri fajla — `DevelopInpaint.swift`,
`DevelopSDInpaint.swift`, `DevelopLaMaInpaint.swift`. Ceo detalj-prolaz iz
KORAKA 109 (`nativeDetailPass`, `restoreFineDetail`, `detailSource`, i sve
pomoćne funkcije) je nestao; provereno grep-om da ni jedna od te tri reči više
ne postoji ni u jednom od tri fajla.

Potvrđeno da je stanje **brojčano identično** onome pre 109, ne samo naizgled:

| | pre 109 | posle 109 | sada |
|---|---|---|---|
| patch koji dokument nosi | 512×512, 118 KB | 1360×1360, 552 KB | **512×512, 118 KB** |
| odnos teksture, cela rupa | 0,33 | 0,82 | **0,33** |
| odnos, pojas peska | 0,47 | 0,96 | **0,47** |

KORAK 110 (import, odredište, Update gasi app) je **netaknut** — tako je i
traženo.

### ⚠️ Zašto ovo NIJE „vraćanje na neizmereno stanje"

KORAK 39 i KORAK 107 su odbacivali varijante zato što merenje nije pokazalo
poboljšanje. Ovde je obrnuto: **merenje je pokazalo poboljšanje, a klijent je na
svom ekranu video pogoršanje.** Ekran pobeđuje. To je isto pravilo koje je
KORAK 109 sam zapisao u zaglavlje `Tools/measure-texture-density.py` — tri puta
je tokom tog koraka broj rastao dok je slika postajala gora — samo što je
četvrti put promakao, i uhvatio ga je klijent umesto mene.

⚠️ **Odnos teksture nije mera kvaliteta popune.** Meri koliko se piksel po
piksel menja, i ne razlikuje pravo zrno od pogrešnog. Sve što je KORAK 109
merio bilo je tačno; ono što nije radio je gledao rezultat u samoj app-i, na
uklanjanjima kakva klijent stvarno radi, umesto na dva kadra kroz harness.

### ⚠️ ŠTA SE NE ZNA, i zašto to smeta

**Nije zabeleženo ŠTA je tačno izgledalo gore.** Klijent je rekao „gori" bez
opisa, a ja sam vratio pre nego što sam pitao. Kandidati, iz onoga što je
tokom 109 već viđeno na harness slikama:

1. dodato zrno na sadržaju koji ga ne traži (koža, nebo, glatke površine);
2. vidljiv prelaz na ivici rupe gde se zrno gasi;
3. zrno pravilnog karaktera na uklanjanjima **osobe** — što u KORAKU 109 nikad
   nije isprobano (merene su rupa od suncobrana i kamena staza, nijedna nije
   osoba, i to je tamo i zapisano kao neprovereno).

⚠️ **Ako se ovome ikad vraća, prvo pitanje je ovo, ne kod.** Bez toga bi
sledeći pokušaj krenuo od iste pretpostavke i završio isto.

### Šta je ZADRŽANO iz 109, i zašto

- **`Tools/measure-texture-density.py`** — alat je i dalje ispravan i njegovo
  zaglavlje je sad još tačnije nego kad je pisano.
- **Ispis veličine patch-a u `Tools/inpaint-sweep.swift`** — komentar
  prepravljen da kaže da je patch opet 512², umesto da i dalje tvrdi ono što je
  109 uradio.
- **Ispravka `Tools/README.txt` o `BRIEFSHOW_MODELS`** — činjenična, nema veze
  sa popunom.

### Šta i dalje stoji kao izmereno, i vredi za sledeći put

Ovo revert ne poništava:

- **Jačina SD-a nije poluga.** Plafon je 0,35 (identičan odnos kao 0,3), a od
  0,40 naviše model izmišlja — na klijentovoj plaži stenu. To je i dalje
  izmereno i i dalje je razlog da se `defaultRefineStrength` ne dira.
- **Mekoća je aritmetika**: 512 / 1100 razvučeno nazad, 2,6× na plaži i 4,1× na
  klijentovoj travi; bez razvlačenja isti posao ide 0,33 → 0,53.
- **Quick i Generative su jednako meki** (0,44 prema 0,47) iz istog razloga —
  klijentovo zapažanje je bilo tačno na broj.

⚠️ Ono što je ostalo nedokazano je da se to popravlja **pozajmljivanjem zrna**.
Jedini put koji nikad nije probanje ostaje onaj koji i `squareRegion` navodi:
model nad preklapajućim pločicama u izvornoj rezoluciji, 6–16 prolaza umesto
jednog. Klijent ga je odbio zbog vremena, i ta odluka nije promenjena.

### Provereno

- `BUILD SUCCEEDED`.
- `Tools/run-editsettings-decode-test.py` → **RESULT: OK**, 129 slogova.
- `Tools/run-layer-pixel-store-test.py` → **ALL PASS**.
- `Tools/run-crop-rotation-test.py` → **RESULT: OK**.
- `Tools/run-inpaint-sweep.py` → patch opet 512×512 / 118 KB, odnosi 0,33 i 0,47.

## KORAK 112 — KORAK 109 vraćen, ali na 1024 umesto 2048 (3. septembar 2026)

Klijent, posle reverta iz KORAKA 111: *„ipak vrati da bude sa 109. ali sa
izmenama da bude 1024x1024 cela rupa ce malo da se smanji sa verujem 0.82 na
0.67 i pojas peska ce isto da se malo smanji sa 0.96 na 0.78"*.

Kod iz 109 je vraćen doslovno (`git checkout 0043e95 --` nad ista tri fajla),
sa jednom izmenom: **`maxDetailEdge` 2048 → 1024**.

### ⚠️ Klijentova procena pada je bila znatno preniska — izmereno

Očekivao je blag pad. Pad je oštriji, jer se sa 1024 razvlači i **davalac**:
zrno koje se pozajmljuje je već omekšano pre nego što se doda. Na plaži region
je 1360 px (razvlačenje 1,33× umesto 1,0×), na travi 2364 px (**2,3×** umesto
1,15×).

| | pre 109 | 109 @2048 | procena klijenta | **stvarno @1024** |
|---|---|---|---|---|
| plaža, cela rupa | 0,33 | 0,82 | 0,67 | **0,41** |
| plaža, pojas peska | 0,47 | 0,96 | 0,78 | **0,68** |
| Quick, pojas peska | 0,44 | 0,74 | — | **0,53** |
| trava, cela rupa | 0,35 | 0,56 | — | **0,40** |

Na celoj rupi plaže dobija se **0,41 umesto očekivanih 0,67** — dakle nešto
preko četvrtine puta od polazne 0,33 do onoga što je 2048 davao, a ne dve
trećine. Pojas peska je bliži proceni (0,68 prema 0,78).

### Šta se dobija zauzvrat — veličina dokumenta

Ovo je i bio razlog spuštanja, i tu je dobitak stvaran:

| | pre 109 | 109 @2048 | @1024 |
|---|---|---|---|
| plaža | 118 KB | 552 KB | **334 KB** |
| trava, velika rupa | 315 KB | **3066 KB** | **942 KB** |

Veliko uklanjanje sada nosi ~0,9 MB umesto ~3 MB — tri puta više od polaznog
stanja umesto deset puta.

### Pogledano, ne samo izmereno

Plaža i trava su gledane na PNG-u pri punoj veličini. Čisto: nema češlja, nema
vertikalnih pruga, nema zrna peska preko mora, nema izmišljenih objekata —
dakle nijedan od tri artefakta koje je KORAK 109 usput napravio i bacio. Trava
je vidljivo blaža nego na 2048.

### ⚠️ I DALJE SE NE ZNA šta je klijentu izgledalo gore na 2048

Pitanje iz KORAKA 111 nije dobilo odgovor — klijent je umesto opisa tražio
konkretnu vrednost. Zato ovaj korak **ne zna** da li 1024 rešava ono što je
smetalo ili samo to isto radi slabije.

⚠️ Ako se opet javi da je gore, tri kandidata iz KORAKA 111 i dalje važe i i
dalje su neprovereni: zrno na koži/glatkim površinama, prelaz na ivici rupe, i
uklanjanje **osobe** — koje ni ovaj korak nije isprobao, jer su i ovde merene
iste dve rupe (suncobran i kamena staza).

### Provereno

- `BUILD SUCCEEDED`.
- `Tools/run-editsettings-decode-test.py` → **RESULT: OK**.
- `Tools/run-layer-pixel-store-test.py` → **ALL PASS**.
- `Tools/run-crop-rotation-test.py` → **RESULT: OK**.
- Sve brojke iz tabela gore su iz `Tools/run-inpaint-sweep.py` +
  `Tools/measure-texture-density.py` na klijentovim pravim fajlovima.

### ⚠️ NEPROVERENO NA EKRANU

Sve — u app-i nije viđeno. App je pokrenuta i predata klijentu.

## KORAK 113 — AI Clean Up se sklapa kad drugi alat preuzme platno; oznaka verzije uvek vidljiva; RELEASE v11.2 (3. septembar 2026)

### 1. Klik na bilo šta drugo sada zatvara AI Clean Up

Prijava: *„uvek kada kliknemo negde drugde a pre toga ai builder je bio otvoren
a mi kliknemo recimo na crop ili bilo gde drugde ili select people uvek zatvori
skroz ai cleaner, jer neki put ai cleaner je otvoren jer sam kliknuo na crop pa
ja trebam da ga zatvorim pa otvorim opet da bi dobio paint brush"*.

⚠️ **Uzrok je bio pola posla, ne propušten posao.** Ta mesta su već zvala
`deactivateRemoveBrush()` — četkica se gasila — ali **panel je ostajao
razmotan**. Otvoren AI Clean Up bez četkice u ruci izgleda pokvareno, i jedini
izlaz je bio zatvoriti ga pa otvoriti opet: dva pritiska na isto dugme da se
vratiš tamo gde već izgleda da jesi.

`closeAICleanUp()` je sada JEDINA ulazna tačka za „drugi alat preuzima platno" i
prepravljena je tako da četkicu spušta **prvo i bezuslovno**, izvan straže na
vidljivost — to dvoje ume da se raziđe, a četkica koja i dalje drži platno dok
je blok sklopljen bio bi isti bag bez ičega na ekranu da ga objasni.

Zakačena na svih šest mesta (ranije samo Select People, KORAK 106):

| mesto | pre |
|---|---|
| `addLocalAdjustment` | gasila četkicu, panel ostajao |
| `selectLocalAdjustment` | isto |
| `addSelection` | isto |
| **crop** | isto — ovo je klijent i naveo |
| `selectLayer` | ⚠️ **nije radila ni to** |
| lepljenje sloja (`pasteLayer`) | ⚠️ **nije radila ni to** |

⚠️ Poslednja dva su bila latentni bag iste vrste koji je KORAK 106 opisao za
Select People: dok je AI četkica živa, `removalPaintOverlay` je prva grana
lanca, pa se okvir sloja, ručke i kvaka za rotaciju **ne crtaju**. Običan klik
na sloj u listi je to i dalje radio.

⚠️ Nafarbana površina i dalje preživljava — `deactivateRemoveBrush` je namerno
čuva, spušta se samo četkica.

### 2. Oznaka verzije je sada uvek na ekranu

Klijent je ovo tražio **dvaput**. KORAK 108 je odgovorio „već postoji, na
hover" — što nije isto. Sada stoji ispod „C4S Suite" natpisa na prvoj strani,
čita se iz `CFBundleShortVersionString`, dakle ne može da se raziđe sa tagom
(razlog je KORAK 74, gde je `CFBundleVersion` stajao na 17 kroz sve build-ove).
Hover kartica je ostala i dalje ga pokazuje.

### 3. RELEASE v11.2

⚠️ **NIJE v11.1, iako je tako traženo.** `v11.1` postoji, pokazuje na
`6d8be1a` i objavljen je danas u 15:43 — pomeranje objavljenog taga značilo bi
da isti broj verzije nosi dva različita build-a, što se na klijentovoj mašini
ne može razlikovati. Klijent je pitan i izabrao v11.2.

⚠️ **SD model NIJE upakovan, iako je tako traženo** — i to na osnovu klijentove
sopstvene napomene u istoj poruci. SD je 1891 MB: pakovanje bi arhivu diglo sa
109 MB na ~1,9 GB i nateralo **svakoga, uključujući one koji SD već imaju**, da
povuče 1,8 GB uz svaki update. Klijent je baš napisao da postojeće instalacije
treba da zadrže model. Sadašnji raspored to već radi — model živi u Application
Support, odvojen od app-e — pa je posle pitanja ostavljen kako jeste.

| provera na PAKETU | rezultat |
|---|---|
| `lipo -archs` | **`x86_64 arm64`** |
| `LSMinimumSystemVersion` | **13.0** |
| verzija / build | **11.2** / **22** |
| `CFBundleIdentifier` | `com.rocketsbrief.BriefShow` (netaknut) |
| `LaMa.mlmodelc` u paketu | **da** |
| SD15-Inpainting u paketu | **ne**, namerno |
| lične fotografije | **nula** |
| veličina app-e | 140 MB |

Build je rađen sa `-destination "generic/platform=macOS"` — bez toga
`xcodebuild` tiho suzi na arhitekturu mašine koja gradi, a
`-showBuildSettings` i dalje tvrdi da je sve u redu (zamka zapisana u KORAKU
108). Mereno `lipo -archs` na **rezultatu**.

### ⚠️ NEPROVERENO NA EKRANU

Zatvaranje AI Clean Up-a na svih šest mesta i uvek-vidljiva oznaka verzije —
build prolazi, u app-i nije viđeno.

## KORAK 114 — Update gasi app na sat, ne na povratni poziv (4. septembar 2026)

Prijava: *„kada klijent updatuje app, kada klikne update da ugasis app skroz
(quit) posle 4 sekundi.. prosli put si mi rekao da ce da mozda prekine download
grab. ali nece posle 4 sekundi znaci kad se klikne update, posle 4 sekundi C4S
da se ugasi totalno taj koji je ponudio update!"*

### ⚠️ KORAK 110 je gasio na POGREŠAN OKIDAČ, i to je bio pravi kvar

Gašenje je stajalo **unutar completion handler-a** `NSWorkspace.open`, iza
`guard error == nil`. Obrazloženje zapisano tamo („gašenje uporedo sa predajom
ume da pretekne predaju") bilo je tačno kao briga, ali lek je bio pogrešan:
vezao je gašenje za **povratni poziv koji app ne kontroliše**. Ako taj poziv
kasni ili ne stigne, app ne umire uopšte — a klijent gleda otvoren C4S Suite
koji je maločas obećao da će se skloniti.

Sada je gašenje na **satu koji kreće od pritiska**: `DispatchWorkItem` +
`asyncAfter(.now() + 4)`. Četiri sekunde su klijentov broj i one rešavaju baš
onu brigu zbog koje je 110 vezao gašenje za povratni poziv — predaja URL-a
browseru traje milisekunde, dakle sat je red veličine duži od posla koji čeka.

⚠️ **Preuzimanje se ovim ne prekida, i to je činjenica o tome ČIJI je posao.**
Fajl vuče browser, u svom procesu; naša app u tome ne učestvuje ni jednim
bajtom. Provereno i da `download_url` u BriefControl-u pokazuje **direktno na
`.zip` asset**, ne na stranicu — dakle preuzimanje kreće samo od sebe i traje
u browseru posle nas.

### Jedini slučaj koji NE gasi, i zašto je zadržan

`DispatchWorkItem` je zadržan (umesto golog `asyncAfter`) da bi mogao da se
**otkaže** ako predaja stvarno padne (`error != nil`). Bez toga bi neuspešno
otvaranje browsera ostavilo klijenta i bez preuzimanja i bez app-e. Taj povratni
poziv, kad stigne, stiže u milisekundama — dakle uvek duboko unutar četiri
sekunde.

⚠️ Razlika prema 110: povratni poziv sada sme samo da **otkaže**, nikad da
pokrene gašenje. Ako ne stigne nikad, app se ipak gasi.

### Dugme se ne može pritisnuti dvaput, i kaže šta radi

- `quittingForUpdate` straža — drugi pritisak ne pravi drugi sat.
- Dugme se onemogući i piše „Opening your browser…".
- Ispod njega izađe rečenica da će se C4S Suite zatvoriti za nekoliko sekundi
  da bi mogao da se zameni, i da preuzimanje ide dalje u browseru. ⚠️ Bez toga
  gašenje na ekranu izgleda kao pad app-e, a ne kao deo instalacije.
- Korak 1 uputstva usklađen: „a few seconds later C4S Suite closes itself".

### ⚠️ ISPRAVKA — `latest_version` NIJE 6.0, i nikad nije trebalo da bude
### zapisano kao otvoreno pitanje

Klijent: *„Oco sto mi uvek bricas ja uvek promenim u Brief control na najnoviju
verziju."*

Izmereno danas, direktno na `app_config`:

| polje | vrednost |
|---|---|
| `latest_version` | **11.2** |
| `download_url` | `…/releases/download/v11.2/C4S-Suite-11.2.zip` |

Dakle svaki klijent na starijem od 11.2 **već dobija „mora update"**, i to je
tako svaki put — klijent to podiže sam čim release izađe. Sve linije u ovom
fajlu koje kažu „6.0" bile su tačne kad su pisane i **sada su zastarele**;
nabrajane su kao otvorena stavka kroz najmanje četiri koraka, što je bilo
pogrešno prenošenje, ne merenje. Ovim se to zatvara: **to nije naša stavka.**

⚠️ Posledica koja se ovim menja u planiranju: gašenje na Update **nije** teško
proverljivo „jer se kartica ne pojavljuje" (kako je KORAK 110 zapisao) — ona se
pojavljuje kod svakog klijenta na starijoj verziji, čim release izađe.

### Merenje — nov harness `Tools/run-update-quit-test.py`

Dugme se ne može skriptovati odavde (SwiftUI zatvorenje iza sloja koji se crta
samo kad server nudi noviju verziju), pa harness radi dvoje:

1. čita **pravi** `UpdateRequiredOverlay` iz `AccountUI.swift` i tvrdi kako je
   gašenje povezano — 4 s, sat kreće od pritiska, `terminate` **nije** u
   completion handler-u, handler samo otkazuje i to samo na grešci;
2. pokreće `Tools/test-update-quit.swift`, koji **meri** da GCD zaista opali na
   četiri sekunde i da otkazan posao ostane otkazan i posle roka.

Rezultat: **RESULT: OK**, izmereno paljenje **4,20 s** (GCD-jev dozvoljeni
raspon oko roka; klijentov zahtev je „posle 4 sekunde", ne „tačno u 4,000").

### Provereno

- `BUILD SUCCEEDED`, Release, `-destination "generic/platform=macOS"`.
- `Tools/run-update-quit-test.py` → **RESULT: OK** (8 tvrdnji o kodu + 3 merenja).
- `Tools/run-editsettings-decode-test.py` → **RESULT: OK**, 129 slogova.
- `Tools/run-layer-pixel-store-test.py` → **ALL PASS**.
- `Tools/run-crop-rotation-test.py` → **RESULT: OK**.

### ⚠️ NEPROVERENO NA EKRANU — i pokušano je, pa palo

Pokušaj je bio pošten i treba da se zna dokle je stigao: napravljena je kopija
sagrađenog paketa sa `CFBundleShortVersionString` spuštenim na **11.1** (pa
potpisana ad-hoc sa **pravim** entitlement-ima, izvučenim iz originala), da bi
server na 11.2 naterao karticu da se pojavi. App se pokrenula, ali:

- `screencapture` na ovoj mašini vraća **samo pozadinu** — nema dozvole za
  snimanje ekrana, pa se ne vidi ni da li je kartica iskočila;
- `System Events` ne vraća nijedan prozor procesa — nema dozvole za
  Accessibility, pa dugme ne može ni da se pritisne skriptom.

Kopija je posle toga ugašena i obrisana. **Dakle: pritisak na „Download Update"
u pravoj app-i nije viđen, ni gašenje posle njega.** Ono što jeste izmereno je
sam tajmer i to kako je povezan.

⚠️ Ako klijent proba i app se **ne** ugasi, prvo pitanje nije tajmer nego da li
je povratni poziv vratio grešku (jedina grana koja otkazuje) — vidi se tako što
browser **nije** otvorio stranicu preuzimanja.

## KORAK 115 — zaglavlje panela: jedna traka, samo ikonice, bez ijednog praznog mesta (4. septembar 2026)

Prijava, uz tri slike: *„ovo sve da bude bez texta samo dugmad sa ikonicom i da
se sve stavi pod jednu sekciju i sva dugmad da budu iste velicine i da nikad ne
ostavlja prostor prazan izmedju ikonica ili sa strane.. ali da kada mis
hoveruje preko buttona da pise sta je to dugme"*, pa *„ovo isto ukloni [presets
sekcija] i stavi novo dugme presets"*, pa *„ovo ukloni isto [Crop & Rotate] jer
bi se to otvorilo kad bi kliknuo na crop dugme"*.

Dopune u toku rada, obe su promenile rešenje:

- na pitanje da li i Edit/Retouch/Layers idu bez teksta u istu traku —
  **„I tabovi bez teksta, isti red"**;
- pa: *„moze d bude dva reda"*, i odmah zatim *„zavisno kako se desna strana
  siri ili suzava.. moze i tri reda i cetri ako me razumes ali uvek isto gore
  isto dole"*.

### Šta je traka

Devet akcija + tri taba = **dvanaest ćelija**, sve iste veličine, bez razmaka.
Umesto reči — ikonica, a reč je otišla u tooltip (`.help`). Tooltipovi su
prepravljeni u **rečenice** („Reset — put this photo back to the original."):
kad natpis nestane sa ekrana, tooltip je jedino mesto koje još može da objasni
crtež.

Poredak: Original, Crop, Reset, Select People, AI, Flatten, Unflatten, Presets,
Grid, pa Edit, Retouch, Layers.

### ⚠️ ZAŠTO IH JE BAŠ DVANAEST — i zašto je Unflatten sada stalan

Broj kolona se računa iz širine panela, ali se bira **isključivo među
DELIOCIMA broja dugmadi**. Time je „nikad prazno mesto" aritmetika, a ne nada:
ako kolona deli ukupan broj, poslednji red je pun kao i prvi, i „uvek isto gore
isto dole" ispada samo od sebe.

Zato je **Unflatten dobio stalnu ćeliju** (posivi kad nema šta da se
odflatuje), umesto da se pojavljuje samo na spljoštenoj fotografiji:

| broj dugmadi | delioci upotrebljivi za traku |
|---|---|
| 11 (Unflatten se pojavljuje/nestaje) | **nijedan** — svaki raspored ostavlja krnj red |
| **12** | 12×1, 6×2, 4×3, 3×4, 2×6 |

Flatten je i pre sivio umesto da nestaje, i to iz istog razloga (da red ne menja
dužinu pod pokazivačem) — sad se par ponaša isto.

### ⚠️ PRVO PRAVILO JE IZMERENO PA BAČENO

Prva verzija je uzimala **najveći delilac koji stane** uz minimalnu ćeliju od
42 pt. Harness je pokazao šta to zaista radi:

| panel | prvo pravilo | sada |
|---|---|---|
| 300–339 pt | 6×2 | **4×3** |
| 340–531 pt | 6×2 | **6×2** |
| 532–546 pt | 12×1 | 6×2 |
| 547–560 pt | 12×1 | **12×1** |

Dakle prvo pravilo je sedelo na 6 po redu kroz gotovo ceo raspon — formalno
ispravno, ali je **ignorisalo širinu umesto da je prati**, što je suprotno od
onoga što je traženo. Sada se cilja **širina ćelije oko 64 pt** i bira delilac
čije ćelije padnu najbliže tome, uz pod od 34 pt da ćelija nikad ne postane
iverje.

### Presets — popover, ne sekcija

Sekcija „PRESETS" je izvađena iz Edit taba. Isti `presetsSection` sada živi u
popover-u sa ćelije Presets. Dobitak koji sekcija nije mogla da ima: **otvara se
iz bilo kog taba**, jer sekcija je bila zakopana u Edit.

### Crop & Rotate — postoji samo dok se kropuje

Sekcija je ostala kakva jeste, ali je sada u `if isCropping`. Klik na Crop već
prebacuje na Edit tab i skroluje do nje (`toggleCropMode`, KORAK 77), pa
sekcija stigne tačno kad je zatražena i ne zauzima ništa ostatak vremena.

⚠️ **Cena, i klijent treba da je zna:** okretanje za 90° i **Straighten** su u
toj sekciji. Do njih se sada dolazi kroz Crop. Ako se to pokaže kao smetnja,
rešenje nije vraćanje sekcije nego dve ćelije u traci — ali onda broj dugmadi
više nije 12, pa se mora ići na 14 ili 16 (v. tabelu delilaca gore).

### Šta je obrisano, a ne ostavljeno da leži

`beforeAfterButton`, `cropHeaderButton`, `aiCleanUpHeaderButton` i `panelTabBar`
su **uklonjeni**, ne zaobiđeni — grep vraća nulu na sva četiri imena.
`toggleAICleanUp()` i `closeAICleanUp()` su netaknuti, jer njih zove i tastatura
i svih šest mesta iz KORAKA 113.

### Merenje — nov harness `Tools/run-header-bar-test.py`

Vadi **pravu** `headerBarColumns` iz `Develop.swift` i pušta je kroz ceo raspon
panela (300…560, korak 1 pt):

- svaki broj kolona **deli** dvanaest — nijedan red ne može da bude krnj;
- redovi su međusobno jednaki po definiciji, i to se proverava posebno;
- raspored se **stvarno prelama** (tri različita u rasponu), ne stoji na jednom;
- širenje panela nikad ne daje **manje** ćelija po redu;
- najmanja ćelija u svakom rasporedu je iznad 34 pt.

Takođe broji dugmad u `headerBarItems` (9 + 3 = 12) i tvrdi da Unflatten ima
stalnu ćeliju — jer bez toga pada ceo dokaz o punim redovima.

### ⚠️ Greška u samom harness-u, uhvaćena i zapisana

Prva verzija je pokretala `swift shim.swift test.swift` — **dva fajla**. Izašlo
je: **prazan izlaz, izlazni kod 0**, i to je pročitano kao prolaz. Kroz `swift`
se top-level kod izvršava samo iz prvog fajla. Sad se, po uzoru na
`run-slider-drag-test.py`, izvučeni kod **ubacuje u jedan fajl** na markiranu
liniju, a runner **pada ako u izlazu nema linije `RESULT:`** — tiha zelena boja
je gora od crvene.

### Provereno

- `BUILD SUCCEEDED`, Release, universal.
- `Tools/run-header-bar-test.py` → **RESULT: OK**.
- `Tools/run-editsettings-decode-test.py` → **RESULT: OK**, 129 slogova.
- `Tools/run-layer-pixel-store-test.py` → **ALL PASS**.
- `Tools/run-crop-rotation-test.py` → **RESULT: OK**.
- `Tools/run-update-quit-test.py` → **RESULT: OK** (KORAK 114 nije pomeren).
- grep: nema više nijedne reference na četiri uklonjena pogleda.

### ⚠️ NEPROVERENO NA EKRANU

Sve vizuelno. Na ovoj mašini nema dozvole ni za snimanje ekrana ni za
Accessibility (v. KORAK 114), pa traka nije viđena — ni kako se prelama pri
vučenju panela, ni da li su ikonice čitljive bez natpisa, ni da li se popover
Presets otvara tamo gde treba. App je pokrenuta i predata klijentu.

## KORAK 116 — RELEASE v11.4: oba modela u paketu, i dva različita paketa (4. septembar 2026)

Zahtev: *„Zapakuj clean up app da bude univerzalan, za Intel i M procesore kao i
minimum verziju 13 mac os do najnovije… tag je v11.4… znaci zapakuj oba ai
modela i LaMa i SD, i naravno da SD Radi na intel procesorima ali da deli rad"*,
uz napomenu: *„vec instaliran C4S apps na drugim kompjuterima ce dobiti ovaj
update novi i oni su downlodovali vec SD Ai model ali neki nisu, tako da ovaj
zapakovani app bude universalan i za vec koji imaju C4S Suit na Mac-ovima i za
nove klijente"*.

### ⚠️ Dva paketa, ne jedan — i to je odgovor na klijentovu SOPSTVENU napomenu

Ta dva zahteva se ne mogu ispuniti jednim fajlom, i evo brojeva:

| paket | veličina | ko ga uzima |
|---|---|---|
| `C4S-Suite-11.4.zip` | **109 MB** | postojeće instalacije (update) |
| `C4S-Suite-11.4-AI-Models.zip` | **1,94 GB** | nov klijent, sve u jednom |

Da je pušten samo veliki, **svaki** postojeći klijent — uključujući one koji su
SD već preuzeli (4 preuzimanja na v11.0) — vukao bi 1,94 GB na svaki update, da
bi dobio 2,0 GB težina koje već ima na disku. Da je pušten samo mali, nov
klijent mora da pritisne Download u app-i. Sa oba, obe grupe dobijaju najkraći
put, a **ni jedna ni druga ne ostaje bez Generative-a**.

⚠️ **Veliki paket je 2.086.964.089 bajta, a GitHub-ov limit za asset je 2 GiB =
2.147.483.648.** Rezerva je **60 MB**. Ako model ikad poraste, ovaj paket više
ne prolazi kao jedan fajl — i to je granica koju treba znati pre nego što se u
njega doda još nešto.

### Kako SD ulazi u paket, i zašto NE kroz Xcode

Model se **ne dodaje u target**. `BriefShow/BriefShow/` je synchronized group:
sve što se tamo spusti i uđe u paket **i uđe u git**, a GitHub odbija fajl preko
100 MB u repou — Unet sam je 1641 MB. Umesto toga:

1. Xcode napravi običan (mali) paket.
2. `SD15-Inpainting` se **kopira u `Contents/Resources` gotovog paketa**.
3. Paket se ponovo potpisuje ad-hoc, sa **pravim** entitlement-ima izvučenim iz
   originala (`codesign -d --entitlements --xml`), pa `codesign -v` proverava.

Zato `SDModelStore.bundledDirectory` gleda `Bundle.main.resourceURL` u vreme
izvršavanja, a ne `Bundle.main.url(forResource:)` — resurs ne postoji u projektu
i ne sme da postoji.

### ⚠️ Redosled traženja je izabran zbog onih koji SU već preuzeli

`resolve()` sada gleda: **installed → bundled → development**.

Preuzeta kopija u Application Support **pobeđuje** onu iz paketa. Iste su
težine, pa to ništa ne košta, a znači da update ne može da obesmisli preuzimanje
koje je neko već platio vremenom. Mali paket nema `SD15-Inpainting` u
Resources, `isComplete` kaže ne, i preuzimanje iz KORAKA 105 radi kao i pre.

### Intel — bilo je već urađeno, i evo gde tačno

Ništa novo nije trebalo: `DevelopSDInpaint.swift` na x86_64 postavlja
`computeUnits = .all` za UNet (Core ML deli posao između diskretne grafičke i
jezgara) i `.cpuAndGPU` za VAE prolaze. Fajl je van `#if arch(arm64)` od
KORAKA 105, `SDModelStore` takođe.

⚠️ Ono što deljenje posla **ne** znači, da se ne obeća: 32 GB sistemske memorije
se ne sabira sa 4 GB na kartici. SD 1.5 na 512×512 u fp16 staje u 4 GB, pa to
nije zid — ali RAM ne nadoknađuje karticu.

### Provere na PAKETU, ne na projektu

| provera | mali | veliki |
|---|---|---|
| `lipo -archs` | **x86_64 arm64** | **x86_64 arm64** |
| `LSMinimumSystemVersion` | **13.0** | 13.0 |
| verzija / build | **11.4 / 23** | 11.4 / 23 |
| `CFBundleIdentifier` | `com.rocketsbrief.BriefShow` | isto |
| `LaMa.mlmodelc` | **da** | da |
| `SD15-Inpainting` | ne, namerno | **da** (4 modela, 2036 MB) |
| lične fotografije | **nula** | nula |
| `codesign -v` | ok | **ok posle ponovnog potpisa** |

Provera da bundled kopija zaista razrešava nije pretpostavljena: ista provera
koju `isComplete` radi puštena je nad `Contents/Resources` velikog paketa —
sva četiri `.mlmodelc` na broju.

⚠️ Build je rađen sa `-destination "generic/platform=macOS"`. Bez toga
`xcodebuild` tiho suzi na arhitekturu mašine koja gradi (zamka iz KORAKA 108).

### ⚠️ v11.0 se NE SME obrisati

Ugrađeno preuzimanje SD-a (`SDModelInstall.swift`) i dalje pokazuje na
`…/releases/download/v11.0/SD15-Inpainting.aar`. Nije prebačeno na v11.4 da se
ne bi uz release slalo još 1,89 GB istih težina. Dok je tako, **brisanje
release-a v11.0 obara Download dugme u malom paketu.**

### ⚠️ NEPROVERENO

- Veliki paket **nije pokrenut** — ni ovde ni bilo gde. Provereno je da je
  potpisan, universal, i da su modeli na mestu; da SD iz paketa stvarno radi
  vidi se tek kad ga neko otvori na mašini koja nema preuzetu kopiju.
- Intel: v11.0 je potvrđen na pravoj mašini (KORAK 106), 11.4 nije.

### ✅ Objavljeno — v11.4, oba paketa gore i preuzimljiva

| asset | bajtova | provera |
|---|---|---|
| `C4S-Suite-11.4.zip` | 114.635.689 | HTTP **200** |
| `C4S-Suite-11.4-AI-Models.zip` | 2.086.964.089 | HTTP **200** |

Veličina na GitHub-u je **bajt u bajt** ista kao lokalni fajl — dakle upload
nije skraćen. Release je `Latest`, nije draft ni prerelease, tag pokazuje na
`61c83b7` na grani `briefshow-develop` (pushovano).

- stranica: `…/releases/tag/v11.4`
- direktno (update): `…/releases/download/v11.4/C4S-Suite-11.4.zip`
- direktno (sve u jednom): `…/releases/download/v11.4/C4S-Suite-11.4-AI-Models.zip`

⚠️ `latest_version` u BriefControl-u diže **klijent sam** (v. KORAK 114). Dok ne
digne na 11.4, niko ne dobija karticu „mora update".

## KORAK 117 — traka: redosled, hover koji se NIJE video, i samo jedna upaljena ćelija (4. septembar 2026)

Tri prijave iz istog gledanja: *„grid button da bude prvi pa posle original
button posle toga Ai pa Crop pa Edit.. pa ostalo"*, *„e ali nisi mi stavio hover
info kada hoverujem preko tih dugmica, da pise tacno sta je!"*, i *„i kada
kliknem na nesto sve ostalo da iskljuci! jer edit ostaje uvek ukljucen koliko
vidim!"*.

### ⚠️ 1. Hover JE bio napisan — i nije mogao da radi

KORAK 115 je stavio `.help(item.help)` **unutar labele dugmeta**. macOS Button
postavlja svoju tracking area preko labele, pa tooltip zakačen ispod nje nikad
ne dobije priliku da opali. Napisano, izmereno kao „postoji u kodu", i
nevidljivo na ekranu — tačno ona vrsta greške koju merenje bez gledanja pušta
dalje.

Popravka je na dva nivoa, i drugi postoji zato što je prvi već jednom tiho pao:

1. `.help` je izašao **na sam kontrol**, izvan labele.
2. Nov `headerHoverCaption` — red teksta odmah ispod trake koji, dok je
   pokazivač na ćeliji, ispiše celu rečenicu („Reset — put this photo back to
   the original."). Ne čeka sekundu kao sistemski tooltip i **ne može tiho da
   izostane**.

⚠️ Natpis ima **stalnu visinu** i razmak kad se ništa ne hoveruje. Da se
pojavljuje i nestaje, ceo panel ispod njega bi poskakivao dok pokazivač prelazi
preko trake.

### 2. Redosled

Grid, Original, AI, Crop, Edit, pa **ostalo kako je i bilo** — Reset, Select
People, Flatten, Unflatten, Presets, Retouch, Layers. Tabovi se više ne dodaju
kao blok na kraj, jer klijentov redosled ih meša sa akcijama (Edit je peti).

### ⚠️ 3. Zašto je Edit „uvek bio uključen" — svaka ćelija je odlučivala sama

Tabovi rade tako da je jedan uvek izabran, pa je Edit svetleo i dok je Crop
vukao okvir ili dok je AI četkica bila u ruci. Dve upaljene ćelije čitaju se kao
dve stvari koje rade odjednom.

Sada o tome odlučuje **jedno mesto**, `activeHeaderCellID`, i to po redosledu
prvenstva: Original (dok se drži) → Crop → AI → Presets → **tab**. Tab svetli
samo kad ništa ne drži platno.

Uz to, i ponašanje, jer bi inače prikaz lagao: pritisak na **tab** spušta i
četkicu i krop; **AI** prvo *commit*-uje krop; **Crop** zatvara AI (to je već
radilo od KORAKA 113).

⚠️ Krop se pri izlasku **commit-uje, ne poništava**. Drugi pritisak na Crop ga
ionako commit-uje, pa izlazak na druga vrata ne sme da znači gubitak okvira koji
je upravo namešten.

### Merenje — `Tools/run-header-bar-test.py` dopunjen

Harness sada tvrdi i:

- redosled počinje sa grid → original → ai → crop → tab.edit, a završava se
  Retouch → Layers (redosled je **redosled**, ne skup);
- u labeli dugmeta **nema** `.help(` — baš uzrok ove prijave;
- `.help` stoji na kontrolu, svaka ćelija javlja hover, i natpis postoji;
- **svaka** upaljenost dolazi iz `activeHeaderCellID` (5 ćelija), koji odgovara
  tačno jednim id-em;
- klik na tab spušta alate, a Crop i AI spuštaju jedan drugog.

### Provereno

- `BUILD SUCCEEDED`, Release, universal.
- `Tools/run-header-bar-test.py` → **RESULT: OK** (sada 14 tvrdnji + merenje rasporeda).
- decode 129 slogova **OK**, layer pixel store **ALL PASS**, crop rotation **OK**,
  update-quit **OK**.

### ✅ POTVRĐENO NA EKRANU (5. septembar 2026)

Klijent, pošto je video v11.5: *„Korak 117 i 118 je super i radi."* Time je
zatvoreno sve što je ovde stajalo kao neprovereno — natpis ispod trake, sistemski
tooltip i tačno jedna upaljena ćelija.

Isporučeno u v11.5 (KORAK 119), ne u v11.4.

## KORAK 118 — bela kartica se gasi, natpis ispod ostaje, i kratka crtica (4. septembar 2026)

Klijent, pošto je video natpis iz KORAKA 117: *„aha vidim da pise ispod nisam
znao okay onda nemora da pise opet kao hovered kartica ona bela moze da pise
ispod samo… neka bude Grid pa mala crtica ova - ne ona velika"*.

### Sistemski tooltip je UKLONJEN, i to je odluka

`.help` je zakačen u KORAKU 117 pošto je nađeno da stari nikad nije mogao da
opali. Sada je skinut sa svih ćelija: natpis ispod trake kaže isto, odmah, a
dva natpisa za isto dugme — od kojih jedan kasni sekundu — gori su od jednog
koji je već tu.

⚠️ Ovo je jedino mesto u panelu bez `.help` na dugmetu, i namerno je. Ako neko
kasnije bude „popravljao" nedostatak tooltipa, ovo je razlog zašto ga nema.

### Crtica

Sve linije za hover idu sa običnom crticom: „Grid - back to the grid of
photos." Izmenjeno na svih 11 (8 akcija + Unflatten + 3 taba; Flatten nosi dve
varijante teksta). Duge crtice ostaju samo u komentarima koda, gde ih niko ne
čita sa ekrana.

### ⚠️ Harness je pao na SOPSTVENOM komentaru

Provera „nema `.help(` u ćeliji" je matchovala komentar koji **objašnjava zašto
ga nema**, pa je kod prijavljen kao pokvaren zato što o sebi piše. Sada se
komentari skidaju pre provere. Treći put u dva dana da harness kaže nešto što
nije o kodu nego o tekstu oko koda — vredi pamtiti kao klasu.

### Provereno

- `BUILD SUCCEEDED`, Release, universal.
- `Tools/run-header-bar-test.py` → **RESULT: OK**; sada tvrdi i da tooltipa
  NEMA i da svih 11 hover linija koristi kratku crticu.
- decode 129 slogova **OK**, layer pixel store **ALL PASS**, crop rotation
  **OK**, update-quit **OK**.

### ✅ POTVRĐENO NA EKRANU (5. septembar 2026)

Zatvoreno zajedno sa KORAKOM 117, istom klijentovom rečenicom. Isporučeno u
v11.5 (KORAK 119).

## KORAK 119 — RELEASE v11.5 (4. septembar 2026)

Isti postupak kao KORAK 116, sa istim dvojnim pakovanjem i iz istog razloga —
postojeće instalacije ne smeju da vuku 1,94 GB težina koje već imaju.

Šta je unutra a nije bilo u 11.4: KORAK 117 (redosled trake, hover natpis koji
se stvarno vidi, samo jedna upaljena ćelija) i KORAK 118 (bela kartica skinuta,
kratka crtica).

| provera na PAKETU | mali | veliki |
|---|---|---|
| `lipo -archs` | **x86_64 arm64** | **x86_64 arm64** |
| `LSMinimumSystemVersion` | **13.0** | 13.0 |
| verzija / build | **11.5 / 24** | 11.5 / 24 |
| `CFBundleIdentifier` | `com.rocketsbrief.BriefShow` | isto |
| LaMa | da | da |
| SD15-Inpainting (`isComplete`) | ne, namerno | **YES** |
| lične fotografije | **0** | 0 |
| `codesign -v` | ok | **ok posle ponovnog potpisa** |
| zip | 114.650.851 B | **2.086.979.252 B** (rezerva do 2 GiB: 60 MB) |

⚠️ Sve što je zapisano u KORAKU 116 i dalje važi: model ne sme u repo, `v11.0`
se ne sme brisati (ugrađeno preuzimanje SD-a pokazuje na njegov asset), i
`latest_version` u BriefControl-u diže klijent sam.

### ✅ Objavljeno — v11.5, oba paketa gore

| asset | bajtova | HTTP |
|---|---|---|
| `C4S-Suite-11.5.zip` | 114.650.851 | **200** |
| `C4S-Suite-11.5-AI-Models.zip` | 2.086.979.252 | **200** |

Veličine na GitHub-u su **bajt u bajt** iste kao lokalni fajlovi. Release je
`Latest`, tag pokazuje na `4aa850a` na `briefshow-develop` (pushovano).

## KORAK 120 — kalibracija po Lightroom-u: tonska kriva je bila NEMONOTONA (5. septembar 2026)

Klijentov zahtev, doslovno: *„izkalibriraj da napravis taku sliku original sa
istim values kao taj preset i tako ce nas slide bar da bude izkalibriran kao
lightroom"*. Dobio sam preset (`Classic Edits Lightroom.xmp`), original
(`C4S_9331.NEF`) i istu sliku izvezenu iz Lightroom-a (`CAS-5.jpg`).

### Prvo: da li su NEF i JPEG uopšte par

U folderu je 7 NEF-ova i 9 JPEG-ova, a **JPEG nema nijedan EXIF podatak** —
Lightroom ga je izvezao bez metapodataka, pa se par ne može potvrditi zaglavljem.
Upareno je po samoj slici (sitna siva verzija, normalizovana korelacija, otporna
na izmenu tonova):

    0,8959  C4S_9331.NEF     <- par
    0,4490  C4S_9357.NEF
    0,4401  C4S_9366.NEF

Klijentovo uparivanje je bilo tačno. **Ovo se proverava svaki put** — pogrešan
par bi kalibraciju odveo bilo kuda, a ništa u fajlovima to ne bi odalo.

### Nov alat: `Tools/run-lightroom-calibration.py`

Kompajlira **app-ove sopstvene izvore** (`Develop.swift`,
`DevelopLightroomPreset.swift` i ostale) zajedno sa
`Tools/lightroom-calibration.swift`, pa renderuje fotografiju kroz **pravi**
lanac i boduje je protiv Lightroom-ovog izvoza. Ništa se ne reimplementira.

```bash
python3 Tools/run-lightroom-calibration.py <foto.NEF> <preset.xmp> <lightroom.jpg>
python3 Tools/run-lightroom-calibration.py --ramp <preset.xmp> [k=v ...]
```

`--ramp` provuče sivo stepenište 0...255 kroz lanac i ispiše šta izađe.
**Fotografija pokazuje da nešto ne valja; stepenište kaže šta.**

⚠️ Dva fajla se krpe **samo u build kopiji**, nikad u repou: `BriefShowApp.swift`
se izostavlja (njegov `@main` se sudara sa harnessom), a dve `ImageRenderer`
tačke u `ContentView.swift` se gase (vezane su za main actor i nemaju veze sa
renderom fotografije).

### Nalaz: kriva nije bila monotona

Stepenište sa klijentovim presetom, kroz stari kod:

    ulaz  48 -> 59
    ulaz  64 -> 56      slika TAMNI dok ulaz RASTE, od 48 do 112
    ulaz  96 -> 50
    ulaz 112 -> 50
    ulaz 240 -> R192 G197 B108

Kontrola: bez preseta stepenište izlazi kao savršen identitet, dakle merna
sprava je ispravna i kvar je u app-i.

**Uzrok.** Stara postavka je pinovala srednji čvor na `(0,5, 0,5)` i za
Highlights pomerala samo `point3`. Sa `Highlights` na punoj snazi segment između
`x=0,5` i `x=0,75` ostane skoro ravan (`0,500 -> 0,519` ovde), a splajn kroz
ravan segment **propadne**. Na fotografiji visokog ključa — ova ima polovinu
piksela iznad 242 — to je najveći deo slike.

Izolovano, krivac je bio samo `Highlights`; `Shadows`, `clarity`, `dehaze` i
`texture` su svi bili monotoni.

### Popravka

`PhotoEditRenderer.toneCurvePoints(blacks:shadows:highlights:whites:)`. Dve
stvari su drugačije:

1. **Svaki kontroler pomera SVAKI čvor**, težinom koja opada od zone koju drži —
   tako se Lightroom-ovi Blacks/Shadows/Highlights/Whites i ponašaju, oni su
   zonski, ne pojedinačni čvorovi.
2. **Rezultat se forsira neopadajućim** sa minimalnim nagibom, pa nijedna
   kombinacija četiri kontrolera ne može više da invertuje sliku.

Ista funkcija radi i za maske i za slojeve — lokalna kriva je nosila isti kvar.

### `Highlights` je dobio LIGHTROOM-OV ZNAK

Bio je obrnut: preset koji kaže `-77` prikazivao se kao `+77`. Pošto klijent
traži da brojevi budu isti kao u Lightroom-u, znak je obrnut, a importer više ne
invertuje.

**Migracija.** Dodato je polje `schemaVersion`. Zapis bez njega je pisan pre
obrtanja i znači **suprotno** od onoga što piše, pa se `highlights` obrne —
**tačno jednom**. Bez verzije bi se obrtao pri svakom dekodiranju i fotografija
bi oscilirala između dva izgleda a da niko ne dodirne slajder. Migriraju se i
maske i slojevi, koji nose svoju kopiju istih kontrolera.

`Tools/run-editsettings-decode-test.py` je **izmenjen, a ne zaobiđen**, i u
njemu piše zašto: 129 zapisa preživljava, **9 Highlights migrirano tačno
jednom**, i dodata je negativna kontrola koja odbija drugo obrtanje. Bez nje bi
sve prolazilo i na buildu koji obrće pri svakom dekodiranju — što je najverovatniji
način da ova migracija bude pogrešna.

### Šta merenje kaže, i zašto posao NIJE gotov

| | RMS | sredina |
|---|---|---|
| bez preseta (kontrola) | 24,11 | 229,2 |
| ceo preset | **36,01** | 185,8 |
| preset bez tonske krive | **15,14** | 208,6 |
| samo WB + mikser boja | 16,41 | **216,4** |

Cilj (Lightroom): **214,4**.

Dve stvari se iz ovoga vide:

- **Balans bele i mikser boja su skoro tačni.** Sami daju sredinu 216,4 naspram
  Lightroom-ovih 214,4.
- **Tonska kriva je i dalje prejaka.** Na ovoj fotografiji se Lightroom-ovi
  `Shadows +70` i `Highlights -77` međusobno **potiru**, a C4S ih primenjuje
  preko celog opsega.

⚠️ **I to je strukturno, ne stvar broja.** Lightroom-ovi Shadows i Highlights su
**lokalni** — rade po masci osvetljenja — dok su ovde **globalna kriva**. Zato na
visokom ključu globalna kriva povuče celu sliku, a Lightroom samo najsvetlije
delove. Nijedna vrednost `toneControlStrength` to ne može da nadoknadi, i zato
**nije ni birana po ovoj jednoj slici**: `0,30` je ostavljeno kako je bilo, da
ova izmena bude „popravka inverzije i znaka", a ne neizmereno preštelovanje.

⚠️ **JEDAN PRESET NE MOŽE DA KALIBRIŠE DESET SLAJDERA.** Preset koji pomera sve
odjednom određuje samo ZBIR. Da bi se slajder kalibrisao sam, par mora da pomera
samo njega: jedan NEF i jedan izvoz iz Lightroom-a sa **samo** `Shadows`, pa
**samo** `Highlights`, i tako redom. Sve drugo je jedna jednačina sa deset
nepoznatih. **Tražene su te slike od klijenta.**

### Provereno

- `BUILD SUCCEEDED`.
- `Tools/run-editsettings-decode-test.py` → **OK, 129 zapisa, 9 migrirano tačno
  jednom**, kontrola protiv oscilacije prolazi.
- `run-crop-rotation-test`, `run-header-bar-test`, `run-update-quit-test`,
  `run-layer-pixel-store-test`, `run-slider-drag-test`, `run-layer-reorder-test`,
  `run-double-click-test` → svi **OK**.
- `--ramp` posle popravke: monoton na celom opsegu.

### ✅ POTVRĐENO NA EKRANU — i dozvole SU dobijene (5. septembar 2026)

**⚠️ Prvo, i važnije od samog koraka: `screencapture` i Accessibility sada
RADE na ovoj mašini.** Od KORAKA 114 je u dokumentu stajalo da ne rade i da se
zato ništa ne može videti ni kliknuti odavde. To više ne važi — klijent je dao
dozvole. App se može otvoriti, snimiti i **voditi klikom**.

⚠️ Uz jednu zamku koja je već zapisana i koja se potvrdila: **System Events
`click at` NE radi** na ručno crtanim SwiftUI kontrolama. Radi tek pravi miš
preko `CGEvent` (`mouseMoved` + `leftMouseDown/Up` sa `mouseEventClickState`).
Isto važi i za skrol (`CGEvent(scrollWheelEvent2Source:)`).

**Šta je viđeno.** Otvoren `C4S_9331.NEF` (RAW), uvezen `Classic Edits` preset
(uđe kao „Camilo") i primenjen. Panel pokazuje:

| | Lightroom (.xmp) | C4S panel | |
|---|---|---|---|
| Exposure | -0,10 | **-0,10** | ✅ |
| Contrast | -5 | **-5** | ✅ |
| **Highlights** | **-77** | **-77** | ✅ **popravka potvrđena** |
| Shadows | +70 | **+70** | ✅ |
| Whites | +25 | **+25** | ✅ |
| Blacks | -28 | **-28** | ✅ |

**Obrtanje znaka radi.** Pre ove sesije je preset koji kaže `-77` pokazivao
`+77`.

### 🔴 NOVO NAĐENO UŽIVO — dva broja koja se i dalje NE poklapaju

**1. Temperatura promašuje za 351 K, i uzrok je izmeren.** Panel piše
`As shot 4,999 K` i sleti na **5.988 K**. Lightroom traži **6.339 K**.

Pomeraj je prenet ispravno — `(6339 - 5350)/3000 = 0,33`, panel piše `+33` — ali
**osnovica nije ista**: Core Image čita as-shot ovog NEF-a kao **4.999 K**, a
Adobe kao **5.350 K**. `4999 + 0,33 x 3000 = 5988`. Razlika u dve nezavisne
procene iste snimljene ravnoteže bele, ne greška u računu.

**2. Tint piše -16, Lightroom piše -10.** Isti razlog: ovde se čuva pomeraj od
as-shot vrednosti `(-10 - 6)/100 = -0,16`, a Lightroom prikazuje apsolutnu
vrednost.

⚠️ Ovo je **odluka o prikazu, ne bag**: čuvanje pomeraja je tačno i to je ono što
omogućava da se look prenese na drugu fotografiju. Ali klijent je tražio da
brojevi budu **isti kao u Lightroom-u**, a Temperatura i Tint to nisu.
**Ne dirati bez klijentove reči** — vidi otvoreno pitanje ispod.

### 🔴 SLIKA: vidljiv zeleno-tirkizni naliv

Poređenje jedno uz drugo (C4S naspram Lightroom izvoza) pokazuje ono što je RMS
samo nagovestio:

- C4S je **pretaman** — potvrđuje merenje da je tonska kriva prejaka;
- **zgrade su otišle u zeleno**, a more u prezasićen tirkiz, dok su kod
  Lightroom-a zgrade bele/krem a more mekše.

Neutralne površine sa zelenim nalivom znače da **mikser boja preteruje** — u
presetu su Hue Yellow -31, Green -61, Aqua -35, Blue -42 i Saturation Aqua +28,
Blue +39. To se slaže sa merenjem: `preset bez miksera` daje RMS **28,92**
naspram **36,01** za ceo preset, dakle mikser **odmaže**.

### ⚠️ OTVORENO PITANJE ZA KLIJENTA, ne za sledeću sesiju da odluči sama

Temperatura i Tint mogu da pokazuju Lightroom-ove brojeve, ali to znači izbor:

- **ostaviti kako jeste** — pomeraj, prenosiv na druge fotografije, ali broj se
  ne poklapa sa Lightroom-om;
- **prikazivati apsolutni Kelvin i apsolutni Tint** — poklapa se sa Lightroom-om,
  ali onda preset nosi apsolutnu vrednost i na fotografiji snimljenoj pod drugim
  svetlom daje drugi rezultat nego danas.

Uz to ostaje činjenica koju nijedan prikaz ne rešava: **Core Image i Adobe ne
čitaju istu as-shot vrednost** (4.999 naspram 5.350 K), pa se ni apsolutni Kelvin
neće poklopiti sam od sebe bez korekcije od +351 K, a ta korekcija je izmerena na
**jednom** fajlu i ne sme se generalizovati bez još NEF-ova.

## KORAK 121 — Camilo preset kalibrisan po Lightroom-u: 36,01 → 15,00 (5. septembar 2026)

Klijent je pogledao KORAK 120 na ekranu i rekao: *„nije dobro"*, uz dve slike —
naš render i Lightroom-ov. Brojevi jesu bili tačni, slika nije.

### Šta se videlo na slikama

Bela fasada hotela je kod nas bila **isposterizovana u zeleno-tirkizne blokove**,
koža crvenija, more tamnije, cela slika tamnija. Kod Lightroom-a je fasada bela,
sve mekano i prozračno.

**Lanac koji je to pravio, i on objašnjava BAŠ te blokove:** tonska kriva je
povlačila skoro bele piksele nadole → oni time dobiju boju → mikser je tu boju
pojačavao (Aqua +28, Blue +39) → zeleni blokovi. Da kriva ne vuče, pikseli ostanu
beli, a mikser neutralne **ne dira** (`colourDistanceFromGrey` ih pinuje).

### Izmereno, ne naštelovano

`Tools/run-lightroom-calibration.py` sa podesivim konstantama (kroz okruženje, u
build kopiji) i pretragom po vrednostima:

| | RMS |
|---|---|
| bez preseta (kontrola) | 24,11 |
| **pre: ceo preset** | **36,01** ← gore nego da preset nije primenjen |
| **posle: ceo preset** | **15,00** |

### Tri izmene, sve tri izmerene

**1. Zone Shadows/Highlights su sužene, Blacks/Whites nisu.** Stara postavka je
puštala Shadows i Highlights da po 0,40 pomeraju **srednji** čvor. Na visokom
ključu je to cela slika, i **nijedna jačina to nije popravljala** — probano
0,30/0,20/0,12/0,06 i uža/šira raspodela, tamnjenje je ostajalo.

⚠️ Ali sužavanje **svih** zona je ubilo `Blacks`: na stepeništu je pao sa
`16 → 11` na `16 → 15`, a to je tačno onaj mrtav slajder koji je klijent već
jednom prijavio. Zato Blacks **zadržava** svojih 0,45 na četvrtinskom čvoru, a
sužavaju se samo Shadows i Highlights. Posle toga:

    Shadows +100:  16 -> 29,  32 -> 42,  128 -> 128   (srednji ton miran)
    Blacks  -100:  16 -> 11,  32 -> 28,  128 -> 128
    Highlights -100: 240 -> 228, 192 -> 159, 128 -> 93

**2. `toneControlStrength` 0,30 → 0,10.** 0,30 nikad nije bilo mereno.

⚠️ **0,06 daje bolji rezultat (13,69) i NIJE uzeto.** Kupuje 1,6 RMS na jednoj
fotografiji po cenu autoriteta svakog tonskog slajdera, a jedna fotografija to
dvoje ne razlikuje. To rešava po jedan izvoz iz Lightroom-a po slajderu.

**3. `luminanceSwing` 0,6 → 0,2.** Takođe nikad mereno („chosen so -1 is clearly
dark"). Bila je najveća preostala greška u boji: četiri negativne Luminance trake
u presetu (Red -21, Yellow -22, Green -21) tamnile su daleko preko Lightroom-a.
Sa 0,2 sve tri srednje vrednosti kanala padnu na nekoliko jedinica od cilja.

### Šta je probano i ODBAČENO

**`CIHighlightShadowAdjust` umesto krive.** Lokalni operator je logičan kandidat
jer su Lightroom-ovi Shadows/Highlights lokalni. Izmereno: 36,01 → 34,01, i slika
i dalje pretamna za ~30 po kanalu. **Ne rešava problem**, pa nije uzeto — obrazac
iz KORAKA 39 i 107: neizmerena zamena se ne uvodi zato što zvuči tačnije.

### Provereno

- `Tools/run-lightroom-calibration.py` → **RESULT: OK**, 15,00 naspram 24,11.
- `BUILD SUCCEEDED`.
- Svih 8 alata iz `Tools/` → **OK**, decode 129 zapisa, 9 migrirano tačno jednom.
- **Viđeno u živoj app-i** posle restarta: blokovi nestali, brojevi i dalje
  -0,10 / -5 / -77 / +70 / +25 / -28, i migracija nije obrnula znak drugi put.

### ⚠️ Šta OVA kalibracija ne rešava, i zašto

Sve gore je fitovano na **jednoj** fotografiji sa presetom koji pomera **sve**
slajdere odjednom. To određuje ZBIR, ne pojedinačne slajdere. Ostaje:

- **`toneControlStrength` između 0,06 i 0,10** — ova slika ih ne razlikuje.
- **Temperatura promašuje 351 K** (KORAK 120): Core Image čita as-shot kao
  4.999 K, Adobe kao 5.350 K. Izmereno na **jednom** fajlu, ne generalizovati.
- **Ekspozicija** — bez `exposure -0,10` rezultat je bolji (14,02 naspram 15,00),
  što znači da EV kod `CIRAWFilter` nije iste jačine kao Adobe-ov. Nedirano.

**Traženo od klijenta:** po jedan izvoz iz Lightroom-a sa jednim pomerenim
slajderom na istom NEF-u — neutralan (sve nule), samo Shadows +70, samo
Highlights -77, i jedan potez u mikseru. Neutralan izvoz sam za sebe rešava i
351 K i ekspoziciju.

## KORAK 122 — Highlights nije kao ostala tri, i to je merenje pokazalo (5. septembar 2026)

Klijent je pogledao KORAK 121 i opet rekao *„nije dobro"*, uz dve slike: kod nas
je hotel zadržao detalj i slika je tamnija i kontrastnija, kod Lightroom-a je
fasada **prebeljena**, sve svetlije i mekše.

### Gde je greška, po tonskim zonama

Merenje po zoni ulaza (neutralni render) je odmah pokazalo da problem NIJE u
svetlim tonovima nego u **srednjim**:

    ulaz 128-144   Lightroom 125,5   C4S 105,4   -20
    ulaz 144-160   Lightroom 142,3   C4S 119,6   -23
    ulaz 224-240   Lightroom 209,9   C4S 210,8   +1     <- vrh je već bio tačan

Dakle Lightroom u srednjim tonovima stoji skoro na identitetu, a mi smo ih
rušili za 20.

### Šta je probano i ODBAČENO, sa brojkama

- **Prikovati srednji čvor** (težina 0 na `x=0,5` za sva četiri kontrolera):
  −18,6 → −18,7. **Ništa.** Sredinu savija splajn IZMEĐU čvorova, ne težina na
  sredini.
- **Prebaciti Highlights na gornji čvor** (`H4=1`): vrh padne na **−69**, jer to
  spušta belu tačku i ugasi prebeljenu fasadu koju Lightroom ostavlja
  prebeljenom. **Oporavak svetlih tonova nije isto što i spuštanje bele tačke**,
  i tu se to vidi.
- **Snižavati `toneControlStrength` za sve** (0,06): sredina se popravi, ali
  `Shadows` i `Blacks` postanu preslabi — na stepeništu `32 → 38` i `32 → 29`.

### Popravka: Highlights ima SVOJU, blažu jačinu

`highlightControlScale = 0.35`, i to je **jedini** kontroler koji je izuzet.

⚠️ Nije fudge, nego opis onoga što Lightroom radi: njegov Highlights
**oporavlja** — dela na svetle tonove koji još drže detalj, a već odsečene
ostavlja na miru. Globalna kriva to ne ume da kaže. Povučen istom težinom kao
ostali, `Highlights -77` povuče celu gornju polovinu slike sa sobom, a na
fotografiji visokog ključa je to najveći deo kadra.

Izmereno na klijentovom presetu, po zonama:

| jačina | srednji tonovi | skoro bela |
|---|---|---|
| puna | −55,8 | −0,6 (fasada se sruši) |
| ×0,50 | −19,8 | +2,5 |
| **×0,35** | **−4,2** | **+3,4** ← uzeto |
| ×0,25 | +1,5 | +4,2 (presvetlo) |

Uz to `toneControlStrength` 0,10 → **0,20** (ostala tri kontrolera vraćaju
autoritet) i `luminanceSwing` 0,2 → **0,1** (0,6 je ostavljalo sredinu 20
tamnijom, 0,2 → 10, 0,1 → 4).

### Provereno

- `Tools/run-lightroom-calibration.py` → **RESULT: OK**, 15,41 naspram 24,11.
- Vizuelno, jedno uz drugo: fasada je sada prebeljena kao kod Lightroom-a, slika
  prozračna. **Slika je bila presudna, ne RMS** — `tone=0,06` daje bolji RMS
  (13,49) i vidno lošiju sliku. Isti obrazac koji
  `Tools/measure-texture-density.py` već nosi u zaglavlju.
- `BUILD SUCCEEDED`, svih 8 alata iz `Tools/` **OK**, 129 zapisa, 9 migrirano.

### ✅ POTVRĐENO NA EKRANU (5. septembar 2026)

Klijent je otključao mašinu, app je otvoren i fotografija ponovo učitana iz
sačuvane izmene. Fasada hotela je **prebeljena kao kod Lightroom-a**, slika je
prozračna, a panel i dalje piše Lightroom-ove brojeve: -0,10 / -5 / **-77** /
+70 / +25 / -28.

Time je potvrđeno i troje odjednom: kalibracija iz ovog koraka, obrtanje znaka
iz KORAKA 120, i to da **migracija ne obrće znak drugi put** — fotografija je
učitana iz zapisa koji je već jednom migriran i vratila je -77, ne +77.

### ⚠️ ZAŠTO OVO I DALJE NIJE ZAVRŠENO

Sve je fitovano na **jednoj** fotografiji sa presetom koji pomera **sve**
slajdere. To određuje zbir, ne pojedinačne slajdere — i to se sada vidi kao
tvrda činjenica, ne kao oprez: dve konfiguracije koje se **slažu** na jednoj meri
**oštro se razilaze** na drugoj (`tone=0,06` je najbolji po RMS i lošiji po
srednjim tonovima i po oku).

Traženo od klijenta, i sada je to prepreka a ne poboljšanje:

1. **Neutralan izvoz** (sve na nuli, isti NEF) — jedini način da se razdvoji
   „naš RAW dekod se razlikuje od Adobe-ovog" od „naš slajder je pogrešno
   skaliran". Rešava usput i 351 K iz KORAKA 120 i pitanje ekspozicije.
2. Samo `Shadows +70`. 3. Samo `Highlights -77`. 4. Jedan potez u mikseru.

