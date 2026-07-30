# HG002 germline WGS with NVIDIA Parabricks

Educational germline analysis of the HG002 reference sample, sequenced on
NovaSeq PCR-free at nominal 40× coverage with consumer Nvidia RTX 3090 GPU.

The pipeline runs automatically:

1. full integrity check and pairing of the FASTQ files;
2. BWA alignment, sorting and duplicate marking;
3. BAM verification and BQSR as a separate process;
4. HaplotypeCaller in gVCF mode, then GenotypeGVCFs;
5. hard filtering, snpEff annotation, WGS QC and an HTML report.

## Project status

Last updated 30 July 2026. **Two complete runs exist, and every figure below is
reported for both.**

| | Iteration 1 | Iteration 2 |
|---|---|---|
| Reference | `Homo_sapiens_assembly38.fasta` (3,366 contigs, 261 `_alt`, no `.alt` file) | `GCA_000001405.15_GRCh38_no_alt_plus_hs38d1` (2,580 contigs, no `_alt`) |
| Run | `20260727_165638` + `20260728_090009` | `20260729_232130_full`, key `53007e55` |
| **SNP F1** | 0.9814 | **0.9921** |
| **INDEL F1** | 0.9837 | **0.9924** |

Iteration 1 is kept intact as the baseline. Nothing about it was overwritten:
prefixes, Docker volumes and benchmark directories are separate.

**What iteration 1 found.** The GIAB benchmark exposed a real defect. SNP recall
came out *lower* than indel recall — 96.97 % against 97.36 % — which is
backwards, because SNPs are the easy case. The cause was traced to ALT contigs
carried without the companion `.alt` file: BWA could not know that a primary
locus and an alternate scaffold were the same place, gave those reads MAPQ 0,
and HaplotypeCaller discarded them below its threshold of 20. Inside the MHC,
recall collapsed to 1.49 %.

**What iteration 2 did about it.** Realigned against the no-ALT analysis set,
one variable changed and nothing else. The plan, its acceptance criteria and its
predictions — written before measuring — are in
[PIANO_ITERAZIONE_2.md](PIANO_ITERAZIONE_2.md). Seven of the nine predictions
held; the two that failed are documented there with the reason, not quietly
dropped.

**The headline result.** SNP recall 96.97 % → **99.26 %**, false negatives
101,963 → **24,740**, and inside the MHC recall goes from 1.49 % to **97.43 %**.
The recall ordering is right again: SNP 99.26 % now above INDEL 99.19 %.

**Also settled in iteration 2:** checkpoint provenance (a reference change now
invalidates checkpoints by construction), the hard-filter question (the SNP
filters cost more than they gain and are now off by default), and the ploidy of
the sex chromosomes (chrX and chrY outside the PAR are re-called haploid; the
11,583 impossible heterozygous calls on chrY are gone).

**What iteration 2 did not fix,** and made easier to see: loss-of-function calls
inside the MHC are artefacts of a linear reference, not biology. See the
limitations.

## Results

Hardware: a Lenovo Legion 5 laptop — AMD Ryzen 5 6600H, 6 cores and 12 threads,
32 GB of system RAM — driving one RTX 3090 (24 GB) through an external PCIe
enclosure, Ubuntu 24.04 under WSL2, Parabricks 4.7.0-1. The host being a laptop
is what sets the 32 GB ceiling and the thread count noted in the limitations,
and it is why the pipeline is built to survive being disconnected from — see
"Operating it remotely" below.

**The host, not the GPU, is the limiter.** Telemetry sampled during alignment on
the iteration-2 run: GPU utilisation 73–83 % while the CPU sat at 97–99 % and
system RAM at 88–90 %. `fq2bam` reports requesting 16 CPU worker threads on a
CPU that has 12. Every conclusion about speed on this machine should be read
with that in mind: the RTX 3090 spends part of its time waiting to be fed.

