# HG002 germline WGS with NVIDIA Parabricks

Educational germline analysis of the HG002 reference sample, sequenced on
NovaSeq PCR-free at nominal 40× coverage, on a eGPU Nvidia RTX 3090 linked to Lenovo Legion 5 ARH7H laptop with its internal RTX 3060 disabled.

The pipeline runs automatically: integrity check and pairing of the FASTQ files,
BWA alignment with sorting and duplicate marking, BAM verification, BQSR as a
separate process, HaplotypeCaller in gVCF mode, GenotypeGVCFs, hard filtering,
snpEff annotation, WGS QC and an HTML report.

## Project status

Last updated 30 July 2026. **Two complete runs exist, and the figures below are
reported for both.**

| | Iteration 1 | Iteration 2 |
|---|---|---|
| Reference | `Homo_sapiens_assembly38.fasta` — 3,366 contigs, 261 `_alt`, no `.alt` file | `GCA_000001405.15_GRCh38_no_alt_plus_hs38d1` — 2,580 contigs, no `_alt` |
| Provenance key | `97bd8ce8` | `53007e55` |
| **SNP F1** | 0.9814 | **0.9921** |
| **INDEL F1** | 0.9837 | **0.9924** |

Iteration 1 is kept intact as the baseline: prefixes, Docker volumes and
benchmark directories are separate, and nothing about it was overwritten.

**What iteration 1 found.** SNP recall came out *lower* than indel recall —
96.97 % against 97.36 % — which is backwards, because SNPs are the easy case.
The cause was ALT contigs carried without the companion `.alt` file. Inside the
MHC, recall collapsed to 1.49 %.

**What iteration 2 did.** Realigned against the no-ALT analysis set, one
variable changed and nothing else. The plan, its acceptance criteria and its
predictions — written before measuring — are in
[PIANO_ITERAZIONE_2.md](PIANO_ITERAZIONE_2.md). Seven of nine predictions held;
the two that failed are documented there with the reason.

SNP recall 96.97 % → **99.26 %**, false negatives 101,963 → **24,740**, MHC
recall 1.49 % → **97.43 %**. The recall ordering is right again: SNP above
INDEL.

Also settled in iteration 2: checkpoint provenance, the hard-filter question,
and the ploidy of the sex chromosomes.

## Results

Hardware: a Lenovo Legion 5 ARH7H laptop — AMD Ryzen 5 6600H, 6 cores and 12
threads, 32 GB of RAM — linked to one RTX 3090 (24 GB) via OcuLink through an external PCIe
dock, with the internal RTX 3060 disabled preventing conflicts.

Software:Ubuntu 24.04 under WSL2, Parabricks 4.7.0-1.

**The CPU, not the GPU, is the limiter.** During alignment the GPU sits at
73–83 % while the CPU is at 97–99 % and RAM at 88–90 %; `fq2bam` asks for 16
CPU worker threads on a CPU that has 12. That constraint is the reason for
`--low-memory`, the 8 GB cap and the separate container per phase.

### Runtime

| Step | Iteration 1 | Iteration 2 |
|---|---|---|
| `fq2bam` | 2 h 01 m | 2 h 13 m |
| BQSR | 17 m | 18 m 29 s |
| HaplotypeCaller (gVCF) | 4 h 41 m | 4 h 38 m |
| GenotypeGVCFs | 1 m 37 s | 1 m 33 s |
| Hard filtering | 3 m 12 s | 3 m 07 s |
| snpEff annotation | 19 m | 18 m 08 s |
| WGS QC | 2 h 40 m | 2 h 26 m |
| Export to `C:` | 30 m | 26 m 02 s |
| HTML report | 1 m 41 s | 1 m 39 s |
| **Total** | **10 h 34 m** | **10 h 31 m** |

The two runs cost the same overall, but everything downstream of alignment got
faster — 786 fewer contigs to traverse — while the two steps that touch
alignment work got slower, because reads previously dumped at MAPQ 0 now have
to be genuinely placed.

### Coverage

| Coverage | Definition | Iteration 1 | Iteration 2 |
|---|---|---|---|
| Raw | before any exclusion | ≈ 46.6× | ≈ 47.2× |
| Deduplicated | mean DP at variant sites | 40.57× | 40.88× |
| **Effective** | `CollectWgsMetrics`, after removing duplicates, MAPQ < 20, base quality < 20 and overlapping mate bases | **35.00×** | **35.69×** |

Breadth over the 2,923,716,080 non-N bases of chr1–22, X and Y — the same
denominator in both runs, since the primary chromosomes are identical between
the two references:

