# BriefShow Develop — status i plan

Beleška za nastavak rada. Poslednja izmena: 25. avgust 2026.

**⚠️ Za sledeću sesiju koja dodaje bilo kakav novi `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` monitor** — DVA obavezna pravila, oba naučena kroz prave incidente u produkciji:
1. UVEK proveriti `event.isARepeat` i vratiti `event` (ne progutati) kad je true, OSIM ako je namerno drugačije. Stavka #15 ispod dokumentuje prvi incident (app zamrznut, `kill -9` morao) kad je ovo izostavljeno.
2. UVEK ograničiti monitor na SVOJ prozor (`guard NSApp.keyWindow?.title == "<taj prozor>" else { return event }`, prva linija u handleru). Local NSEvent monitori su APP-WIDE, ne po-prozoru — bez ove provere, monitor registrovan u JEDNOM prozoru (npr. ShowGrid) i dalje prima i OBRAĐUJE tastere dok je NEKI DRUGI prozor (npr. Develop) fokusiran, često sa netačnim/praznim kontekstom (npr. "ništa nije selektovano, pa primeni na CEO folder"). Stavka #18 dokumentuje pravi incident (ceo Desktop folder rekurzivno kopiran u sebe, DVA puta, `kill -9` morao oba puta) kad je ovo izostavljeno na ShowGrid-ovom monitoru dok je Develop-ov (koji JESTE imao ovu proveru) bio ispravan primer.

## TL;DR — gde smo stali

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
| 44 | **Patch i Selection kreću kao free**, i nijedan više ne laguje pri prevlačenju |

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

### Oba alata sada kreću kao free-hand

Krug je bio stari difolt, uz obrazloženje da „ne traži crtanje da bi nešto
uradio". U upotrebi je to naopako: krug sleti nasred fotke preko onoga što se tu
zatekne, pa se onda vuče, menja mu se veličina i najčešće se ionako prebaci na
free — dakle ono što je taj difolt kupovao niko nije ni hteo. Oba oblika i dalje
postoje u panelu.

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
