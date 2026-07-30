# Piano dell'iterazione 2 — HG002 / Parabricks

Documento operativo. Descrive tutte le fasi della seconda iterazione, cosa
comprende ognuna, quanto costa e come si verifica che sia riuscita.

Redatto il 29 luglio 2026. Baseline di riferimento: la run completa del
27–28 luglio 2026 (`logs/runs/20260727_165638_full` e
`logs/runs/20260728_090009_full`), i cui risultati sono in `output/`,
`reports/HG002_NovaSeq_40x_summary.json` e `reports/giab/`.

---

## 1. Da dove si parte

La prima iterazione è **completa e valida**: nove step su nove `PASS` su
474.384.500 coppie di read, e un benchmark contro NIST HG002 v4.2.1 che ha
prodotto F1 0,9837 sugli indel e 0,9814 sugli SNP dentro il BED ad alta
confidenza.

Lo stesso benchmark ha però messo in luce tre difetti reali, tutti documentati
in `README.md` e nel capitolo 10 della dispensa v2.

### Difetto 1 — contig ALT senza file `.alt` (il più grave)

Il riferimento `Homo_sapiens_assembly38.fasta` contiene **3.366 contig**, di cui
**261 terminano in `_alt`** e **525 sono contig HLA**. Accanto al FASTA **non
esiste** `Homo_sapiens_assembly38.fasta.alt`, e l'header del BAM non porta tag
`AH`.

Senza quel file BWA non sa che un contig ALT e il locus primario corrispondente
descrivono lo stesso pezzo di genoma: tratta il doppio allineamento come
multi-mapping ordinario e assegna **MAPQ 0**. HaplotypeCaller scarta tutto ciò
che sta sotto MAPQ 20. Le varianti sottostanti non vengono mai chiamate.

Conseguenze misurate:

| Misura | Valore |
|---|---|
| Read con MAPQ 0 | 61,4 milioni (6,5 %) |
| SNP veri persi, genoma intero | 101.963 (3,03 %) |
| SNP veri persi su chr6 | 23.093 (**10,39 %**) |
| SNP veri persi in `chr6:28.510.120-33.480.577` (MHC) | 19.876 su 20.177 (**98,51 %**) |
| Profondità media nell'MHC | 7,64× contro 35× genome-wide |
| Quota dei falsi negativi di chr6 dovuta al solo MHC | 86,1 % |

Il segnale diagnostico è l'ordine invertito delle recall: 97,36 % sugli indel
contro 96,97 % sugli SNP. Gli SNP sono il caso facile. Se vanno peggio degli
indel, il problema non è il variant caller: è che i dati non arrivano.

### Difetto 2 — i filtri hard sugli SNP peggiorano l'F1

Passando da `ALL` a `PASS`, sugli SNP si perdono **41.350 veri positivi** per
eliminarne **13.583 falsi**: tre varianti buone buttate per ogni errore preso.
L'F1 scende da 0,9814 a 0,9770. Sugli indel gli stessi filtri sono neutri
(0,9837 → 0,9839).

Il filtro dominante è `SNP_MQ40`, cioè una soglia sulla mapping quality:
**la stessa grandezza che il difetto 1 deprime artificialmente**. I due difetti
si compongono — il riferimento abbassa la MAPQ, poi il filtro cancella ciò che
era sopravvissuto.

### Difetto 3 — ploidia diploide su chrX, chrY e chrM

HaplotypeCaller è stato eseguito con una sola impostazione di ploidia,
diploide, su tutto il genoma. HG002 è maschile: fuori dalle regioni
pseudoautosomiche chrX e chrY sono aploidi. Nel VCF ci sono **10.740 record
PASS su chrY, di cui 7.777 eterozigoti (72,41 %)**, che è biologicamente
impossibile. chrM è rappresentato diploide, e questo non è un'analisi di
eteroplasmia sotto nessuna definizione.

### Falso allarme già escluso — l'eccesso di indel

Il rapporto SNP/indel del call set (4,01) è più basso di quello del truth set
(6,40), e sembra un eccesso di indel. Dentro le regioni ad alta confidenza però
il rapporto è **6,13 contro 6,40**: quasi normale. L'eccesso sta **fuori** da
quelle regioni — il 41,8 % delle chiamate indel cade dove GIAB non giudica,
contro il 13,7 % degli SNP.

Quelle zone sono ripetizioni, omopolimeri, contig alt e decoy: GIAB le esclude
proprio perché difficili. Il 6,40 del truth set **non è il rapporto biologico
reale**, è il rapporto in un genoma ripulito dalle zone dove gli indel
abbondano. Resta una quota di falsi positivi indel di GATK negli omopolimeri,
ma non è il difetto principale e non giustifica un cambio di variant caller.

---

## 2. Due regole che valgono per tutte le fasi

**Una variabile alla volta.** L'iterazione 2 cambia il riferimento e nient'altro.
Filtri, BQSR, snpEff, known-sites e parametri restano identici. Così ogni
differenza nei risultati è attribuibile con certezza a una causa sola. I filtri
si ridiscutono dopo, sui dati nuovi, senza rieseguire niente.

**La baseline è intoccabile.** La run del 27–28 luglio è il termine di
confronto. Non va sovrascritta, non va spostata, non va "aggiornata". Vale per
`output/`, per `reports/` e per il volume Docker `hg002_work_v1`.