The card is undervolted to 860 mV, which brings the core temperature during
analysis from 64 °C down to 57 °C. Telemetry sampled mid-alignment on the
iteration-2 run: **58 °C, 191 W against a 350 W limit, SM clock holding
1,785 MHz** — above this card's reference boost, so the undervolt is buying
thermal and power headroom without giving up clock speed. At that same moment
GPU utilisation was 73 % while the host sat at 99 % CPU and 90 % RAM, which
places the bottleneck on the host rather than the GPU. That is the reason the
undervolt costs no wall-clock time here: the GPU already had headroom to spare.

This matters beyond tidiness. A ten-and-a-half-hour run on a consumer card
inside an external enclosure is a sustained thermal load, and roughly halving
the power draw removes heat from a chassis that was never designed to dissipate
350 W.

### Runtime

| Step | Iteration 1 | Iteration 2 | Δ |
|---|---|---|---|
| `fq2bam` (BWA-MEM, sort, mark duplicates) | 2 h 01 m | 2 h 13 m 05 s | **+10.0 %** |
| BQSR | 17 m | 18 m 29 s | **+8.7 %** |
| HaplotypeCaller (gVCF) | 4 h 41 m | 4 h 37 m 58 s | −1.1 % |
| GenotypeGVCFs | 1 m 37 s | 1 m 33 s | −4.1 % |
| Hard filtering | 3 m 12 s | 3 m 07 s | −2.6 % |
| snpEff annotation and PASS+HIGH table | 19 m | 18 m 08 s | −4.6 % |
| WGS QC | 2 h 40 m | 2 h 26 m 32 s | **−8.4 %** |
| Export to `C:` | 30 m | 26 m 02 s | −13.2 % |
| HTML report | 1 m 41 s | 1 m 39 s | −2.0 % |
| **Total measured** | **10 h 34 m** | **10 h 31 m** | **−0.6 %** |

HaplotypeCaller, not alignment, is the bottleneck: on its own it accounts for
44 % of the total.

The two runs cost the same overall, but the distribution moved, and it moved in
a way that explains itself. **Everything downstream of alignment got faster**,
because there are 786 fewer contigs to traverse. The only two steps that got
slower are the two that touch alignment work: `fq2bam`, where reads previously
dumped at MAPQ 0 now have to be genuinely placed and extended, and BQSR, which
consequently has more reads above threshold to model.

That pattern also rules out two alternative explanations for the slowdown. Both
the GPU undervolt and host memory pressure would have slowed *everything*
uniformly. HaplotypeCaller came in 1 % faster, so neither is responsible.

### Coverage

The dataset is published as "40×". That label refers to the coverage expected
after mapping and deduplication, and it is not the number a QC tool reports.
Three different and equally correct figures coexist, so all three are stated
here:

| Coverage | Definition | Iteration 1 | Iteration 2 |
|---|---|---|---|
| Raw | before any exclusion | ≈ 46.6× | ≈ 47.2× |
| Deduplicated | mean DP at variant sites | 40.57× | 40.88× |
| **Effective** | `CollectWgsMetrics`: duplicates, MAPQ < 20, base quality < 20 and overlapping mate bases removed | **35.00×** | **35.69×** |
| Median | | 36× | 37× |
| Bases excluded by Picard | | 24.94 % | 24.40 % |

Breadth over the 2,923,716,080 non-N bases of chr1–22, X and Y — the same
denominator in both runs, since the primary chromosomes are byte-identical
between the two references:

| Run | ≥ 1× | ≥ 10× | ≥ 20× | ≥ 30× |
|---|---|---|---|---|
| Iteration 1 | 96.34 % | 95.03 % | 90.78 % | 78.27 % |
| Iteration 2 | **97.91 %** | **96.75 %** | **92.52 %** | **79.84 %** |

The breadth gain is the ALT fix seen from another angle. The same reads, placed
on primary loci instead of scattered across alternate scaffolds, cover 1.57
percentage points more of the genome at ≥ 1× — roughly 46 Mb that previously
had no coverage at all on the primary assembly.

### Alignment