| Run | ≥ 1× | ≥ 10× | ≥ 20× | ≥ 30× |
|---|---|---|---|---|
| Iteration 1 | 96.34 % | 95.03 % | 90.78 % | 78.27 % |
| Iteration 2 | **97.91 %** | **96.75 %** | **92.52 %** | **79.84 %** |

The gain at ≥ 1× is roughly 46 Mb that previously had no coverage at all on the
primary assembly, because those reads were scattered across alternate scaffolds.

### Alignment

| Metric | Iteration 1 | Iteration 2 |
|---|---|---|
| Primary reads | 948,769,000 | 948,769,000 |
| Mapped | 99.73 % | 99.72 % |
| Properly paired | 97.85 % | 97.84 % |
| Duplicates | 12.08 % | 12.19 % |
| MQ0 reads | 6.49 % | **4.86 %** |

The duplicate rate is dominated by optical duplicates, expected on a NovaSeq
patterned flow cell and not evidence of PCR amplification.

MQ0 falls by a quarter but not to zero, and that is correct: ALT contigs cover a
small share of GRCh38, and the residual is ordinary multi-mapping on repeats and
on the 2,385 decoy contigs that were deliberately kept. Inside the MHC, where
the defect lived, MQ0 goes from 91.45 % to 1.57 %.

### Variants

| Metric | Iteration 1 | Iteration 2 |
|---|---|---|
| Records | 4,953,729 | 5,098,062 |
| SNP alleles | 4,037,673 | 4,160,768 (**+123,095**) |
| Indel and complex alleles | 1,006,658 | 1,030,015 |
| Ti/Tv | 1.928 | 1.929 |
| Heterozygous / homozygous alt | 3,104,375 / 1,849,354 | 3,212,050 / 1,886,012 |
| Records on `_alt` contigs | present | **0** |
| PASS and HIGH predicted impact | 613 | 762 |

Hard filtering annotates the `FILTER` column and removes nothing, so both the
whole call set and the PASS subset can be benchmarked separately.

Note that **Ti/Tv does not move**. Deriving the ratio for the added SNPs alone
gives roughly 1.95 against the 2.10 of the truth set — a signal, recorded before
the benchmark was run, that part of the gain would turn out to be false.

## GIAB benchmark

`hap.py` v0.3.12 with the `vcfeval` engine, against NIST HG002 GRCh38 v4.2.1,
restricted to the high-confidence BED. The truth set covers chr1–22 and contains
3,365,127 SNPs and 525,469 indels. Each run's output lives in its own directory
under `reports/giab/`; reproduce with `PREFIX=<prefix> bash benchmark_giab.sh`.

| Type | Filter | Run | Recall | Precision | F1 | FN |
|---|---|---|---|---|---|---|
| SNP | ALL | iteration 1 | 96.97 % | 99.33 % | 0.9814 | 101,963 |
| SNP | ALL | **iteration 2** | **99.26 %** | 99.16 % | **0.9921** | **24,740** |
| SNP | PASS | iteration 2 | 98.06 % | 99.61 % | 0.9883 | 65,149 |
| INDEL | ALL | iteration 1 | 97.36 % | 99.40 % | 0.9837 | 13,895 |
| INDEL | ALL | **iteration 2** | **99.19 %** | 99.29 % | **0.9924** | **4,238** |
| INDEL | PASS | iteration 2 | 99.17 % | 99.38 % | 0.9928 | 4,340 |

### The defect, and what removing it did

False negatives per chromosome, before and after:

| Contig | Iteration 1 | Iteration 2 |
|---|---|---|
| **chr6** | 23,093 (**10.39 %**) | 1,425 (**0.64 %**) |
| chr17 | 7,585 (8.80 %) | 630 (0.73 %) |
| chr15 | 6,657 (6.47 %) | 1,543 (1.50 %) |
| chr19 | 3,714 (5.26 %) | 394 (0.56 %) |
| *whole genome* | 101,963 (*3.03 %*) | 24,740 (*0.74 %*) |

chr6, chr17, chr15 and chr19 carry the most ALT scaffolds in GRCh38 — the MHC on
chr6 alone has seven alternate haplotypes. After the fix chr6 goes from the worst
chromosome in the genome to one of the best, and the improvement is not confined
to ALT-rich chromosomes: chr1 falls from 1.64 % to 0.91 %.

Inside `chr6:28,510,120-33,480,577` the truth set holds 20,177 SNPs:

| | Recovered | Missed | Recall |
|---|---|---|---|
| Iteration 1 | 301 | 19,876 | **1.49 %** |
| Iteration 2 | 19,658 | 519 | **97.43 %** |