---

## 3. Le fasi

### Fase 0 — Provenance dei checkpoint

**Perché blocca tutto il resto.** La logica di ripresa che ha salvato sette ore
dopo il crash del QC è una trappola alla prossima iterazione. I checkpoint sono
indicizzati su un `PREFIX` e un `WORK_VOLUME` scritti a mano nello script. La
validazione controlla che un file sia strutturalmente sano, indicizzato e con
il sample e il read group giusti — ma niente lega un checkpoint all'identità
dei FASTQ, del riferimento, dei parametri o dell'immagine del container.

Cambiando riferimento senza toccare prefisso e volume, il vecchio BAM
**passerebbe la validazione**, l'allineamento verrebbe saltato, e la pipeline
riporterebbe `PASS` restituendo esattamente i risultati che doveva sostituire.

**Cosa comprende.**

1. Una funzione `compute_run_key()` che calcola una chiave da otto caratteri
   esadecimali a partire dagli ingredienti che determinano il risultato:
   ID dell'immagine Parabricks, SHA-256 del `.fai` del riferimento, nome e
   dimensione dei due FASTQ, nome e dimensione del known-sites, read group,
   intervalli di calling. Il `.fai` è la scelta chiave: pochi KB, e cambia se
   cambia anche un solo contig del riferimento.
2. `PREFIX`, `WORK_VOLUME` e `TMP_VOLUME` derivati da quella chiave. Cambiare
   riferimento produce automaticamente prefisso e volumi nuovi: i vecchi
   checkpoint non vengono più trovati e allo stesso tempo **non vengono
   distrutti**.
3. Un `run_manifest.json` in chiaro nella cartella della run, che elenca tutti
   gli ingredienti della chiave. Un hash da solo non è verificabile: serve
   poter leggere cosa ci è entrato.
4. Il riferimento diventa una variabile (`REF_NAME`, sovrascrivibile con
   `HG002_REF_NAME`) invece di un percorso scritto a mano in quattro file
   diversi. L'elenco dei file obbligatori del preflight viene derivato da essa.
5. Il controllo di integrità dei FASTQ resta riutilizzabile: dipende solo dai
   FASTQ, non dal riferimento, e rifarlo costerebbe ore per nulla.

**File toccati.** `run_parabricks_hg002.sh`, `scripts/pipeline_functions.sh`,
`scripts/postprocess.sh`, `benchmark_giab.sh`.

**Costo.** Nessun calcolo GPU.

**Criterio di accettazione.** Con il riferimento vecchio la chiave riproduce un
prefisso stabile fra due invocazioni consecutive; cambiando `HG002_REF_NAME` la
chiave cambia; `--preflight` passa in entrambi i casi.

---

### Fase 1 — Riferimento senza contig ALT

**Cosa comprende.**