| Metric | Iteration 1 | Iteration 2 |
|---|---|---|
| Primary reads | 948,769,000 | 948,769,000 |
| Mapped | 99.73 % | 99.72 % |
| Properly paired | 97.85 % | 97.84 % |
| Singletons | 0.17 % | 0.17 % |
| Duplicates | 12.08 % (5,802,003 optical pairs) | 12.19 % (5,859,114 optical pairs) |
| MQ0 reads | 6.49 % | **4.86 %** |

The duplicate rate is dominated by optical duplicates, which is expected on a
NovaSeq patterned flow cell and is not evidence of PCR amplification. That it
barely moves between the two runs is the point: the same library, aligned twice.

MQ0 falls by a quarter but not to zero, and that is correct rather than
disappointing. ALT contigs cover a small share of GRCh38; the residual 4.86 % is
ordinary multi-mapping on repeats, segmental duplications and the 2,385 decoy
contigs that were deliberately kept. Inside the MHC, where the defect actually
lived, MQ0 goes from 91.45 % to 1.57 % and mean MAPQ from 3.4 to 58.4.

### Variants

| Metric | Iteration 1 | Iteration 2 | Δ |
|---|---|---|---|
| Records | 4,953,729 | 5,098,062 | +2.91 % |
| SNP alleles | 4,037,673 | 4,160,768 | **+123,095** |
| Indel and complex alleles | 1,006,658 | 1,030,015 | +23,357 |
| Multiallelic sites | 90,602 | 92,721 | +2.34 % |
| Ti/Tv | 1.928 | 1.929 | +0.001 |
| Heterozygous / homozygous alt | 3,104,375 / 1,849,354 (1.68) | 3,212,050 / 1,886,012 (1.70) | |
| Mean DP | 40.57× | 40.88× | |
| Contigs carrying a variant | 1,913 | 1,689 | −224 |
| Records on `_alt` contigs | present | **0** | |
| PASS and HIGH predicted impact | 613 | 762 | +24.3 % |

Hard filtering annotates the `FILTER` column and removes nothing, so the
filtered VCF still holds every record. This is deliberate: it allows the whole
call set and the PASS-only subset to be benchmarked separately.

Two things in this table are worth pausing on. The SNP gain is close to the
deficit the benchmark had measured (101,963 true SNPs missing), which is what a
correct fix should look like. But **Ti/Tv does not move**, and deriving the
ratio for the added SNPs alone gives roughly 1.95 against the 2.10 of the truth
set — a signal, recorded before the benchmark was run, that part of the gain
would turn out to be false. It did: see below.

### Sample identity

Normalised read density is 0.51 on chrX and 0.44 on chrY relative to the
autosomes, with chrM at 574×. That is the profile of a male sample, which is
what HG002 is.

## GIAB benchmark

Method: `hap.py` v0.3.12 with the `vcfeval` engine (rtgtools 3.10.1), against
NIST HG002 GRCh38 v4.2.1, restricted to the high-confidence BED. The truth set
covers chr1–22 and contains 3,365,127 SNPs and 525,469 indels. Reproduce with
`bash benchmark_giab.sh`.

| Type | Filter | Run | Recall | Precision | F1 | FN | FP |
|---|---|---|---|---|---|---|---|
| INDEL | ALL | iteration 1 | 97.36 % | 99.40 % | 0.9837 | 13,895 | 3,207 |
| INDEL | ALL | **iteration 2** | **99.19 %** | 99.29 % | **0.9924** | **4,238** | 3,867 |
| INDEL | PASS | iteration 1 | 97.34 % | 99.47 % | 0.9839 | 13,993 | 2,865 |
| INDEL | PASS | **iteration 2** | **99.17 %** | 99.38 % | **0.9928** | **4,340** | 3,370 |
| SNP | ALL | iteration 1 | 96.97 % | 99.33 % | 0.9814 | 101,963 | 21,931 |
| SNP | ALL | **iteration 2** | **99.26 %** | 99.16 % | **0.9921** | **24,740** | 28,440 |
| SNP | PASS | iteration 1 | 95.74 % | 99.74 % | 0.9770 | 143,313 | 8,348 |
| SNP | PASS | **iteration 2** | **98.06 %** | 99.61 % | **0.9883** | **65,149** | 12,995 |