**The mechanism.** The iteration-1 reference held 261 contigs ending in `_alt`
with no `.alt` file beside it. Without that file BWA cannot know a primary locus
and an alternate scaffold are the same place, so it treats the pair as ordinary
multi-mapping and assigns MAPQ 0. HaplotypeCaller discards those reads below its
default threshold of 20, and the variants underneath are never called. Removing
the ALT contigs removes the ambiguity: the reads have one place to go.

**What the fix cost.** 77,223 recovered true positives arrived with 6,509 new
false positives — 11.9 true for every false — and SNP precision fell from
99.33 % to 99.16 %. An overwhelmingly good trade, but a trade.

**What remains.** F1 0.9921 against the ~0.995 a GATK pipeline should reach at
this depth. What is left sits in ordinary repeats and segmental duplications, in
the residual MQ0, and plausibly in a BQSR known-sites set limited to dbSNP alone.

### The SNP hard filters cost more than they gain

| Type | F1 ALL | F1 PASS |
|---|---|---|
| SNP, iteration 1 | 0.9814 | 0.9770 |
| SNP, iteration 2 | **0.9921** | 0.9883 |
| INDEL, iteration 2 | 0.9924 | **0.9928** |

On SNPs, going from ALL to PASS discards 40,409 true positives to remove 15,445
false ones. Since iteration 2 the SNP hard filters are **off by default** in
`scripts/postprocess.sh`; the indel filters stay on. Set
`HG002_SNP_HARD_FILTERS=on` to restore the previous behaviour. The published
iteration-2 artefacts predate this change, which is why both ALL and PASS numbers
exist for them. **The recommended call set is ALL.**

A prediction failed here, and it is instructive. The plan expected `SNP_MQ40` to
stop biting once MAPQ was no longer depressed. It did not: 207,014 records tagged
before, 205,464 after. Where the ALT defect struck, HaplotypeCaller called
nothing at all — those sites were absent from the VCF, not filtered out of it,
and a filter cannot tag a record that does not exist. Two independent defects had
been treated as one.

## What this call set is, and what it is not

This is a **benchmarked autosomal call set**. GIAB v4.2.1 covers chr1–22 inside
high-confidence regions and nothing else, so every accuracy figure is scoped to
that and says nothing about X, Y, chrM, ALT contigs or decoys.

### Sex chromosomes

The main VCF of both runs was produced with a single diploid ploidy across the
whole genome. HG002 is male, so outside the pseudoautosomal regions chrX and chrY
are haploid and a heterozygous call there is not biologically meaningful:

| Region | Run | Records | Heterozygous |
|---|---|---|---|
| chrY outside PAR | iteration 2, diploid | 14,865 | 11,583 (**77.92 %**) |
| chrY outside PAR | **iteration 2, ploidy 1** | 6,065 | **0** |
| chrX outside PAR | iteration 2, diploid | 106,435 | 4,476 (4.21 %) |
| chrX outside PAR | **iteration 2, ploidy 1** | 104,034 | **0** |

Iteration 2 therefore ships a separate haploid call set,
`output/HG002_NovaSeq_40x_53007e55.haploid.vcf.gz`, from re-running
HaplotypeCaller with `--ploidy 1` on the intervals between PAR1 and PAR2. No
realignment was needed. All 110,099 genotypes in it are haploid and none is
heterozygous.

It is **not benchmarked**, because GIAB does not cover the sex chromosomes: more
defensible biologically, not measured to be more accurate. The main VCF still
carries the diploid version, so both remain available.

**chrM is not addressed.** It is represented diploid, which is not a heteroplasmy
analysis by any definition. Do not interpret chrM from this VCF.

## Checkpoint provenance

Checkpoints used to be keyed on a fixed `PREFIX` and `WORK_VOLUME`. Validation
checks that a file is structurally sound and carries the expected sample, but
nothing bound it to the identity of the inputs: swapping in a new reference, the
old BAM would still validate, alignment would be skipped, and the pipeline would
report `PASS` while returning exactly the results it was supposed to replace.

Prefix and volumes are now derived from a provenance key — the first eight hex
characters of a SHA-256 over the Parabricks image ID, the SHA-256 of the
reference `.fai`, the name and size of each FASTQ and of the known-sites file,
the read group and the calling intervals. The `.fai` is the load-bearing choice:
a few kilobytes that change if a single contig changes, so the reference is
identified without hashing three gigabytes.

Changing any ingredient yields a new prefix and new volumes, so previous
checkpoints are neither reused by accident nor overwritten. Every run also writes
`logs/runs/<id>/run_manifest.json` listing the ingredients in plain text — a hash
tells you that something changed, not what.

