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

Last updated 28 July 2026.

- **Full run completed.** All nine steps finished with `PASS` on the complete
  474,384,500 read pairs. Every figure in the section below comes from that run
  (`logs/runs/20260727_165638_full` and `logs/runs/20260728_090009_full`).
- **The run took two sessions, on purpose.** The first attempt reached step 8 of
  9 and failed there: Picard `CollectWgsMetrics` was left on its default
  `READ_LENGTH` of 150 while the reads are 151 bp, which triggers an
  `ArrayIndexOutOfBoundsException` in the fast collector. The alignment and
  variant calling were untouched by this. After the fix the pipeline resumed
  from the validated checkpoints and recomputed only the QC step — no BAM and no
  VCF had to be produced twice. The step now reads the real length from
  `samtools stats` and falls back to the standard collector if the fast one
  fails again.
- **GIAB benchmark: done.** Measured against the NIST HG002 v4.2.1 truth set,
  restricted to the high-confidence BED: F1 0.984 on indels and 0.981 on SNPs.
  The benchmark also exposed a real defect in the current setup, described in
  full below — the SNP recall is about one point lower than it should be, and
  the cause is identified.
- **Next: re-run against the no-ALT analysis set.** The fix is understood and
  costs roughly seven hours of compute. It has not been done yet, so every
  number published here still comes from the ALT-carrying reference.

## Results

Hardware: one RTX 3090 (24 GB) over an external PCIe enclosure, 32 GB of system
RAM, Ubuntu 24.04 under WSL2, Parabricks 4.7.0-1.

### Runtime

| Step | Duration |
|---|---|
| `fq2bam` (BWA-MEM, sort, mark duplicates) | 2 h 01 m |
| BQSR | 17 m |
| HaplotypeCaller (gVCF) | 4 h 41 m |
| GenotypeGVCFs | 1 m 37 s |
| Hard filtering | 3 m 12 s |
| snpEff annotation and PASS+HIGH table | 19 m |
| WGS QC | 2 h 40 m |
| Export of 98 GB to `C:` | 30 m |
| HTML report | 1 m 41 s |
| **Total compute time** | **≈ 10 h 40 m** |

HaplotypeCaller, not alignment, is the bottleneck: on its own it accounts for
44 % of the total.

### Coverage

The dataset is published as "40×". That label refers to the coverage expected
after mapping and deduplication, and it is not the number a QC tool reports.
Three different and equally correct figures coexist, so all three are stated
here:

| Coverage | Definition |
|---|---|
| ≈ 46.6× | raw, before any exclusion |
| ≈ 41× | after deduplication (mean DP at variant sites: 40.57×) |
| **35.0×** | effective, as reported by `CollectWgsMetrics`: duplicates, MAPQ < 20, base quality < 20 and overlapping mate bases all removed |

The arithmetic closes: Picard excludes 24.93 % of bases in total, and
35.0 / (1 − 0.2493) = 46.6×. Median coverage is 36×.

Breadth over the 2,923,716,080 non-N bases of chr1–22, X and Y:

| ≥ 1× | ≥ 10× | ≥ 20× | ≥ 30× |
|---|---|---|---|
| 96.34 % | 95.03 % | 90.78 % | 78.27 % |

### Alignment

| Metric | Value |
|---|---|
| Primary reads | 948,769,000 |
| Mapped | 99.73 % |
| Properly paired | 97.85 % |
| Singletons | 0.17 % |
| Duplicates | 12.05 % (5,802,003 optical read pairs) |
| Insert size | 410 ± 171 bp |
| Error rate | 0.58 % |
| Mean base quality | 35.5 |

The duplicate rate is dominated by optical duplicates, which is expected on a
NovaSeq patterned flow cell and is not evidence of PCR amplification.

### Variants

| Metric | Value |
|---|---|
| Records | 4,953,729 |
| SNP alleles | 4,037,673 |
| Indel and complex alleles | 1,006,658 |
| Multiallelic sites | 90,602 |
| Ti/Tv | 1.928 |
| Heterozygous / homozygous alternate | 3,104,375 / 1,849,354 (1.68) |
| Passing the hard filters | 4,675,118 (94.4 %) |
| PASS and HIGH predicted impact | 613 |

Hard filtering annotates the `FILTER` column and removes nothing, so the
filtered VCF still holds every record. This is deliberate: it allows the whole
call set and the PASS-only subset to be benchmarked separately.

### Sample identity

Normalised read density is 0.51 on chrX and 0.44 on chrY relative to the
autosomes, with chrM at 574×. That is the profile of a male sample, which is
what HG002 is.

## GIAB benchmark

Method: `hap.py` v0.3.12 with the `vcfeval` engine (rtgtools 3.11), against
NIST HG002 GRCh38 v4.2.1, restricted to the high-confidence BED. The truth set
covers chr1–22 and contains 3,365,127 SNPs and 525,469 indels. Reproduce with
`bash benchmark_giab.sh`.

| Type | Filter | Recall | Precision | F1 | FN | FP |
|---|---|---|---|---|---|---|
| INDEL | ALL | 97.36 % | 99.40 % | **0.9837** | 13,895 | 3,207 |
| INDEL | PASS | 97.34 % | 99.47 % | **0.9839** | 13,993 | 2,865 |
| SNP | ALL | 96.97 % | 99.33 % | **0.9814** | 101,963 | 21,931 |
| SNP | PASS | 95.74 % | 99.74 % | **0.9770** | 143,313 | 8,348 |