Each run's hap.py output lives in its own directory under `reports/giab/`.
Reproduce with `PREFIX=<prefix> bash benchmark_giab.sh`.

### The defect, and what removing it did

In iteration 1 the ordering was backwards. SNPs are the easy case and indels
the hard one, so a pipeline recovering 97.36 % of indels but only 96.97 % of
SNPs was not suffering from a weak variant caller — it was never seeing some of
the data.

Counting false negatives per chromosome located the problem immediately, and
the same count after the fix shows what it was worth:

| Contig | Iteration 1 | Iteration 2 |
|---|---|---|
| **chr6** | 23,093 (**10.39 %**) | 1,425 (**0.64 %**) |
| chr17 | 7,585 (8.80 %) | 630 (0.73 %) |
| chr15 | 6,657 (6.47 %) | 1,543 (1.50 %) |
| chr19 | 3,714 (5.26 %) | 394 (0.56 %) |
| *whole genome* | 101,963 (*3.03 %*) | 24,740 (*0.74 %*) |

chr6, chr17, chr15 and chr19 are precisely the chromosomes carrying the most
ALT scaffolds in GRCh38 — the MHC on chr6 alone has seven alternate haplotypes.
After the fix chr6 goes from the worst chromosome in the genome to one of the
best. The improvement is not confined to ALT-rich chromosomes either: chr1 falls
from 1.64 % to 0.91 % and chr2 from 1.34 % to 0.70 %, because alternate contigs
exist just about everywhere.

Inside `chr6:28,510,120-33,480,577` the truth set holds 20,177 SNPs:

| | Recovered | Missed | Recall |
|---|---|---|---|
| Iteration 1 | 301 | 19,876 | **1.49 %** |
| Iteration 2 | 19,658 | 519 | **97.43 %** |

**The mechanism, stated once.** The iteration-1 reference held 3,366 contigs of
which 261 end in `_alt`, with no `.alt` file beside it and no `AH` tags in the
BAM header. Without that file BWA cannot know a primary locus and an alternate
scaffold are the same place, so it treats the pair as ordinary multi-mapping and
assigns MAPQ 0. HaplotypeCaller discards those reads below its default
mapping-quality threshold of 20, and the variants underneath are never called.
Removing the ALT contigs removes the ambiguity: the reads have one place to go.

**What the fix cost.** Recall did not come free. The 77,223 recovered true
positives arrived with 6,509 new false positives — **11.9 true for every false**
— and SNP precision fell from 99.33 % to 99.16 %. Two signals recorded during
the run had predicted exactly this, before the benchmark ran: the added SNPs
carry a Ti/Tv of about 1.95 rather than the 2.10 of real variation, and the
`QD2` filters grew faster than the record count. The trade is overwhelmingly
worth it, but it is a trade.

**What remains.** F1 0.9921 against the ~0.995 a GATK pipeline should reach at
this depth: most of the gap closed, not all of it. What is left sits in ordinary
repeats and segmental duplications, in the residual 4.86 % of MQ0 reads, and
plausibly in a BQSR known-sites set limited to dbSNP alone.

### The SNP hard filters cost more than they gain — still

Measured on both runs, the answer did not change:

| Type | F1 ALL | F1 PASS | Verdict |
|---|---|---|---|
| SNP, iteration 1 | 0.9814 | 0.9770 | filters cost 0.0044 |
| SNP, iteration 2 | **0.9921** | 0.9883 | filters cost 0.0038 |
| INDEL, iteration 2 | 0.9924 | **0.9928** | filters neutral to marginally useful |

Going from ALL to PASS on SNPs in iteration 2 discards 40,409 true positives to
remove 15,445 false ones: 2.6 good variants lost per error caught, against 3.0
in iteration 1. Marginally less bad, still a bad trade.

