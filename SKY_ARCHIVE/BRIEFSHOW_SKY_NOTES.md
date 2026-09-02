# BriefShow — sve o NEBU, i zašto je izvađeno

Napisano 2. septembra 2026, u trenutku kad je funkcija uklonjena iz app-e na
zahtev klijenta. **Ovo je jedini zapis koji ostaje** — kod, slike i alati su u
`SKY_ARCHIVE/` pored ovog fajla.

Ako se ikad nastavi: pročitati OVAJ dokument do kraja pre nego što se išta
vrati. Polovina onoga što piše ovde su stvari koje su izmerene tek pošto su
izgledale kao da rade.

---

## 1. Šta je postojalo, na kraju

| deo | gde je bio | šta je radio |
|---|---|---|
| `SkyMasker` | `DevelopInpaint.swift` | heuristika koja nalazi nebo i vraća masku |
| `SkyStyle` | `Develop.swift` | 7 **nacrtanih** neba (gradijent + oblak) |
| `SkyPhoto` | `Develop.swift` | 15 klijentovih **fotografija** neba, u bundle-u |
| `SkyChoice` | `Develop.swift` | `.drawn(SkyStyle)` ili `.photo(ime)` |
| `SkyPainter` | `Develop.swift` | crta nacrtano nebo / učitava fotografiju |
| `matchedToScene` | `Develop.swift` (`PhotoEditRenderer`) | uklapa izabrano nebo u svetlo kadra |
| Select Sky | dugme u Layers | pravi Sky sloj sa maskom |
| Change Sky | modal | bira nebo |
| `Tools/run-skymask.py` | alat | crta masku crveno preko prave fotografije |

Sve je u `SKY_ARCHIVE/code/SkyTypes.swift`, slike u `SKY_ARCHIVE/skies/`, alati u
`SKY_ARCHIVE/tools/`.

---

## 2. Kako je maska radila

Nebo se traži na radnoj kopiji od 900 px po dužoj ivici. Četiri skora se množe
i sabiraju u jedan:

- **boja** — plavo ILI svetlo-bezbojno, kao **MAKSIMUM** a ne proizvod (duboko
  plavo nebo ne skoruje na „svetlo" i obrnuto; množenje bi odbilo oba);
- **ravnost** — nebo je najravnija stvar u kadru, ovo izbacuje zgrade i lišće;
- **visina u kadru** — sa **PODOM od 0,25, ne rezom**: nebo silazi između zgrada,
  a ravan rez preko slike je najočigledniji način da zamena neba oda samu sebe;
- **povezanost sa vrhom** (`growFromTop`) — nebo je ono do čega se stigne
  spuštanjem od vrha bez prelaska preko nečega što nije nebo.

Zatim se **oduzimaju ljudi** (Vision), jer koža na suncu je bleda, glatka i
visoko u kadru — dakle prolazi **po zasluzi**.

### Hod nadole — dva zaustavljanja

1. **skor padne** (sa tolerancijom od 3 reda, da žica ili grana ne preseku nebo);
2. **ivica pravo nadole** — piksel se oštro razlikuje od onog **iznad** njega, u
   FOTOGRAFIJI a ne u skoru.

Izmereno: unutar neba je taj korak 0 (p50), 1 (p90), 1–4 (p98), 2–26 (p99,9).
Granica **40** stoji čisto iznad svega toga.

### Posle hoda

- **`withoutStripes`** — medijan filtar nad profilom dubine. Kolona koja prođe
  kroz zgradu je **impuls**; medijan ga uklanja i, za razliku od blura,
  **ne zaobljava pravi stepenik** — a krov JESTE stepenik.
- **`isPlausibleHorizon`** — kapija: ako je (p95 − p50) dubine veći od 0,30
  visine kadra, maska se **odbija**. Loša maska je gora od nikakve, jer se otkrije
  tek pošto je novo nebo već na slici.
- **`continuousHorizon`** — horizont se interpolira preko zaklonjenih kolona pa
  ide **od ivice do ivice**, a skor se primenjuje po pikselu iznad njega. Palma
  ostaje van maske, nebo IZA nje ulazi.
- **feather samo na horizontu** (4,5% visine), ne svuda — oko palmi i krovova
  ivica ostaje tvrda.

---

## 3. ⚠️ TRI GREŠKE KOJE SU IZGLEDALE KAO PODEŠAVANJE

Ovo je najvredniji deo dokumenta.

### 3.1 Alat nije merio app

`Tools/skymask.swift` je nosio **ručnu kopiju** `SkyMasker`-a, dok su beleške
tvrdile da ga izvlači iz izvora. Kopija je slučajno još bila identična, pa ništa
nije bilo pogrešno izmereno — ali prva izmena bi bila merena nad **starim
kodom**, a rezultat bi izgledao kao merenje. Zamenjeno pravim izvlačiocem
(`run-skymask.py`).

**Pouka:** svaki harness u ovom projektu mora da vadi kod iz izvora po balansu
zagrada. Kopija je bomba sa odloženim dejstvom.

### 3.2 Hod je merio ARTEFAKT RENDERA

`.RGBA8` vraća **premultiplikovanu** boju, a skalirana radna kopija ima
razlomljen extent — pa je **prvi red bitmape poluprekriven**: alpha 141, boja
133/137/141, dok je isto to nebo u punoj vrednosti 241/249/255.

Sirovo čitano, skok sa reda 0 na red 1 je **114** — granica po svakom pragu.
Kad je dodat test „zaustavi se na ivici", **svaka kolona je pucala na redu 1** i
maska je dolazila prazna. Izgledalo je tačno kao pretesna granica, i **nikakvo
popuštanje granice to ne bi našlo.**

**Pouka:** kad se čita bitmapa iz CoreImage-a, ili se un-premultiplikuje ili se
odbacuju piksely sa alfom < 255. I: kad merenje da broj koji se ponavlja tačno
(114, 114, 114), to nije priroda — to je artefakt.

### 3.3 Referenca je bila trovana na promašenom redu

Na redu koji padne na skoru (žica, grana), referenca za sledeće poređenje je
ažurirana na **taj tamni piksel** — pa je povratak u nebo bio ogroman skok i
tolerancija od 3 reda bila potpuno obesmišljena.

---

## 4. ⚠️ ZID — gde heuristika prestaje, izmereno

**Beli hotel ispod belog neba se lokalno NE MOŽE razlikovati od neba.**

Izmereno na `C4S_8987.NEF`: nebo 241/249/255, fasada praktično isto. Nema koraka
koji se traži, nema boje koja se razlikuje, a ravna je čim se skor zamuti u
regione. Medijan skraćuje **usamljene** pruge, ali ne pomaže kad je blok zgrade
širi od prozora filtra.

Isto važi za `C4S_8991.NEF`: more i pesak bez horizonta prolaze iz istog razloga.

**Zaključak:** heuristika radi na kadru sa vidljivim horizontom i ne radi kad
veliko svetlo telo stoji pod svetlim nebom. To nije podešavanje koje fali — to je
kraj onoga što lokalni test može. Dalje se ide samo sa **treniranim
segmentacionim modelom** (stotine MB + licenca) ili tako što klijent **zaokruži
oblast Selection alatom** pre pritiska (radi već i tada).

**Testni kadrovi, sa merenjima (p95 − p50) dubine, u delovima visine:**

```
C4S_8947  0.030   dobar (zgrade + more, jasan horizont)
C4S_8995  0.046   dobar
C4S_9011  0.069   dobar (maska od ivice do ivice)
C4S_8991  0.152   maska uzme i more i pesak
C4S_8939  0.160   dobar
C4S_8943  0.160   dobar
C4S_8987  0.547   PRUGE niz beli hotel — odbija se
```

**Dve metrike koje su probane i odbačene:** standardna devijacija dubine (8987 je
0,190 a savršeno dobar 8991 je 0,139 — ne razdvaja) i „udeo kolona dubljih od
dvostruke medijane" (0,000 na pet kadrova, 0,42 na 8987 — ali 0,34 na 9011 čija
je maska TAČNA; medijana mu je 2% kadra, pa je „dvostruka medijana" 4%, a
odnos prema skoro-nuli nije merenje).

---

## 5. Neba

15 klijentovih fotografija, iz `~/Downloads/Skies`. **Isečena su na nebo** —
devet ih je imalo more ili plažu u donjoj polovini. Rez je **očitan sa svake
slike posebno**, ne nađen detektorom: petnaest brojeva pogledanih odjednom vredi
više od detektora koji pogreši na dve a niko ne gleda. Planine u `sky-11` su
**zadržane** po klijentu — planinski venac je pejzaž, plaža je druga plaža.

Rezovi (deo visine od vrha koji se čuva):

```
1: 0.45   2: 0.82   3: 0.84   4: 1.00   5: 1.00
6: 0.52   7: 0.52   8: 0.74   9: 0.62  10: 0.55
11: 0.92  12: 0.45  13: 1.00  14: 1.00  15: 1.00
```

2400 px po širini, JPEG 0,86 → **8,5 MB za svih petnaest**.

**⚠️ Bundle spljošti podfolder.** Fajlovi su stajali u `BriefShow/Skies/`, ali je
to unutar file system synchronized grupe i Xcode ih kopira u
`Contents/Resources` **bez foldera** — provereno u napravljenom bundle-u. Zato je
`SkyPhoto.url` tražio **ravno prvo**, a podfolder samo kao rezervu.

