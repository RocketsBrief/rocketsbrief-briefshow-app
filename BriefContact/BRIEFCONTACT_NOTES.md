# BriefContact — beleška za nastavak rada

Poslednja izmena: 23. septembar 2026.

BriefContact je **veb galerija za kupce**: fotograf pokazuje slike online (kao contact sheet), a kupci ne
treba da mogu da ih iskoriste, ni screenshot-om ni fotografisanjem ekrana telefonom. Nastala je iz
**ViewThem** prozora u C4S Suite-u (`BriefShow/ViewThem.swift`, KORAK 214 u
`BRIEFSHOW_DEVELOP_NOTES.md`).

⚠️ **Rečeno klijentu na početku i važi i dalje:** ništa ne može potpuno da spreči fotografisanje ekrana
(„analogna rupa"). Sve ovde je otežavanje i odvraćanje, ne garancija.

---

## Gde je šta

| | |
|---|---|
| stranica | `BriefContact/index.html` — jedan fajl, bez build koraka |
| ova beleška | `BriefContact/BRIEFCONTACT_NOTES.md` |
| test modela | `BriefContact/tools/model-test.mjs` (v. dole) |
| app verzija | `BriefShow/ViewThem.swift` — dugme **ViewThem** u headeru C4S Suite-a |

## Kako se pokreće (lokalno)

Kamera u browser-u radi samo na `https` ili `localhost`:

```
cd ~/Desktop/BriefShow/BriefShow/BriefContact
python3 -m http.server 8765 --bind 127.0.0.1
open "http://localhost:8765/?v=$(date +%s)"
```

**Pravilo za rad:** posle svake izmene server se restartuje i otvara se **nova kartica** (`?v=` da browser
ne posluži staru stranicu). Klijent je to tražio 23.09.

---

## Šta stranica radi

### Prikaz
- **Dve slike po strani**, jedna pored druge, sa razmakom od 24 px, i **Previous / Next** ispod
  (strelice ←/→ rade). **Size** je visina slika, a **Width** najveća širina para.
- **Slike su prikovane za ekran, ne za prozor** („Pinned by camera"). Stoje gore u sredini, odmah ispod
  trake browser-a, tik uz kameru. Ako se prozor povuče nadole ili u stranu, sadržaj klizi suprotno pa
  slike izlaze iz prozora. Da bi se videle, prozor mora gore, do kamere. Stranica se ne skroluje.
- **Podešavanja su skroz dole**, a slike gore.
- **Add Photos** sa trakom napretka (`3 / 10`). Samo JPG/PNG, browser ne otvara NEF. Slike se **ne
  pamte** između učitavanja.

### Crna mreža (isto kao u app-i)
- Vodoravne linije idu nagore, uspravne udesno. Linije su u **koordinatama prozora**, pa jedna linija
  prelazi preko obe slike.
- **Black** ili **Blurry** (uvek tačno jedno): Black su pune crne linije, a Blurry „mutno staklo", traka
  zamućene slike u punoj svetlini.
- **Blur around**: zamućenje slike pored svake linije, širinu određuje **Blur**.
- **Flicker**: vodoravne i uspravne linije trepere **suprotno**, sa **preklopom 10 %**, pa nema trenutka
  bez crnog. **Flicker speed** je broj treptaja u sekundi.
- Crtanje: zamućena kopija slike pravi se **jednom** po veličini, a svake sličice crta se kroz **jedan**
  isečak (`Path2D` clip). Crtanje po liniji je gušilo stranicu i izazvalo lažno „No face".

### Baterijska lampa
Slika je zamućena i tamna, a jasan je samo krug oko miša (**Light size**). Mutno staklo se tamni samo
van kruga, istim prelazom kao lampa.

### Čuvar (kamera kao senzor)
Modeli rade u **Web Worker-u**, pa ne ometaju crtanje mreže. Svaka provera ide redom:

| signal | kada slike pocrne |
|---|---|
| kamera | nije dozvoljena, ugašena, ili je **prekrivena** (srednja svetlina < 0,06) |
| **Face needed** | **3 provere zaredom** bez pravog lica |
| **Mouse needed** | 4 s bez miša i tastature |
| **telefon** (COCO-SSD) | „cell phone" ili „remote" ≥ 1 − Sensitivity |
| **Arm pose** (MoveNet) | šaka iznad ramena, lakat u visini ramena, podlaktica nagore; **2 provere zaredom** |
| **Motion** | naglo se promeni ≥ 18 % ivica kadra ili ≥ 30 % celog kadra |

Posle alarma slike ostaju crne još **1,5 s**. Dok je čuvar podignut, **ništa se ne crta od slike**, ni
Blurry trake ni zamućenje, jer bi inače slika virila kroz mrežu „u kockicama".

**Telefon se traži u 8 isečaka**: ceo kadar, pa donja dva ugla (prvi, jer se tu telefon drži), gornja
dva ugla, leva i desna polovina, i donja polovina. Svaki se uvećava do veličine koju model vidi.

**Lice** traži MediaPipe Face Detection, ali lice se računa samo ako **izgleda kao lice**
(`isRealFace`): oči u ravni i razmaknute, nos ispod očiju, usta ispod nosa i između očiju. Na
klijentovom snimku (teme, prsti, tri sočiva telefona) detektor je „našao" lice sa očima jednu ispod
druge. Pravilo ga odbacuje, a pravi portret prolazi.

Kamera se uzima **u punoj širini** (do 1920×1080, 16:9). 640×480 je isečena sredina.

### Screenshot
⚠️ **Veb stranica ne može da blokira screenshot.** App može (`sharingType = .none`). Stranica umesto toga
**cela pocrni**:
- Mac: čim su ⌘ i ⇧ pritisnuti zajedno (⌘⇧3/4/5 tako počinju),
- Windows: Windows taster i Print Screen,
- uvek kad browser **nije aktivan prozor** ili je kartica skrivena.
Tihi program za snimanje dok browser ostaje u fokusu ovo ne hvata.

### Kartica za kameru
- Kamera se **ne traži pri učitavanju**. Prvo naša kartica „Camera consent — please read", pa tek na
  klik pitanje browser-a (inače se dva pitanja pojave odjednom).
- Tekst kartice se upisuje **samo kad se stanje promeni**. Upisivanje 12 puta u sekundi je gutalo klik
  na dugme.
- Posle „Never for This Website" browser **ne dozvoljava** stranici da ponovo pita. Kartica tada
  prikazuje korake za browser koji kupac koristi (Safari, Chrome, Edge, Firefox, plus Windows
  podešavanje) i dugme **„I've allowed it — reload"**.
- ⚠️ **Tekst saglasnosti mora da pregleda pravnik pre objave** (GDPR, srpski ZZPL). Svaka rečenica u
  njemu mora ostati tačna za kod: slike sa kamere se obrađuju samo u browser-u i nigde se ne šalju.

---

## Početna podešavanja (klijentova, 23.09)

Sensitivity 75 %, Width 70 %, Size 300, Light size 115 px, Flicker speed 17, Lines 40, Thickness 2 px,
Speed 103 px/s, Blur 6 px. Uključeno: Phone guard, Corners, Motion, Arm pose, Face needed, Mouse needed,
Pinned by camera, Mesh, Black, Blur around, Flashlight, Flicker, Vertical. **Show camera isključen.**

## Modeli (svi besplatni, bez kupovine)

| model | za šta | licenca |
|---|---|---|
| COCO-SSD `mobilenet_v2` (TF.js 4.22) | telefon („cell phone", „remote") | Apache 2.0 |
| MoveNet SinglePose Lightning | ramena, laktovi, šake | Apache 2.0 |
| MediaPipe Face Detection `short` (tfjs runtime) | lice | Apache 2.0 |

YOLO modeli su **namerno izbegnuti**: AGPL licenca pravi problem kod prodaje. Sopstveni model se ne
trenira. Za „cell phone" već postoji istreniran na hiljadama slika.

Modeli se sada učitavaju sa jsDelivr/tfhub. **Za Cloudflare ih treba držati kod nas**, pa stranica
neće zvati nikoga sa strane.

---

## Probano i izbačeno — ne ponavljati

- **Moaré** (fina rešetka) — *„nije more nesto dobro"*.
- **TV roll** (cela slika trepće, pa rolling shutter pravi trake) — ekran menja sliku najviše 60 puta u
  sekundi, pa su trake bile preširoke.
- **Malusov zakon / polarizacija** — polarizacija je u hardveru ekrana, a telefon nema filter. Softver
  tu nema šta da uradi.
- **„Near camera"** (slike pocrne kad je prozor dole) — nije bilo ono što je klijent mislio. Zamenjeno
  prikovanjem za ekran.
- **± treperenje u parovima** kao glavni režim — oko ga usrednji u sivo, a klijent hoće punu crnu.
- **Pametne naočare sa kamerom** — nijedan besplatan model ne razlikuje ih od običnih. „Sve naočare =
  crno" bi isključilo kupce sa dioptrijom.

## Otvoreno

- ⚠️ **Telefon postavljen vodoravno se prepoznaje lošije nego uspravno** (klijent, 23.09). Moguće
  sledeće: dodatni isečci sa drugim odnosom strana, rotiran isečak za 90°, ili niži prag samo za
  donju polovinu. Izmeriti sa `tools/model-test.mjs` na pravom snimku.
- Telefon izbliza, napola van kadra, i dalje ume da promakne. Tada spasava „No face".
- Spoljni monitor: prikovanje pretpostavlja da je kamera gore u sredini **ekrana na kome je prozor**.
- Safari možda ne javlja poziciju prozora dok se vuče, pa slike skoče na mesto tek kad se prozor pusti.
- Dugme u C4S Suite-u i dalje piše **ViewThem**. Klijent nije rekao da ga preimenujemo.
- Cloudflare verzija: hosting, self-host modela, čuvanje slika, link po kupcu, ime kupca preko slike.

## Test modela bez browser-a

`tools/model-test.mjs` pušta **iste modele** kroz Node na PNG kadru i ispisuje šta vidi svaki isečak,
koliko je lica nađeno i koliko prolazi `isRealFace`. Pravi kadar sa kamere (snimak ekrana „Show
camera") najbolje otkriva zašto nešto nije uhvaćeno.

```
mkdir -p /tmp/bc-test && cd /tmp/bc-test && npm init -y >/dev/null
npm install @tensorflow/tfjs@4.22.0 @tensorflow-models/coco-ssd@2.2.3 \
  @tensorflow-models/face-detection@1.0.3 @tensorflow-models/pose-detection@2.1.3 \
  @mediapipe/face_detection @mediapipe/pose pngjs
cp ~/Desktop/BriefShow/BriefShow/BriefContact/tools/model-test.mjs .
node model-test.mjs kadar.png
```

⚠️ Klijentovi snimci sa kamere su **lični** (lice, soba). Ne commit-ovati ih.