**A prediction that failed here.** The plan expected `SNP_MQ40` to stop biting
once MAPQ was no longer artificially depressed. It did not: 207,014 records
tagged in iteration 1, 205,464 in iteration 2, a change of −0.7 %. The reasoning
was wrong in an instructive way. Where the ALT defect struck, MAPQ collapsed to
~3, so HaplotypeCaller discarded the reads and **called nothing at all** — those
sites were absent from the VCF, not filtered out of it. A filter cannot tag a
record that does not exist. The 207,014 tagged records are a different
population entirely: ordinary repeats with intermediate MAPQ, where enough reads
cleared the threshold of 20 to permit a call while the root-mean-square MQ
stayed under 40. Two independent defects, treated as one.

**Consequence.** Since iteration 2 the SNP hard filters are **off by default**
in `scripts/postprocess.sh`; the indel filters stay on. Set
`HG002_SNP_HARD_FILTERS=on` to restore the previous behaviour. Note that the
published iteration-2 artefacts were produced *before* this change, with the
filters still applied — which is why both ALL and PASS numbers exist for it. The
recommended call set is ALL.

## What this call set is, and what it is not

This is a **benchmarked autosomal call set**. The distinction matters, because
the GIAB v4.2.1 truth set covers chr1–22 inside high-confidence regions and
nothing else. Every accuracy figure above is scoped to that, and says nothing
about X, Y, the mitochondrial genome, ALT contigs, decoys or any other
difficult region.

### Sex chromosomes: fixed in iteration 2

The main VCF of both runs was produced with a single diploid ploidy setting
across the whole genome. HG002 is male, so outside the pseudoautosomal regions
chrX and chrY are haploid, and a heterozygous call there is not biologically
meaningful. Both runs are full of them:

| Region | Run | Records | Heterozygous |
|---|---|---|---|
| chrY outside PAR | iteration 1, diploid | 14,891 | 11,608 (**77.95 %**) |
| chrY outside PAR | iteration 2, diploid | 14,865 | 11,583 (**77.92 %**) |
| chrY outside PAR | **iteration 2, ploidy 1** | 6,065 | **0** |
| chrX outside PAR | iteration 1, diploid | 105,679 | 4,017 (3.80 %) |
| chrX outside PAR | iteration 2, diploid | 106,435 | 4,476 (4.21 %) |
| chrX outside PAR | **iteration 2, ploidy 1** | 104,034 | **0** |

Iteration 2 therefore ships a **separate haploid call set** for those regions,
`output/HG002_NovaSeq_40x_53007e55.haploid.vcf.gz`, produced by re-running
HaplotypeCaller with `--ploidy 1` restricted to `chrX:2,781,480-155,701,382` and
`chrY:2,781,480-56,887,902` — the intervals between PAR1 and PAR2 on GRCh38. No
realignment was needed: the existing BAM and BQSR table were reused, and the
whole thing took about twenty minutes.

All 110,099 genotypes in it are haploid and none is heterozygous. On chrY the
record count drops from 14,865 to 6,065, which is the expected shape of the
correction: most of those heterozygous calls were never real variants.

**Two honest caveats.** GIAB v4.2.1 covers chr1–22 only, so this call set is not
benchmarked — it is more defensible on biological grounds, not measured to be
more accurate. And the main VCF still contains the diploid version of these
regions; the haploid file sits beside it rather than replacing it, so that both
remain available for comparison.

**chrM is still not addressed.** It is represented diploid, which is not a
heteroplasmy analysis by any definition. Mitochondrial variant calling needs a
dedicated workflow with its own ploidy model, and none was run. Do not
interpret chrM from this VCF.

None of this affects the autosomal results, which were called, filtered and
benchmarked normally.

## Checkpoint provenance — fixed in iteration 2

The resume logic that saved seven hours after the QC failure was also a trap
waiting for the next iteration, and it had to be dealt with before the
reference was touched.