Indels are where they should be for GATK at this coverage, and precision is
high everywhere: the pipeline is not inventing variants. The interesting part
is what the numbers say about what it misses.

### The SNP recall is lower than the indel recall

That ordering is backwards. SNPs are the easy case and indels the hard one, so
a pipeline that recovers 97.36 % of indels but only 96.97 % of SNPs is not
suffering from a weak variant caller — it is never seeing some of the data. An
F1 of 0.981 on SNPs sits about one point below the ~0.995 a GATK pipeline
should reach at 35×.

Counting the false negatives per chromosome locates the problem immediately:

| Contig | FN | Share of true variants missed |
|---|---|---|
| **chr6** | 23,093 | **10.39 %** |
| chr17 | 7,585 | 8.80 % |
| chr15 | 6,657 | 6.47 % |
| chr19 | 3,714 | 5.26 % |
| *whole genome* | 101,963 | *3.03 %* |

One SNP in ten is missed on chr6, three and a half times the genome average.
chr6, chr17, chr15 and chr19 are precisely the chromosomes carrying the most
ALT scaffolds in GRCh38 — the MHC region on chr6 alone has seven alternate
haplotypes.

The cause follows from that. `Homo_sapiens_assembly38.fasta` includes the ALT
contigs, but the accompanying `.alt` file is absent and no alt-aware
post-processing is performed. Reads that map equally well to a primary locus
and to an alternate scaffold are given MAPQ 0, HaplotypeCaller discards them
below its default mapping-quality threshold of 20, and the variants underneath
are never called. This is consistent with the 61.4 million MQ0 reads (6.5 %)
seen in the alignment statistics.

The fix is to align against
`GCA_000001405.15_GRCh38_no_alt_analysis_set.fa`, the reference used by GIAB,
by the DeepVariant case studies and by the hap.py examples themselves.

### The SNP hard filters cost more than they gain

Going from ALL to PASS on SNPs discards 41,350 true positives in order to
remove 13,583 false ones — three good variants lost per error caught — and the
F1 falls from 0.9814 to 0.9770. On indels the same filters are neutral
(0.9837 to 0.9839).

The dominant filter is `SNP_MQ40`, the mapping-quality threshold, which is the
same quantity the ALT problem depresses. The two defects compound: the
reference lowers MAPQ, then the filter deletes what survived. Whether the SNP
filters are worth keeping should be re-decided after the no-ALT re-run, not
before, since the re-run changes the input to that decision.

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

## How the code is organised

- `run_parabricks_hg002.sh` — the main recipe;
- `scripts/pipeline_functions.sh` — Docker orchestration, checkpoints and logs;
- `scripts/postprocess.sh` — filtering, annotation and QC metrics;
- `scripts/generate_report.py` — HTML report and JSON summary;
- `benchmark_giab.sh` — accuracy benchmark against the GIAB truth set, run
  separately once the pipeline has finished;
- `Start-HG002.ps1` — small Windows launcher that runs Bash inside Ubuntu WSL2;
- `Get-PipelineStatus.ps1` — monitor;
- `Stop-HG002.ps1` — controlled shutdown;
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

If the export to Windows fails, the valid copy stays in the `hg002_work_v1`
volume.

## Directories that matter

- `logs/` — current logs and previous attempts;
- `output/` — validated final results;
- `reports/` — HTML and JSON reports;
- `reports/giab/` — hap.py output; only the small JSON summary is committed;
- `ref/` — GRCh38/assembly38 and its indexes;
- `snpEff_data/` — local hg38 database;
- `smoke/` — small FASTQ files used for the trial run.

The full FASTQ files, the reference, the databases and the outputs must not be
pushed to GitHub. `.gitignore` excludes them. See `docs/data-sources.md` for
where to obtain each of them.

## Stated limitations

- The workstation has 32 GB of RAM, well below the 100 GB NVIDIA officially
  recommends for WGS. Splitting the work across separate containers reduces the
  risk and passed the smoke test, but the configuration remains outside the
  official specification.
- BQSR uses the dbSNP set included in the project; this is not the complete
  known-sites bundle from the Broad Best Practices.
- The snpEff hg38 database does not recognise some decoy/alt contigs of
  assembly38. The pipeline keeps those records, quantifies the limitation in the
  report, and does not present them as annotated.
- The reference carries ALT contigs without the `.alt` file and without
  alt-aware post-processing. The benchmark quantifies the cost: 3.03 % of true
  SNPs missed genome-wide, rising to 10.39 % on chr6. This is the largest known
  defect in the current results and the reason for the planned re-run.
- Ti/Tv is 1.928 against 2.10 in the truth set. The benchmark shows this is
  driven by missing true SNPs rather than by an excess of false ones:
  precision is 99.33 %.
- The SNP hard filters currently reduce F1 rather than improve it. They are
  left unchanged on purpose until the reference problem is fixed, so that one
  variable moves at a time.
- The "40×" in the dataset name is the publisher's label, not a measurement.
  The effective coverage measured on this run is 35.0×; see Results for the
  three definitions and how they reconcile.
- Hard filters and snpEff are technical controls, not clinical interpretation.
