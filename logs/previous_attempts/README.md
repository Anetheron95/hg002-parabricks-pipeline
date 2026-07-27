# Metadata from previous attempts

This directory keeps the small diagnostic files that used to be mixed in with
the outputs:

- full integrity check of the 40× FASTQ files: 474,384,500 read pairs, `PASS`;
- timings and duplicate metrics from the failed 40× attempt;
- FASTQ check, timings, annotation and QC from the old smoke test.

The complete original logs remain in `logs/`.

The old `HG002_NovaSeq_40x.bam` was not kept: it was truncated, missing its EOF
block, and came with an empty BAI index. It was neither recoverable nor usable
as a checkpoint.