The preflight additionally refuses to start on a reference carrying `_alt`
contigs without an `.alt` file beside it. That check costs nothing and would have
caught the MHC defect at minute zero instead of ten hours in.

## The commands you need

Open PowerShell in the project directory.

```powershell
.\Start-HG002.ps1 -PreflightOnly    # checks only, no analysis
.\Start-HG002.ps1 -SmokeTest        # end-to-end trial, about 6 minutes
.\Start-HG002.ps1                   # full run, about 10 h 30 m
.\Watch-HG002.ps1                   # follow the live log, read-only
.\Get-PipelineStatus.ps1 -Watch     # checkpoints, durations, resources
.\Stop-HG002.ps1                    # controlled shutdown
```

The pipeline resumes automatically from any checkpoint that passes validation. A
file is never treated as valid merely because it exists — see
[docs/pipeline-validation-20260725.md](docs/pipeline-validation-20260725.md),
where deliberately truncated copies are rejected.

`Start-HG002.ps1` registers a Windows scheduled task rather than running in the
foreground, so a run survives the terminal closing and the network dropping. That
matters because the machine is normally driven remotely, over Tailscale with
OpenSSH and VSCode Remote; `Setup-RemoteAccess.ps1` configures the host side.
`Watch-HG002.ps1` only reads the log, so `Ctrl+C` detaches the reader and leaves
the analysis running.

## How the code is organised

- `run_parabricks_hg002.sh` — the main recipe;
- `scripts/pipeline_functions.sh` — Docker orchestration, checkpoints, provenance;
- `scripts/postprocess.sh` — filtering, annotation and QC metrics;
- `scripts/generate_report.py` — HTML report and JSON summary;
- `scripts/fetch_reference_noalt.sh` — downloads and verifies the no-ALT reference;
- `benchmark_giab.sh` — accuracy benchmark, run separately;
- `Start-HG002.ps1`, `Stop-HG002.ps1`, `Get-PipelineStatus.ps1`,
  `Watch-HG002.ps1`, `Setup-RemoteAccess.ps1` — Windows-side launcher, shutdown,
  monitor, log follower and one-off remote-access setup;
- `docs/data-sources.md` — provenance and download URLs for every input file.

Large intermediates are written to a Linux Docker volume rather than to `C:`: an
early attempt died with `Cannot allocate memory` writing to a Windows-mounted
path. Only validated results are copied to `output/`. The FASTQ files, the
reference, the databases and the outputs are excluded by `.gitignore`; see
`docs/data-sources.md` for where to obtain each of them.

## Stated limitations

- The workstation has 32 GB of RAM against the 100 GB NVIDIA recommends for WGS,
  and 12 CPU threads against the 16 per GPU Parabricks asks for. The
  configuration is outside the official specification on both counts, and the
  host is the measured bottleneck.
- BQSR uses the dbSNP set included in the project, not the complete known-sites
  bundle from the Broad Best Practices.
- The residual 4.86 % of MQ0 reads is ordinary multi-mapping on repeats and
  decoys, not a defect left unfixed.
- Ti/Tv inside the GIAB scope is 1.9591 for ALL against 2.10 in the truth set.
  In iteration 1 that gap was driven by missing true SNPs; now that most have
  been recovered and the ratio has barely moved, it points at false positives in
  hard regions instead.
- The "40×" in the dataset name is the publisher's label, not a measurement. The
  effective coverage is 35.00× in iteration 1 and 35.69× in iteration 2.
- The PASS + HIGH list — 613 records in iteration 1, 762 in iteration 2 — is a
  technical shortlist with no genotype threshold applied. It does not mean
  pathogenic, and no ACMG/AMP classification was performed.
- **Loss-of-function calls inside the MHC are not interpretable on a linear
  reference.** Once the MHC is no longer blind it contributes 48 PASS + HIGH
  records where the baseline had none, concentrated in HLA-DRB1, HLA-DRB5, MICA,
  HLA-A, HLA-B and HLA-DQB1, predicted as frameshifts, stop-gains and splice-site
  variants. Their technical quality is good, which is exactly what makes them
  misleading: GRCh38 carries one arbitrary HLA haplotype, and HG002's real alleles
  differ from it so much that the caller describes the divergence as a pile of
  loss-of-function events. HLA requires dedicated typing tools, or a pangenome
  reference. See [PIANO_ITERAZIONE_2.md](PIANO_ITERAZIONE_2.md) §8.4.
- The snpEff hg38 database does not recognise the decoy contigs, and snpEff 5.1d
  with the 2020 database is adequate as a technical control and out of date for
  anything resembling interpretation.
- Hard filters and snpEff are technical controls, not clinical interpretation.