Checkpoints used to be keyed on a fixed `PREFIX` and `WORK_VOLUME` written into
`run_parabricks_hg002.sh`. Validation checks that a file is structurally sound,
indexed, and carries the expected sample and read group — but nothing bound a
checkpoint to the identity of the FASTQ, the reference, the parameters or the
container image. Swapping in the no-ALT reference while keeping the same volume
and prefix, the old BAM would still validate, alignment would be skipped, and
the pipeline would report `PASS` while returning exactly the results it was
supposed to replace.

Prefix and volumes are now derived from a provenance key: the first eight hex
characters of a SHA-256 over the Parabricks image ID, the SHA-256 of the
reference `.fai`, the name and size of each FASTQ and of the known-sites file,
the read group, and the calling intervals. The `.fai` is the load-bearing
choice — a few kilobytes that change if a single contig of the reference
changes, so the reference is identified without reading its 3 Gb.

Changing any ingredient yields a new prefix and new volumes, so the previous
checkpoints are neither reused by accident nor overwritten. Measured: the
iteration-1 reference produces `97bd8ce8`, the no-ALT reference `dba323b7`, and
two consecutive runs on the same inputs reproduce the same key. Every run also
writes `logs/runs/<id>/run_manifest.json`, which lists the ingredients in
plain text — a hash alone tells you something changed, not what.

The preflight additionally refuses to start on a reference that carries `_alt`
contigs without an `.alt` file beside it. That check costs nothing and would
have caught the MHC defect at minute zero instead of ten hours later.

## The three commands you need

Open PowerShell in the project directory.

Preliminary checks only, no analysis:

```powershell
.\Start-HG002.ps1 -PreflightOnly
```

Small end-to-end trial run:

```powershell
.\Start-HG002.ps1 -SmokeTest
```

Full 40× run:

```powershell
.\Start-HG002.ps1
```

To watch progress, throughput, estimates and resource usage:

```powershell
.\Get-PipelineStatus.ps1 -Watch
```

To stop deliberately:

```powershell
.\Stop-HG002.ps1
```

The pipeline resumes automatically from any checkpoint that passes validation.
A file is never treated as valid merely because it exists.

## Operating it remotely

A full run occupies the machine for ten and a half hours, so most of it happens
while nobody is sitting in front of it. The compute host is reached from a
second laptop over **Tailscale**, a WireGuard mesh VPN, with **OpenSSH** and
**VSCode Remote** on top. `Setup-RemoteAccess.ps1` configures the host side:
sshd on automatic start, the firewall rule, PowerShell as the SSH shell,
key-based authentication with the restrictive ACLs Windows OpenSSH demands, and
the Tailscale install.

The point of Tailscale here is that **no port is ever forwarded on the router**
and SSH is never exposed to the internet. The two machines join a private
network and address each other directly, wherever either of them happens to be.
Port-forwarding RDP or SSH would have been the shorter path and is the one that
gets machines compromised.

This composes with a design decision made for a different reason.
`Start-HG002.ps1` does not run the pipeline in the foreground: it registers a
Windows scheduled task, so the run is independent of any shell, and everything
it prints is teed to `logs/runs/<id>/pipeline.log`. Over a flaky connection that
distinction is the whole ballgame — a dropped link closes a log reader, not a
ten-hour alignment. `Watch-HG002.ps1` reattaches to the log from anywhere, as
many times as needed, read-only.

Two things to keep in mind when working this way:

- **The laptop must not sleep.** The scheduled task is configured with
  `-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries`, but that governs the
  task, not the operating system. On this host the sleep timeout on mains power
  is set to zero, meaning never, so a run on AC is safe; on battery it is five
  hours, which is half a run. The lid-close action is hidden by the OEM power
  profile and has not been confirmed — worth checking before relying on it,
  because nobody is there to reopen the lid.
- **A VSCode Remote session is not free.** The VSCode server and its language
  extensions hold hundreds of megabytes on the host. During `fq2bam` the host
  sits at roughly 90 % of its 32 GB, and an earlier attempt at this pipeline
  already died once with `Cannot allocate memory`. When a heavy step is running,
  a plain `ssh` session tailing the log costs almost nothing; a full editor
  session is the expensive way to read a text file.