---

## 6. Uklapanje neba u sliku

**Šav nije ono što odaje zalepljeno nebo — SVETLO jeste.** Nebo zalepljeno u
sopstvenoj svetlini i boji čita se kao drugi dan nalepljen preko slike, i nikakvo
omekšavanje šava to ne rešava.

`matchedToScene`: izmeri se nebo koje se zamenjuje, izmeri se novo, i novo se
pomeri **45% puta** ka starom. Deo puta, ne ceo — ceo bi reprodukovao baš ono
nebo koje se menja.

- **Mereno POD MASKOM**, ne preko kadra: kadar koji je četiri petine pesak inače
  povlači svako nebo ka boji peska.
- **Pojačanje po kanalu**, ne pomeranje temperature: nosi i svetlinu i boju u
  jednom potezu, a pojačanje ostavlja crno na crnom. Ograničeno 0,6–1,7.
- **Sopstveni `CIContext`** — čita prosek jednim pikselom *unutar* rendera koji
  već drži jedan od tri konteksta; isti kontekst bi zaključao render protiv sebe.

---

## 7. ⚠️ OREOL — dva izvora, oba nađena tek na pravoj slici

Nad **prebeljenim** nebom svaka meka ivica maske pusti staro belo nebo kroz novo.

1. **Oduzimanje ljudi je bilo naduvano na 0,006** ≈ 31 px na kadru od 5176. Svaki
   taj piksel čuva ORIGINAL — dakle debeo beo sjaj oko svakog čoveka, povrh novog
   neba. Spušteno na 0,0015. Naduvavanje je i samo nekad bilo popravka oreola
   (rim light), pa je trampa neizbežna: **nekoliko piksela u kosi je porub,
   trideset je oreol.**
2. **Blur od 0,004 (≈20 px) na kraju maske** omekšavao je i ivicu oko palmi i
   krovova — traka starog neba koja prati svaki list. Uklonjen; horizont ima
   sopstvenu rampu.

---

## 8. ⚠️ I JEDNA GREŠKA U DIZAJNU, DA SE NE PONOVI

Izabran Sky sloj nije pokazivao ništa na slici (izvedeni sloj nema okvir, jer bi
okvir bio pravougaonik oko cele slike). Dodata je **magenta koprena preko maske**
— i isporučena **bez uslova**, pa je ostajala da stoji i **pošto** se nebo
izabere. Klijent je izabrao plavo nebo i dobio ljubičastu sliku: *„izgleda
užas!"*

Izmereno pre nego što je išta dirano: `sky-7.jpg` u traci koja se vidi je
prosečno **R110 G170 B222** — plavo. Ljubičasto je bilo plavo ispod 34% magente.

**Pouka:** indikator koji pokazuje GDE je nešto nađeno mora da nestane čim
postoji rezultat koji se gleda.

---

## 9. Zašto je izvađeno

Klijentova odluka, 2.09. Traženo je bilo da SD odredi masku i ubaci nebo. Odgovor
koji je do toga doveo:

- **SD inpainting POPUNJAVA zadatu masku — on je ne pravi.** Određivanje gde je
  nebo je semantička segmentacija, drugi posao i drugi model. Vision segmentira
  samo ljude.
- SD **može** da inpaintuje nebo u masku, ali bi ga **izmislio**, ne stavio
  klijentovu sliku.
- Radno platno je zaključano na **512 px**; nebo je velika površina, pa se vraća
  mekano posle uvećanja — za razliku od male mrlje koju Clean Up briše.

Zaključak koji je klijent prihvatio: SD ima smisla samo kao **dorada preko već
zalepljenog neba**, ne kao ono što nebo nalazi ili pravi. Umesto polovičnog
rešenja, funkcija je izvađena cela.

---

## 10. Kako se vraća

1. Pročitati odeljke 3, 4 i 8 — tri greške, zid, i greška u dizajnu.
2. `SKY_ARCHIVE/code/SkyTypes.swift` nazad u `Develop.swift` /
   `DevelopInpaint.swift`.
3. `SKY_ARCHIVE/skies/*.jpg` u `BriefShow/BriefShow/Skies/`.
4. `SKY_ARCHIVE/tools/*` u `Tools/`.
5. `ImageLayer` treba nazad `skyStyle: SkyChoice?` i `isSky: Bool`, sa
   `decodeIfPresent` — i **`SkyChoice` mora na spisak u
   `run-editsettings-decode-test.py`**, inače taj test pada sa
   `cannot find 'SkyChoice' in scope`.
6. Vratiti Select Sky dugme, Change Sky modal i `matchedToScene` poziv.
7. Meriti `run-skymask.py`-em na `~/Desktop/BriefShow RAW Check/2026-09-01/`,
   kadrovi iz tabele u odeljku 4.