1. Download da NCBI di `GCA_000001405.15_GRCh38_no_alt_plus_hs38d1_analysis_set.fna`,
   del suo `.fai` pubblicato e degli **indici BWA già costruiti** (`bwa index`
   su 3 Gb costerebbe circa un'ora di CPU per un risultato identico).
2. Verifica MD5 contro `md5checksums.txt` di NCBI.
3. Rigenerazione del `.fai` con `samtools faidx` e confronto con quello
   pubblicato: se coincidono, il FASTA è integro riga per riga.
4. Creazione del dizionario `.dict`, che GATK e Parabricks pretendono.
5. **Diff dei contig** contro il riferimento attuale, con verifica esplicita che
   i cromosomi primari non cambino né nome né lunghezza — è la condizione per
   cui dbSNP, snpEff e il BED di GIAB restano compatibili senza modifiche.

**Perché la variante `no_alt_plus_hs38d1`.** Ce ne sono quattro. Questa cambia
una sola cosa rispetto ad oggi: toglie i contig ALT e gli HLA che dipendono da
loro, e **tiene i decoy**. I decoy servono: sono un cestino che assorbe le read
spazzatura che altrimenti si appiccicherebbero ai cromosomi veri creando falsi
positivi. Il riferimento attuale li ha, e toglierli insieme agli ALT
significherebbe muovere due variabili invece di una.

**Costo.** Circa 4 GB di download. Nessun calcolo GPU.

**Criterio di accettazione.** Contig da 3.366 a 2.580, con 786 rimossi
(261 `_alt` + 525 HLA) e nessuno aggiunto; lunghezze di chr1, chr6, chr20,
chrX, chrY e chrM invariate.

**Script.** `scripts/fetch_reference_noalt.sh`, rieseguibile e idempotente.

---

### Fase 2 — Smoke test sul riferimento nuovo

**Perché.** Serve a scoprire in un quarto d'ora, e non dopo dieci ore, se il
`.dict` è sbagliato, se il known-sites non combacia, se GATK rifiuta
l'estensione `.fna`, se snpEff protesta. È esattamente il motivo per cui lo
smoke test esiste.

**Cosa comprende.** La pipeline completa a nove step su un milione di coppie di
read (`smoke/HG002_NovaSeq_smoke_R1/R2.fastq.gz`), con calling ristretto a
`chr20:1-1.000.000`. Volume e prefisso nuovi, derivati dalla chiave della
fase 0.

**Costo.** Circa 15 minuti.

**Criterio di accettazione.** Nove step `PASS`, BAM e VCF validati, report HTML
generato, e nessun riutilizzo di checkpoint appartenenti al riferimento vecchio.

---

### Fase 3 — Run completo

**Cosa comprende.** La pipeline sui 474.384.500 coppie di read completi, con
riferimento nuovo e **tutto il resto identico**: stessi filtri hard, stessa
BQSR, stessi flag `--bwa-options=-Y --low-memory --memory-limit 8
--bwa-normalized-queue-capacity 2 --gpuwrite`.

**Costo.** Circa 10 h 40 m, così ripartite secondo la baseline: fq2bam 2 h 01,
BQSR 17 m, HaplotypeCaller 4 h 41, GenotypeGVCFs 1 m 37, hard filtering 3 m 12,
snpEff 19 m, QC WGS 2 h 40, esportazione 30 m, report 1 m 41.

**Spazio.** 612 GB liberi su `C:` e 952 GB nel disco Linux: il BAM nuovo occupa
circa 86 GB e la baseline va conservata. C'è margine, ma il `.vhdx` di WSL
cresce in parallelo e va tenuto d'occhio.

**Criterio di accettazione.** Nove step `PASS`, e nel manifest della run una
chiave diversa da quella della baseline.

---

### Fase 4 — Benchmark e verifica delle predizioni

**Cosa comprende.**

1. `bash benchmark_giab.sh` sul nuovo VCF, contro lo stesso truth set NIST
   v4.2.1 e lo stesso BED ad alta confidenza.
2. Ricalcolo dei falsi negativi per cromosoma.
3. Ricalcolo mirato su `chr6:28.510.120-33.480.577`, che è il punto dove la
   diagnosi si conferma o cade.
4. Conteggio delle read MAPQ 0 nel BAM nuovo.

**Le predizioni vanno scritte prima di misurare.** Sono queste, e sono
inferenze, non misure:

| Metrica | Baseline | Attesa |
|---|---|---|
| Read con MAPQ 0, genoma intero | 6,49 % | ~4,9 % — **predizione corretta il 29/07, vedi sotto** |
| Read con MAPQ 0 **dentro l'MHC** | 91,45 % | 1–2 % |
| Profondità nell'MHC | 7,64× | ~35×, in linea col genoma |
| Recall SNP nell'MHC | 1,49 % | > 95 % |
| SNP persi su chr6 | 10,39 % | ~2 %, in linea col resto |
| Recall SNP genome-wide | 96,97 % | ~99 % |
| F1 SNP (ALL) | 0,9814 | 0,993–0,995 |
| Ordine delle recall | indel > SNP | SNP > indel |

> **Predizione corretta.** La prima stesura di questo piano prevedeva che le
> read a MAPQ 0 scendessero dal 6,5 % all'1–2 % **sull'intero genoma**. Lo
> smoke test della fase 2 mostra 4,86 %, e quella previsione era sbagliata.
> Il motivo: i contig ALT coprono una frazione piccola di GRCh38, quindi il
> MAPQ 0 che dipende da loro è solo un quarto del totale. Il resto è
> multi-mapping ordinario su ripetizioni, duplicazioni segmentali e sui 2.385
> decoy, che è fisiologico e non un difetto.
>
> La metrica diagnostica giusta non è il MAPQ 0 globale ma quello **dentro
> l'MHC**, dove il difetto è concentrato. Là la riduzione misurata è enorme, e
> la riga è stata aggiunta alla tabella.

Se l'ordine delle recall si raddrizza, la diagnosi era giusta ed è dimostrata.
Se **non** si raddrizza, c'era anche altro, e saperlo vale comunque la fase. In
entrambi i casi il risultato si pubblica.

**Costo.** Circa un'ora, quasi tutta di `vcfeval`.

---

### Fase 5 — Ridecidere i filtri hard

**Cosa comprende.** Confronto di tre scenari sui numeri nuovi: nessun filtro,
filtri attuali, filtri senza `SNP_MQ40`. La decisione si prende sull'F1
misurato, non per convenzione.

**Non serve rieseguire niente.** Le curve ROC che hap.py produce già
(`reports/giab/happy.roc.Locations.SNP.csv.gz` e l'equivalente per gli indel)
contengono precision e recall a ogni soglia possibile. Il VCF hard-filtered
conserva tutti i record e annota solo la colonna `FILTER`, quindi ogni
sottoinsieme è ricavabile a posteriori.

**Ipotesi da testare — falsificata il 30 luglio 2026.** Avevo scritto che, tolto
il difetto a monte, `SNP_MQ40` avrebbe smesso di mordere da solo, perché la MAPQ
non sarebbe più stata depressa artificialmente. **È sbagliato.** Misurato sul VCF
hard-filtered della fase 3:

| Filtro | Baseline | Iterazione 2 | Delta |
|---|---|---|---|
| `SNP_MQ40` | 207.014 | 205.464 | **−0,7 %** |
| `SNP_SOR3` | 71.572 | 74.153 | +3,6 % |
| `SNP_QD2` | 46.312 | 50.428 | +8,9 % |
| `INDEL_QD2` | 4.448 | 4.954 | +11,4 % |
| quota PASS | 94,38 % | 94,44 % | +0,06 % |

Il ragionamento sbagliato stava nell'assumere che i record marcati da
`SNP_MQ40` fossero gli stessi che il difetto ALT danneggiava. Non lo erano.

Dove il difetto ALT colpiva — l'MHC in testa — la MAPQ crollava a ~3, quindi
HaplotypeCaller scartava le read *sotto la propria soglia di 20* e **non
chiamava alcuna variante**. Quei siti non comparivano nel VCF, e perciò non
potevano nemmeno essere marcati da un filtro. Erano assenti, non filtrati.
Dopo la correzione la loro MAPQ media è ~58, quindi vengono chiamati **e**
passano `MQ ≥ 40` senza essere sfiorati dal filtro.

I 207.014 record marcati da `SNP_MQ40` sono una popolazione diversa: siti in
ripetizioni e duplicazioni segmentali ordinarie, con MAPQ intermedia, dove
abbastanza read superavano la soglia 20 da permettere una chiamata ma la MQ
quadratica media restava sotto 40. Quelle regioni non c'entrano con i contig
ALT, e infatti il MAPQ 0 residuo genome-wide è ancora 4,86 %.

**Conseguenza per questa fase.** La domanda «i filtri SNP costano più di quanto
rendano?» resta **aperta e va decisa su hap.py**, non su questi conteggi. È
però probabile che la risposta non sia cambiata, perché la popolazione bersaglio
del filtro dominante non è cambiata: nella baseline i filtri costavano 41.350
veri positivi per rimuoverne 13.583 falsi.

Nota di cautela nella direzione opposta: `SNP_QD2` (+8,9 %) e `INDEL_QD2`
(+11,4 %) crescono più dei record totali (+2,91 %). QD è la qualità normalizzata
sulla profondità, e più marcature significano più siti con supporto marginale —
coerente con il Ti/Tv degli SNP aggiunti, intorno a 1,95 invece del 2,10 atteso
per varianti tutte vere. Una parte del guadagno sarà falsa. Quanto, lo dice la
fase 4.

**Deciso il 30 luglio 2026, sui numeri della fase 4.** I filtri hard sugli SNP
continuano a costare più di quanto rendano, esattamente come nella baseline:

| Tipo | F1 ALL | F1 PASS | Verdetto |
|---|---|---|---|
| SNP | **0,9921** | 0,9883 | ALL vince: i filtri tolgono 0,0038 di F1 |
| INDEL | 0,9924 | **0,9928** | PASS vince di un soffio: filtri neutri |

Passando da ALL a PASS sugli SNP si perdono 40.409 veri positivi per rimuoverne
15.445 falsi: **2,6 buoni per ogni errore preso**, contro i 3,0 della baseline.
Marginalmente meno peggio, ma sempre un cattivo affare — ed è esattamente ciò
che l'analisi del meccanismo prevedeva, visto che la popolazione bersaglio del
filtro dominante non è cambiata.

**Raccomandazione: disattivare i filtri hard sugli SNP, mantenere quelli sugli
indel.** In alternativa, sostituirli con soglie ricavate dalle curve ROC invece
che dalle soglie storiche di GATK, tarate su dati e profondità diversi da questi.

**Costo.** Nessun calcolo GPU.

---

### Fase 6 — Ploidia di chrX, chrY e chrM

**Cosa comprende.** Ri-chiamata di HaplotypeCaller **solo** sugli intervalli
aploidi con `--ploidy 1`, escludendo le regioni pseudoautosomiche che restano
diploidi, e sostituzione di quei record nel VCF finale. chrM va dichiarato non
analizzato: l'eteroplasmia richiede un workflow dedicato, e presentarlo
diploide è peggio che ometterlo.

**Costo.** Circa 30 minuti, perché gli intervalli sono piccoli. Non richiede di
rifare l'allineamento.

**Criterio di accettazione.** Zero genotipi eterozigoti su chrY fuori dalle PAR.

---

### Fase 7 — Aggiornamento della documentazione

**Cosa comprende.** `README.md` e dispensa v2 aggiornati con due colonne
affiancate, prima e dopo. Il valore didattico del progetto non sta nel numero
finale: sta nel ciclo completo — un difetto trovato con un benchmark, spiegato
con un meccanismo, corretto, e la correzione verificata contro una predizione
dichiarata in anticipo.

Va aggiornata anche la sezione dei limiti: quelli risolti vanno spostati nello
storico, non cancellati.

---

## 4. Riassunto

| Fase | Che cosa | Costo | Blocca |
|---|---|---|---|
| 0 | Provenance dei checkpoint | codice | tutto il resto |
| 1 | Riferimento no-ALT | ~4 GB di download | fase 2 |
| 2 | Smoke test | ~15 min | fase 3 |
| 3 | Run completo | ~10 h 40 m | fase 4 |
| 4 | Benchmark e predizioni | ~1 h | fasi 5 e 7 |
| 5 | Filtri hard, ridecisi | nessuno | fase 7 |
| 6 | Ploidia X/Y/M | ~30 min | fase 7 |
| 7 | Documentazione | scrittura | — |

Percorso critico: **fase 0 (mezza giornata) → fasi 1-2 (un'ora e mezza) →
fase 3 (una notte) → fasi 4-5 (una mattina)**. Le fasi 6 e 7 non hanno
vincoli di orario.

---

## 5. Cosa non facciamo, e perché

**DeepVariant.** Escluso per scelta. Non risolverebbe comunque il difetto 1: il
danno avviene nell'allineatore, e un variant caller legge solo ciò che
l'allineatore ha scritto. DeepVariant filtra anch'esso per mapping quality
(default `min_mapping_quality = 5`), quindi le read a MAPQ 0 le scarta
ugualmente. Aiuterebbe sui difetti 2 e 3, ma introdurrebbe un problema nuovo di
onestà del benchmark: i suoi modelli WGS sono addestrati su HG001–HG007 escluso
HG003, cioè **HG002 è nel training set**. Un confronto genome-wide su HG002
sarebbe truccato in suo favore, e l'unico confronto pulito sarebbe ristretto a
chr20–22, i soli cromosomi sempre esclusi dall'addestramento.

**Abbassare la soglia di MAPQ di HaplotypeCaller** per recuperare l'MHC senza
riallineare. Chiamerebbe varianti da read genuinamente in posizione incerta:
recall recuperata e pagata in falsi positivi. È truccare il numero, non
risolvere il problema.

**Aggiungere il file `.alt` al riferimento attuale.** In teoria è la strada
alt-aware corretta. In pratica il supporto in `pbrun fq2bam` cambia fra le
versioni di Parabricks e `bwa-postalt.js` andrebbe eseguito come passo separato
fuori da Parabricks. Più fragile e meno verificabile del riferimento no-ALT, per
lo stesso risultato.

**Il pangenoma** (`pangenome_germline` di Parabricks 4.7: Giraffe su GPU più
pangenome-aware DeepVariant). Attaccherebbe il problema alla radice, perché il
riferimento contiene le varianti alternative invece di doverle indovinare. Ma
richiede il grafo HPRC e più RAM di quanta ce ne sia. Resta un'ipotesi per
un'iterazione 3, non per questa.

**Cambiare snpEff, known-sites e riferimento nella stessa run.** Sono tutti
miglioramenti sensati. Insieme rendono il confronto illeggibile.

---

## 6. Stato

- [x] Fase 0 — provenance dei checkpoint · 29 luglio 2026
- [x] Fase 1 — riferimento no-ALT · 29 luglio 2026
- [x] Fase 2 — smoke test · 29 luglio 2026
- [x] Fase 3 — run completo · 30 luglio 2026, 10 h 55 m, nove step `PASS`
- [x] Fase 4 — benchmark e predizioni · 30 luglio 2026, F1 SNP 0,9921
- [x] Fase 5 — filtri hard · 30 luglio 2026: disattivati per default sugli SNP
      in `scripts/postprocess.sh`, mantenuti sugli indel, ripristinabili con
      `HG002_SNP_HARD_FILTERS=on`
- [x] Fase 6 — ploidia X/Y · 30 luglio 2026: call set aploide separato per le
      regioni fuori PAR, 110.099 genotipi, zero eterozigoti. **chrM resta
      esplicitamente non affrontato**
- [x] Fase 7 — documentazione · 30 luglio 2026: README con le due iterazioni
      affiancate

---

## 7. Esito verificato delle fasi 0, 1 e 2

Eseguite il 29 luglio 2026. Ogni numero qui viene da un file del progetto.

### Fase 0

Prefisso e volumi derivano dalla chiave di provenance. Tre collaudi superati:

| Collaudo | Esito |
|---|---|
| Riferimento con `_alt` e senza `.alt` | la pipeline **rifiuta** di partire |
| Con `HG002_ALLOW_ALT_WITHOUT_ALT_FILE=1` | preflight superato, con avviso |
| Due invocazioni identiche | stessa chiave, `97bd8ce8` |
| Cambio di riferimento | chiave diversa, `dba323b7` |

Il manifest in chiaro viene scritto in `logs/runs/<id>/run_manifest.json`. Il
volume della baseline `hg002_work_v1` (91,1 GB) è intatto.

Aggiunto anche il controllo che nell'iterazione 1 mancava: il preflight blocca
un riferimento che porta contig `_alt` senza il file `.alt` accanto.

### Fase 1

| Criterio | Atteso | Misurato |
|---|---|---|
| Contig totali | 2.580 | 2.580 |
| Contig `_alt` | 0 | 0 |
| Contig HLA | 0 | 0 |
| Decoy conservati | 2.385 | 2.385 |
| Contig aggiunti | 0 | 0 |
| MD5 NCBI | corrispondenti | FASTA e indici OK |
| `.fai` rigenerato | identico al pubblicato | identico |
| `.dict` | 2.580 sequenze | 2.580 |

Rimossi 786 contig: 261 `_alt` più i 525 HLA che dipendono da loro. Nomi e
lunghezze di chr1, chr6, chr10, chr20, chrX, chrY e chrM invariati, quindi
dbSNP, snpEff e il BED di GIAB restano validi senza modifiche.

### Fase 2

Nove step, tredici esecuzioni contando i controlli, tutte `PASS` in **5 m 54 s**
(`logs/runs/20260729_230546_smoke`). Nessun checkpoint del riferimento vecchio
riutilizzato: `2_fq2bam` ha girato davvero.

Header del BAM: 2.580 `@SQ`, zero `_alt`, zero HLA, 2.385 decoy. Il report HTML
dichiara il riferimento effettivamente usato invece di una stringa scritta a
mano.

**Il rischio tecnico principale è superato:** Parabricks 4.7 accetta il
riferimento con estensione `.fna` e gli indici BWA pubblicati da NCBI, senza
bisogno di ricostruirli.

### Prima prova che la correzione funziona

Lo smoke test usa il primo milione di coppie di read, distribuite su tutto il
genoma, quindi il MAPQ è già confrontabile. Stesso input, unica differenza il
riferimento:

| Regione | Riferimento | Read | MQ0 | MQ0 % | MAPQ medio |
|---|---|---|---|---|---|
| **MHC** `chr6:28,5–33,5 Mb` | con ALT | 538 | 492 | **91,45 %** | 3,4 |
| **MHC** `chr6:28,5–33,5 Mb` | no-ALT | **3.499** | 55 | **1,57 %** | **58,4** |
| chr20 intero (controllo) | con ALT | 45.475 | 2.558 | 5,63 % | 55,3 |
| chr20 intero (controllo) | no-ALT | 45.657 | 2.428 | 5,32 % | 55,5 |
| genoma intero | con ALT | 1.994.995 | 129.569 | 6,49 % | — |
| genoma intero | no-ALT | 1.994.892 | 96.931 | 4,86 % | — |

Tre cose da leggere in questa tabella.

**Nell'MHC il meccanismo è confermato.** Il MAPQ medio passa da 3,4 a 58,4 e le
read a MAPQ 0 dal 91,45 % all'1,57 %. Soprattutto, il locus primario riceve
**6,5 volte più read** (538 → 3.499): con il riferimento vecchio quelle read
finivano spalmate sui sette aplotipi alternativi dell'MHC invece che sul locus
vero. È esattamente la catena causale descritta nel capitolo 1.

**Su chr20 non cambia nulla**, come deve essere. La correzione agisce dove
c'era il difetto e non altera il resto: le 12 varianti chiamate su
`chr20:1-1.000.000` sono identiche nelle due run, Ti/Tv compreso.

**Il MAPQ 0 globale scende poco** perché i contig ALT coprono una frazione
piccola del genoma. Questo ha falsificato una predizione di questo piano, che è
stata corretta nella fase 4 invece di essere fatta passare come indovinata.

Restano non verificate, e lo saranno solo dopo la fase 3, le metriche che
richiedono profondità piena e il confronto con il truth set: recall nell'MHC,
recall genome-wide, F1 e ordine fra SNP e indel.

---

## 8. Fase 3 — che cosa si è visto durante la run

Run `20260729_232130_full`, chiave di provenance `53007e55`. Osservazioni
raccolte mentre la pipeline girava, prima del benchmark. **Nessun numero qui è
una misura di accuratezza**: quella arriva dalla fase 4.

### 8.1 Tempi: lo scarto è dove il riferimento cambia il lavoro

| Step | Baseline | Iterazione 2 | Delta |
|---|---|---|---|
| `fq2bam` | 2 h 01 m | 2 h 13 m 05 s | **+9,8 %** |
| BQSR | 17 m | 18 m 29 s | **+8,7 %** |
| HaplotypeCaller | 4 h 41 m | 4 h 37 m 58 s | **−1,1 %** |
| **cumulativo** | 6 h 59 m | 7 h 09 m | +2,5 % |

Tre ipotesi erano in campo per lo scarto iniziale: più lavoro utile,
l'undervolt della GPU, la pressione di memoria sull'host. Le ultime due
predicevano un rallentamento **uniforme**, perché agiscono su tutto. Il dato di
HaplotypeCaller le scagiona: lo scarto è concentrato dove la rimozione dei
contig ALT cambia la quantità di lavoro — l'allineamento decide dove va ogni
read, la BQSR modella più read sopra soglia — e sparisce dove non la cambia.

Su HaplotypeCaller i due effetti si compensano: 786 contig in meno da
attraversare tirano verso il basso, le regioni prima cieche che ora generano
ActiveRegion vere tirano verso l'alto.

### 8.2 Call set: +123.095 alleli SNP

| Metrica | Baseline | Iterazione 2 | Delta |
|---|---|---|---|
| Record | 4.953.729 | 5.098.062 | +144.333 (+2,91 %) |
| Alleli SNP | 4.037.673 | 4.160.768 | **+123.095 (+3,05 %)** |
| Alleli indel/complex | 1.006.658 | 1.030.015 | +23.357 (+2,32 %) |
| Eterozigoti | 3.104.375 | 3.212.050 | +107.675 (+3,47 %) |
| Omozigoti alt | 1.849.354 | 1.886.012 | +36.658 (+1,98 %) |
| Ti/Tv | 1,928 | 1,929 | +0,001 |
| DP medio | 40,57 | 40,88 | +0,31 |
| Record su contig `_alt` | — | 0 | atteso 0 |
| Contig con varianti | 1.913 | 1.689 | −224 |

Il guadagno è dello stesso ordine del deficit misurato dal benchmark della
baseline (101.963 SNP veri mancanti nel BED ad alta confidenza) e la sua
composizione è quella attesa: gli SNP crescono più degli indel, perché il
difetto ALT costava soprattutto SNP; gli eterozigoti crescono più degli
omozigoti, perché un sito eterozigote con un allele uguale al riferimento è
invisibile finché non c'è copertura.

Nella finestra dell'MHC gli SNP chiamati passano da **301 a 28.766**. Il numero
non va letto come recall: comprende chiamate fuori dal BED ad alta confidenza, e
l'MHC ne è largamente escluso proprio perché difficile.

**Segnale prudenziale.** Il Ti/Tv complessivo non si muove. Ricavando dai totali
il Ti/Tv dei soli SNP aggiunti si ottiene circa **1,95** — sopra l'1,93 del set
esistente, sotto il 2,10 del truth set. È un valore derivato da un rapporto
arrotondato, quindi con incertezza di qualche centesimo, ma la direzione è
chiara: una parte del guadagno non è vera.

### 8.3 Filtri hard: ipotesi falsificata

Vedi la fase 5. In sintesi: `SNP_MQ40` è immobile (−0,7 %), perché i siti che il
difetto ALT danneggiava **non erano filtrati, erano assenti**. `SNP_QD2`
(+8,9 %) e `INDEL_QD2` (+11,4 %) crescono più dei record totali, seconda
conferma che una parte delle nuove chiamate ha supporto marginale.

### 8.4 Il risultato più importante: l'MHC è stato recuperato, ma su un riferimento che non può rappresentarlo

I record `PASS` con impatto previsto `HIGH` passano da **613 a 762 (+149)**,
cioè +24,3 % contro un +2,91 % di record totali. Non è distribuito:

| Contig | Baseline | Iterazione 2 | Delta |
|---|---|---|---|
| **chr6** | 16 | 64 | **+48** |
| chr19 | 40 | 65 | +25 |
| chr3 | 43 | 59 | +16 |
| chr11 | 42 | 57 | +15 |

**Tutti e 48 i nuovi record di chr6 cadono dentro `chr6:28.510.120-33.480.577`,
dove la baseline ne aveva zero.** L'MHC occupa 5 Mb, lo 0,16 % del genoma, e da
solo produce il 32 % dell'incremento: un arricchimento di circa 200 volte.

I geni coinvolti non lasciano dubbi su cosa stia succedendo:

| Gene | Record | | Gene | Record |
|---|---|---|---|---|
| HLA-DRB1 | 28 | | HLA-DQB1 | 6 |
| HLA-DRB5 | 14 | | HLA-B | 6 |
| MICA | 10 | | HLA-A | 6 |
| CCHCR1 | 9 | | TAP2 | 3 |
| TCF19 | 6 | | MUC21, OR12D1, PSORS1C1/2, HLA-J | 1–4 |

Gli effetti previsti sono 45 `frameshift_variant`, 12 `stop_gained`, 7
`splice_acceptor_variant`, 6 `splice_donor_variant`, 3 `stop_lost`. Una pila di
perdite di funzione nei geni HLA classici.

**E la qualità tecnica è buona:** DP medio 36,2 in linea con i 35× genome-wide,
GQ medio 83,5, solo 4 siti con DP < 10 e 3 con GQ < 30. Il variant caller è
sicuro di sé.

Ed è proprio questo il punto. **Tecnicamente solide, biologicamente prive di
senso come perdite di funzione.** HLA-DRB1, HLA-DRB5, HLA-A, HLA-B e HLA-DQB1
sono i geni più polimorfici del genoma umano, con migliaia di alleli noti che
differiscono fra loro per decine di sostituzioni e inserzioni. Il primary
assembly di GRCh38 ne porta **un solo aplotipo arbitrario**. Gli alleli HLA
reali di HG002 differiscono da quel template così tanto che allineatore e caller
descrivono la differenza come una sequenza di frameshift e codoni di stop. Il
frameshift non è nella biologia di HG002: è nel riferimento, che è il template
sbagliato.

Il caso di HLA-DRB5 è il più istruttivo: DRB5 esiste soltanto su alcuni aplotipi
DR. Read provenienti da DRB1, paralogo identico per oltre il 90 %, si accumulano
sul locus di riferimento di DRB5 e producono nonsenso. Rimuovere i contig ALT
**favorisce** questo effetto, perché a quelle read non resta nessun altro posto
dove andare. Anche il genotipo `1/2` su HLA-A a chr6:29.943.463 è un indizio
diretto: un sito multiallelico dove entrambi gli aplotipi del campione
differiscono dal riferimento.

**Tre conseguenze.**

1. La correzione ha fatto quello che doveva: l'MHC non è più cieco. Questo
   resta un successo, e il benchmark della fase 4 lo quantificherà.
2. Il benchmark **non penalizzerà** questi 48 record, perché l'MHC è in gran
   parte fuori dal BED ad alta confidenza. F1 potrà migliorare mentre quei
   record restano artefatti. Un miglioramento di F1 non è una promozione della
   scorciatoia `PASS + HIGH`.
3. La lista `PASS + HIGH` va letta con una cautela in più, ora quantificata:
   48 record su 762, il 6,3 %, stanno nell'MHC e sono con ogni probabilità
   divergenza dal riferimento, non perdita di funzione. Per l'HLA servono
   strumenti dedicati di tipizzazione, non variant calling su riferimento
   lineare, oppure un riferimento pangenomico che contenga gli aplotipi
   alternativi invece di costringerli su uno solo.

È l'argomento più forte a favore dell'ipotesi pangenoma per un'eventuale
iterazione 3, e arriva da una misura, non da una preferenza.

### 8.6 Fase 4 — il benchmark

`hap.py` v0.3.12 con motore `vcfeval`, truth set NIST HG002 GRCh38 v4.2.1,
ristretto al BED ad alta confidenza. Risultati in
`reports/giab/HG002_NovaSeq_40x_53007e55/`.

| Tipo | Filtro | Metrica | Baseline | Iterazione 2 | Delta |
|---|---|---|---|---|---|
| SNP | ALL | Recall | 96,97 % | **99,26 %** | **+2,29 pp** |
| SNP | ALL | Precision | 99,33 % | 99,16 % | −0,18 pp |
| SNP | ALL | **F1** | 0,9814 | **0,9921** | **+0,0107** |
| SNP | ALL | Falsi negativi | 101.963 | **24.740** | **−75,7 %** |
| SNP | ALL | Falsi positivi | 21.931 | 28.440 | +29,7 % |
| INDEL | ALL | Recall | 97,36 % | **99,19 %** | **+1,84 pp** |
| INDEL | ALL | Precision | 99,40 % | 99,29 % | −0,11 pp |
| INDEL | ALL | **F1** | 0,9837 | **0,9924** | **+0,0088** |
| INDEL | ALL | Falsi negativi | 13.895 | **4.238** | **−69,5 %** |

**L'ordine delle recall si è raddrizzato.** Nella baseline gli indel (97,36 %)
battevano gli SNP (96,97 %), che è al contrario di come dovrebbe essere. Ora
SNP 99,26 % contro indel 99,19 %: gli SNP tornano il caso facile. Era la
predizione principale del piano ed è confermata.

**L'MHC.** Recall degli SNP dentro `chr6:28.510.120-33.480.577`:

| | Veri | Recuperati | Persi | Recall |
|---|---|---|---|---|
| Baseline | 20.177 | 301 | 19.876 | **1,49 %** |
| Iterazione 2 | 20.177 | 19.658 | 519 | **97,43 %** |

**Falsi negativi per cromosoma**, i quattro più colpiti dal difetto:

| Contig | Baseline | Iterazione 2 |
|---|---|---|
| chr6 | 23.093 (10,39 %) | 1.425 (**0,64 %**) |
| chr17 | 7.585 (8,80 %) | 630 (**0,73 %**) |
| chr15 | 6.657 (6,47 %) | 1.543 (1,50 %) |
| chr19 | 3.714 (5,26 %) | 394 (**0,56 %**) |
| **genoma** | 101.963 (3,03 %) | **24.740 (0,74 %)** |

chr6 passa da peggiore cromosoma del genoma a uno dei migliori. Il
miglioramento non è confinato ai cromosomi ricchi di ALT: anche chr1 scende
dall'1,64 % allo 0,91 % e chr2 dall'1,34 % allo 0,70 %, perché contig
alternativi ne esistono un po' ovunque.

### 8.7 Le predizioni, verificate una per una

| Predizione | Attesa | Misurato | Esito |
|---|---|---|---|
| MAPQ 0 genome-wide | ~4,9 % (corretta) | 4,86 % | **giusta** |
| MAPQ 0 nell'MHC | 1–2 % | 1,57 % | **giusta** |
| Recall SNP nell'MHC | > 95 % | 97,43 % | **giusta** |
| SNP persi su chr6 | ~2 % | 0,64 % | **giusta**, anzi meglio |
| Recall SNP genome-wide | ~99 % | 99,26 % | **giusta** |
| Ordine SNP > indel | sì | sì | **giusta** |
| Parte del guadagno è falsa | sì | +6.509 FP | **giusta** |
| F1 SNP (ALL) | 0,993–0,995 | 0,9921 | **sbagliata**, ottimistica |
| `SNP_MQ40` smette di mordere | sì | −0,7 % | **sbagliata** (vedi fase 5) |

Sette su nove. Le due sbagliate restano scritte, con il motivo.

**Il costo in precisione, quantificato.** Il guadagno porta 77.223 veri positivi
in più e 6.509 falsi positivi in più: **11,9 veri per ogni falso**. I due
segnali prudenziali raccolti durante la run — Ti/Tv degli SNP aggiunti intorno
a 1,95 e filtri `QD2` in crescita — indicavano correttamente che una parte del
guadagno era falsa, e il benchmark dice quanto: poca.

**Quel che resta.** F1 0,9921 contro lo ~0,995 che una pipeline GATK dovrebbe
raggiungere a questa profondità. Il grosso del divario è chiuso, non tutto.
Restano sul tavolo le duplicazioni segmentali ordinarie, il MAPQ 0 residuo al
4,86 %, e un known-sites di BQSR limitato al solo dbSNP.

### 8.5 Annotazione: nessun miglioramento, come non previsto

I record su contig che il database snpEff non riconosce passano da 45.177 a
45.734. In proporzione ai record totali scendono appena, dallo 0,912 % allo
0,897 %. Mi aspettavo un calo netto, avendo rimosso 786 contig: sbagliato, perché
quei record sono dominati dai 2.385 decoy, che sono stati **deliberatamente
conservati**. La limitazione dichiarata nel README resta valida così com'è.