## How the code is organised

- `run_parabricks_hg002.sh` — the main recipe;
- `scripts/pipeline_functions.sh` — Docker orchestration, checkpoints and logs;
- `scripts/postprocess.sh` — filtering, annotation and QC metrics;
- `scripts/generate_report.py` — HTML report and JSON summary;
- `benchmark_giab.sh` — accuracy benchmark against the GIAB truth set, run
  separately once the pipeline has finished;
- `scripts/fetch_reference_noalt.sh` — downloads, verifies and prepares the
  no-ALT reference; idempotent and safe to re-run;
- `Start-HG002.ps1` — small Windows launcher that registers the pipeline as a
  scheduled task, so it outlives the shell that started it;
- `Get-PipelineStatus.ps1` — monitor with checkpoints, durations and resources;
- `Watch-HG002.ps1` — follows the live log of the current run, read-only;
- `Stop-HG002.ps1` — controlled shutdown;
- `Setup-RemoteAccess.ps1` — one-off host setup for remote operation: OpenSSH,
  firewall, key authentication and Tailscale;
- `.vscode/tasks.json` — the same monitoring commands as VSCode tasks;
- `docs/parabricks-basic-commands.md` — teaching notes on the two Parabricks
  commands taken individually, runnable against the reduced FASTQ in `smoke/`;
- `docs/data-sources.md` — provenance and download URLs for every input file.

## Why large files are not written straight to C:

An earlier attempt failed during the BQSR rewrite of the BAM with
`Cannot allocate memory`, while writing to a Windows-mounted path. The current
pipeline:

- runs `fq2bam` without integrated BQSR;
- uses `--low-memory`, an 8 GB RAM cap and reduced BWA queues;
- writes the BAM, gVCF and intermediates to a Linux Docker volume;
- releases memory by shutting down the container after each phase;
- computes BQSR separately;
- applies the BQSR report inside HaplotypeCaller;
- copies only validated results to `output/`.

If the export to Windows fails, the valid copy stays in the run's Docker volume
(`hg002_work_<key>`, for example `hg002_work_53007e55`).

## Directories that matter

- `logs/` — current logs and previous attempts;
- `output/` — validated final results;
- `reports/` — HTML and JSON reports;
- `reports/giab/<prefix>/` — hap.py output, one directory per evaluated run, so
  a second benchmark cannot overwrite the first; only the small JSON summary is
  committed;
- `ref/` — the references and their indexes;
- `snpEff_data/` — local hg38 database;
- `smoke/` — small FASTQ files used for the trial run.

The full FASTQ files, the reference, the databases and the outputs must not be
pushed to GitHub. `.gitignore` excludes them. See `docs/data-sources.md` for
where to obtain each of them.

## Stated limitations

- The workstation has 32 GB of RAM, well below the 100 GB NVIDIA officially
  recommends for WGS, and 12 CPU threads against the 16 per GPU Parabricks asks
  for. Splitting the work across separate containers reduces the risk and passed
  the smoke test, but the configuration remains outside the official
  specification on both counts, and the host is the measured bottleneck.
- The GPU is undervolted to 860 mV. No stock-voltage control run was performed,
  so the runtimes published here are the undervolted ones and are not directly
  comparable to a reference 3090. An unstable undervolt would normally announce
  itself as a driver fault or an Xid error, which aborts the run rather than
  corrupting it quietly; the GIAB benchmark is the check that would surface a
  silent compute error, and precision stayed at 99.3–99.5 %. That is
  reassurance, not proof.
- BQSR uses the dbSNP set included in the project; this is not the complete
  known-sites bundle from the Broad Best Practices.
- The snpEff hg38 database does not recognise some decoy/alt contigs of
  assembly38. The pipeline keeps those records, quantifies the limitation in the
  report, and does not present them as annotated.
- ~~The reference carries ALT contigs without the `.alt` file.~~ Fixed in
  iteration 2, which is the whole point of that iteration. The cost it had been
  imposing, now measured on both sides: 3.03 % of true SNPs missed genome-wide
  → 0.74 %, 10.39 % on chr6 → 0.64 %, and 98.51 % inside the MHC → 2.57 %.
- **Residual MQ0 is 4.86 %, and that is not a defect to fix.** It is ordinary
  multi-mapping on repeats, segmental duplications and the 2,385 decoy contigs
  that were kept deliberately. Only the ALT-driven share was ever recoverable
  this way.
- Ti/Tv is 1.929 across the whole iteration-2 call set, which mixes in contigs
  the truth set cannot judge. Inside the GIAB scope it is 1.9591 for ALL and
  2.0254 for PASS against 2.10 in the truth set. In iteration 1 the gap was
  driven by missing true SNPs; now that most of those have been recovered and
  the ratio has barely moved, the remaining gap points at false positives in
  hard regions instead. Precision is 99.16 %.
- ~~The SNP hard filters reduce F1 rather than improve it, and are left
  unchanged until the reference problem is fixed.~~ Re-measured on iteration 2
  and confirmed: they still cost 0.0038 of F1. They are now **off by default**;
  `HG002_SNP_HARD_FILTERS=on` restores them. The published iteration-2 artefacts
  predate this switch, so both ALL and PASS numbers exist for them.
- The "40×" in the dataset name is the publisher's label, not a measurement.
  The effective coverage measured is 35.00× in iteration 1 and 35.69× in
  iteration 2; see Results for the definitions and how they reconcile.
- The benchmarked call set is autosomal: GIAB v4.2.1 covers chr1–22 inside
  high-confidence regions and nothing else. Every accuracy figure is scoped to
  that and says nothing about X, Y, chrM, decoys or any other difficult region.
- ~~X and Y were called with a global diploid ploidy; 72.41 % of PASS records on
  chrY are heterozygous.~~ Fixed in iteration 2 by a separate haploid call set
  for the non-PAR intervals: 0 heterozygous genotypes out of 110,099. It is not
  benchmarked, because GIAB does not cover the sex chromosomes — more defensible
  biologically, not measured to be more accurate. chrM remains unaddressed and
  must not be interpreted.
- ~~Checkpoints are not bound to input hashes, so a reference change alone does
  not invalidate them.~~ Fixed in iteration 2: prefix and volumes derive from a
  provenance key over image, reference, FASTQ, known-sites, read group and
  intervals. See the provenance section above.
- The PASS + HIGH list — 613 records in iteration 1, 762 in iteration 2 — is a
  technical shortlist with no genotype threshold applied. `PASS` plus predicted
  `HIGH` impact means the site passed the filters and the effect predictor
  expects a large consequence. It does not mean pathogenic, and no ACMG/AMP
  classification was performed. The list grew by 24.3 % while the record count
  grew by 2.9 %, and the next bullet explains where that came from.
- **Loss-of-function calls inside the MHC are not interpretable on a linear
  reference.** The iteration-2 run makes this concrete and quantified: once the
  MHC is no longer blind, it contributes 48 PASS + HIGH records where the
  baseline had none, concentrated in HLA-DRB1 (28), HLA-DRB5 (14), MICA (10),
  HLA-A, HLA-B and HLA-DQB1 — predicted as 45 frameshifts, 12 stop-gains and 13
  splice-site variants. Their technical quality is good (mean DP 36.2, mean GQ
  83.5), which is exactly what makes them misleading. GRCh38 carries one
  arbitrary HLA haplotype; HG002's real alleles differ from it so much that the
  caller describes the divergence as a pile of loss-of-function events. HLA
  requires dedicated typing tools, or a pangenome reference that contains the
  alternate haplotypes instead of forcing reads onto one. See
  [PIANO_ITERAZIONE_2.md](PIANO_ITERAZIONE_2.md) §8.4.
- snpEff 5.1d with the 2020 hg38 database is adequate as a technical control
  and out of date for anything resembling interpretation.
- Hard filters and snpEff are technical controls, not clinical interpretation.
