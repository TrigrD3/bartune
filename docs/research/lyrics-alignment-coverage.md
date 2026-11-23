# Lyrics Alignment coverage: handling unalignable lines, confidence, and gap filling

Research notes for raising the share of LRC lines that the Lyrics Alignment engine (MMS forced-aligner, CTC Viterbi, Core ML) times successfully. Researched 2026-11. Every claim cites a primary source; "unverified" marks what could not be confirmed. Code links are pinned to the commit that was read.

## 1. Summary

- **No mainstream aligner chains segments monotonically the way BarTune does.** WhisperX aligns each segment independently within its own time bounds, and on failure it keeps the original timing ([alignment.py L269–331](https://github.com/m-bain/whisperX/blob/8d8e43bf3698dd1df4b011c0f1a8dd1d468ae365/whisperx/alignment.py#L269-L331)). Gentle and the Moreno/HP recursive method treat confidently aligned words as **anchors** and re-align only the gaps between them ([gentle multipass.py](https://github.com/lowerquality/gentle/blob/087a3b738bad9ebafd0570561486252cb624ba3a/gentle/multipass.py#L12-L60), [US 6,076,059](https://patents.google.com/patent/US6076059)). The patent calls its approach "not a sequential left-to-right alignment", so an error in one segment does not spread to others.
- **BarTune's code makes the suspected cascade possible.** `alignedUntilFrame` advances to the last kept word *before* `dropUnreliableLines` runs, so a line that is placed late and then dropped still pushes the lower bound for every later line (`LyricsForcedAligner.align(_:keeping:)`). This comes from reading the code. The runtime effect has not been measured.
- **Use the MMS paper's own confidence score.** It scores an alignment as `(1/T)·(log P(forced) − log P(greedy))` and keeps samples above −0.2 ([MMS §3.1.5, Eq. 1](https://arxiv.org/pdf/2305.13516)). BarTune can compute this per line for free from the log-probs it already holds, and the score is a direct "the model doesn't hear this text here" signal. That is better than a global offset test alone.
- **Garbage/star tokens give extra audio a place to go**, such as ad-libs, backing vocals and lines missing from the LRC. MMS/torchaudio use `<star>` with log-prob 0 ([torchaudio utils.py L37–42](https://github.com/pytorch/audio/blob/efaadd2ab0a31d871c9bb6b05262e302d07d4fe8/src/torchaudio/pipelines/_wav2vec2/utils.py#L37-L42)). WhisperX uses a "wildcard" column equal to the max non-blank log-prob per frame ([L313–322](https://github.com/m-bain/whisperX/blob/8d8e43bf3698dd1df4b011c0f1a8dd1d468ae365/whisperx/alignment.py#L313-L322)). On music, a zero-cost star is risky (see §2.1).
- **Treat parenthetical backing vocals as non-monotonic.** Apple's lyric TTML puts them in an `x-bg` span *inside* the lead line ([Apple asset guide](https://help.apple.com/itc/videoaudioassetguide/en.lproj/itc8c2e23e9a.html)). Apple's style guide puts them on a separate line *after* the lead line ([Apple Music style guide](https://help.apple.com/itc/musicstyleguide/en.lproj/itc3ae5d4dea.html)). A strictly sequential Viterbi over LRC order cannot represent "sung at the same time as the previous line".
- **Line-bounded soft masks help.** Spotify's contrastive aligner restricts each line's tokens to an estimated line interval with a 2.5 s linear tolerance. Removing this step gave "a significantly worse AAE" ([Durand et al. 2023 §2.4, §3.2](https://arxiv.org/pdf/2306.07744)).
- **Source separation gives mixed results and costs a lot on device.** Stoller et al. cut Jamendo AAE from 0.82 s to 0.38 s, but only after *retraining* the acoustic model on separated vocals ([ICASSP 2019 §5](https://arxiv.org/pdf/1902.06797)). Gupta et al. found models trained on separated vocals did *worse* than polyphonic ones ([ICASSP 2020 Table 3](https://arxiv.org/pdf/1909.10200)). For a Core ML HTDemucs, the community port lists 200–400 MB and says it is "not stable on the Apple Neural Engine" ([htdemucs-coreml](https://github.com/dexxdean/htdemucs-coreml)). Separation also leaves lead and backing vocals in one stem.
- **Recommended order:** fix the cascade → per-line score-based rejection relative to neighbours → anchor-bounded re-alignment of failed runs with star edges → a separate pass for parenthetical lines → interpolate the residue between anchors. Measure before considering separation.

## 2. Findings

### 2.1 How established forced aligners handle unalignable segments (Q1)

| Tool | Mechanism for extra/missing content | How it decides "failed" | Output on failure |
|---|---|---|---|
| **MMS / torchaudio `MMS_FA`** | `<star>` token: one extra emission column with log-prob **0** (posterior = 1), appended *after* log_softmax ([utils.py L37–42](https://github.com/pytorch/audio/blob/efaadd2ab0a31d871c9bb6b05262e302d07d4fe8/src/torchaudio/pipelines/_wav2vec2/utils.py#L37-L42)). For the Bible data, MMS inserts it at the start of each chapter and in place of digits ([MMS §3.1.3, p. 6–7](https://arxiv.org/pdf/2305.13516)). | Data filtering: the score in Eq. 1 must be > −0.2 (§3.1.5). A later CER > 10% filter removed 1.7% of samples (§3.1.6). | Star spans are dropped. Low-score segments are discarded (training-data use case). |
| **torchaudio API tutorial** | Shows `*` absorbing untranscribed audio (`* (1.00): 0.000 - 2.595 sec`) ("Advanced: Handling transcripts with `<star>` token") ([tutorial](https://docs.pytorch.org/audio/main/tutorials/ctc_forced_alignment_api_tutorial.html)). | Token score = mean frame prob over the span ([`merge_tokens` L96–124](https://github.com/pytorch/audio/blob/efaadd2ab0a31d871c9bb6b05262e302d07d4fe8/src/torchaudio/functional/_alignment.py#L96-L124)). Word score = span-length-weighted average. | No built-in rejection. Note: these APIs were "deprecated in 2.8 and … removed in 2.9" (tutorial header). |
| **ctc-forced-aligner** (MahmoudAshraf97) | Adds a zero log-prob star column ([alignment_utils.py L180–183](https://github.com/MahmoudAshraf97/ctc-forced-aligner/blob/7c66b95a8d69f5a34d02813bb6ed76c73ce8d887/ctc_forced_aligner/alignment_utils.py#L180-L183)). `star_frequency="segment"` puts `<star>` before **every** segment; `"edges"` puts it only at the start and end ([text_utils.py L180–214](https://github.com/MahmoudAshraf97/ctc-forced-aligner/blob/7c66b95a8d69f5a34d02813bb6ed76c73ce8d887/ctc_forced_aligner/text_utils.py#L180-L214)). A code comment says per-segment stars "produce more accurate results". | Emits `score = mean(log-prob over segment frames)`. No threshold ([text_utils.py L224–246](https://github.com/MahmoudAshraf97/ctc-forced-aligner/blob/7c66b95a8d69f5a34d02813bb6ed76c73ce8d887/ctc_forced_aligner/text_utils.py#L224-L246)). | Star spans are skipped in the output. Everything else is returned with its score. |
| **WhisperX** | Aligns each ASR segment **independently** on its own audio slice. Characters missing from the model dictionary map to a wildcard column = max non-blank log-prob ([L313–322](https://github.com/m-bain/whisperX/blob/8d8e43bf3698dd1df4b011c0f1a8dd1d468ae365/whisperx/alignment.py#L313-L322)). | No alignable chars, segment beyond audio, or backtrack returns no path ([L269–331](https://github.com/m-bain/whisperX/blob/8d8e43bf3698dd1df4b011c0f1a8dd1d468ae365/whisperx/alignment.py#L269-L331)). | "resorting to original" segment times. Words without times are **interpolated** (`interpolate_nans`, default `nearest`) ([L406–412, L437–438](https://github.com/m-bain/whisperX/blob/8d8e43bf3698dd1df4b011c0f1a8dd1d468ae365/whisperx/alignment.py#L406-L438)). |
| **NeMo Forced Aligner** | No garbage token documented. Text is split into segments by `additional_segment_grouping_separator`. With `align_using_pred_text`, it aligns against ASR output instead ([NFA docs](https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/tools/nemo_forced_aligner.html)). | Not documented. CTM output has no confidence field per the docs page. | Unverified. |
| **Gentle** | First decodes with a transcript-biased LM, then diffs the hypothesis against the transcript. Matches become `success`, and transcript words with no match become `not-found-in-audio` ([diff_align.py L16–75](https://github.com/lowerquality/gentle/blob/087a3b738bad9ebafd0570561486252cb624ba3a/gentle/diff_align.py#L16-L75)). | Diff mismatch. | **Second pass:** each run of unaligned words is re-recognized only within the audio between its neighbouring aligned words, using a run-specific LM. Gaps shorter than 0.75 s or longer than 60 s are skipped ([multipass.py L12–60](https://github.com/lowerquality/gentle/blob/087a3b738bad9ebafd0570561486252cb624ba3a/gentle/multipass.py#L12-L60)). Then `AdjacencyOptimizer` resolves ambiguous placements of repeated words ([forced_aligner.py L28–45, L50–90](https://github.com/lowerquality/gentle/blob/087a3b738bad9ebafd0570561486252cb624ba3a/gentle/forced_aligner.py#L28-L90)). |
| **ctc-segmentation** (ESPnet/NeMo) | `gratis_blank` / `blank_transition_cost_zero` makes blank self-loops free, so "unrelated" audio between utterances can be skipped ([README L198, L246](https://github.com/lumaku/ctc-segmentation/blob/e9215bfdd4de6c05023596c8a861089f7afbdbd6/README.md)). | Confidence = **minimum** over sliding windows of L = 30 frames of the mean path log-prob ([ctc_segmentation.py L395–406](https://github.com/lumaku/ctc-segmentation/blob/e9215bfdd4de6c05023596c8a861089f7afbdbd6/ctc_segmentation/ctc_segmentation.py#L395-L406)). The README warns that "Partially repeating segments have a high chance to disarrange the alignments … These segments can be detected with the confidence score." | Segments below a tuned threshold are discarded (README "Segments clean-up"). |
| **aeneas** | TTS + banded DTW on MFCCs ([HOWITWORKS](https://github.com/readbeyond/aeneas/blob/master/wiki/HOWITWORKS.md)). | None. The README says "Audio should match the text: large portions of spurious text or audio might produce a wrong sync map" and "not suitable for song captioning" ([README](https://github.com/readbeyond/aeneas)). | Not applicable. Not a model for this problem. |
| **Montreal Forced Aligner** | `beam=10`, `retry_beam=40` ("Beam width to use if initial alignment fails"). OOVs map to `<unk>`/`spn` ([global config](https://montreal-forced-aligner.readthedocs.io/en/latest/user_guide/configuration/global.html)). | A second attempt with a wider beam. Post-hoc `alignment_analysis.csv`: speech log-likelihood, phone-duration z-score deviation, "max running short intervals" (transcript squeezed), SNR ([alignment analysis](https://montreal-forced-aligner.readthedocs.io/en/latest/user_guide/implementations/alignment_analysis.html)). | Flags utterances for review. |

**Implications for BarTune:**

- **Retry with a wider search (MFA's retry beam).** The equivalent here is retrying a failed line with a wider window or without the `alignedUntilFrame` bound.
- **"Max running short intervals" (MFA) catches the squeeze symptom.** A line forced into too little audio produces many 1-frame tokens, and that is cheap to detect.
- **A zero-cost star is not safe on music.** This is reasoning, not tested. With log-prob 0, the star is never worse than any real token on any frame. MMS works because a correct path on clean read speech also costs ≈ 0. On a polyphonic mix, true lyric frames often score well below 0, so a free star can swallow real singing.
  - STC, where the star originates, uses a token-insertion penalty λ ≤ 0 and scores the star as a logsumexp over tokens, not as 1 ([Pratap et al. 2022 §3.4.1, Fig. 2](https://arxiv.org/pdf/2201.12208)).
  - WhisperX's wildcard (max non-blank) is a reasonable on-device choice.
  - Either needs a tuned penalty.

### 2.2 Lyrics-specific alignment research (Q2)

**Benchmarks and metrics.**

- **JamendoLyrics.** The original set has 20 English songs ([Stoller 2019](https://arxiv.org/pdf/1902.06797)). The current MultiLang version has 80 songs in several languages with word and line timestamps. Its metadata flags "lyric overlap, polyphony, and non-lexical singing" ([f90/jamendolyrics](https://github.com/f90/jamendolyrics)).
- **Metrics.** AAE is the mean absolute word-onset error. PCO is the % of onsets within 0.3 s ([Durand 2023 §3.1](https://arxiv.org/pdf/2306.07744)). Older MIREX work uses "Perc", the % of time the predicted position is correct ([Stoller 2019 §4.2](https://arxiv.org/pdf/1902.06797)).
- **DALI.** 5,358 tracks of karaoke-user annotations, aligned to found audio by a singing-voice-detection teacher-student loop ([Meseguer-Brocal 2018](https://arxiv.org/abs/1906.10606)). It corrects **global** errors only, with an offset `o` and a frame-rate stretch `fr`, chosen by normalized cross-correlation between voice activity and annotation. The authors tried DTW and found it "not successful for our purpose" because its local warps break the annotation structure (§3.2, footnote 2). This supports an **affine (offset + rate) fit** over a constant offset for LRC files.

**Reported alignment accuracy on Jamendo (English):**

| System | Separation? | AAE (s) | PCO / PCS | Source |
|---|---|---|---|---|
| Stoller E2E (mix) | no | 0.82 | 85% | [Durand Table 2](https://arxiv.org/pdf/2306.07744); [Stoller Table 1](https://arxiv.org/pdf/1902.06797) |
| Stoller E2E, retrained on separated vocals | yes (Wave-U-Net, internal) | 0.38–0.39 | 87% | [Stoller §5](https://arxiv.org/pdf/1902.06797); [Demirel Table 1](https://arxiv.org/pdf/2102.09202) |
| Vaglio et al. (Spleeter) | yes | 0.37 | 92% | [Durand Table 2](https://arxiv.org/pdf/2306.07744) |
| Demirel et al., Demucs / Spleeter + anchors | yes | 0.31 / 0.38 | 93% / 90% | [Demirel Table 1](https://arxiv.org/pdf/2102.09202) |
| Gupta et al., genre-informed, polyphonic | no | 0.22 | 94% | [Gupta 2020 Table 3/7](https://arxiv.org/pdf/1909.10200) |
| Durand et al. contrastive (char) | no | 0.15 | 92% | [Durand Table 2](https://arxiv.org/pdf/2306.07744) |

**Effect of vocal separation (evidence is mixed):**

- **Stoller et al.:** separation plus *retraining the acoustic model on separated vocals* improved AAE from 0.82 to 0.38 (Jamendo) and from 0.35 to 0.27 (Mauch) ([§5](https://arxiv.org/pdf/1902.06797)).
- **Gupta et al.:** acoustic models trained on Wave-U-Net-separated vocals were worse than polyphonic models: Jamendo 0.39 vs 0.34, Mauch 3.62 vs 0.25. The cause was "erratic music suppression" around long non-vocal sections ([§4.1, Table 3](https://arxiv.org/pdf/1909.10200)).
- **Demirel et al.:** with a solo-singing acoustic model, Demucs beat Spleeter (AAE 0.31 vs 0.38) ([Table 1](https://arxiv.org/pdf/2102.09202)).
- **Whisper (transcription, not alignment):**
  - On Jam-ALT, HTDemucs separation "generally degraded the results for Whisper", except for large-v2 on English ([Cífka et al. 2023 §4](https://arxiv.org/pdf/2311.13987)).
  - On MUSDB-ALT, separation lowered WER from 23.59 to 20.00, but on Jam-ALT it did nothing (20.99 vs 21.08) ([Syed et al. 2025 Table III](https://arxiv.org/html/2506.15514v1)).
  - Using separated vocals only as an **RMS voice-activity detector** gave most of the gain: "the improvement comes from better segment boundaries rather than improved vocal quality after separation" (§III-B1).
- **No published result covers MMS_FA (read-speech wav2vec2) aligning lyrics on separated vs mixed audio.** Not found; unverified. A speech-only model could plausibly gain more from separation than the music-trained models above, but that is a hypothesis.
- **Practitioner report (not peer-reviewed):** a wav2vec2 lyric aligner on HTDemucs vocals found that bleed in instrumental stretches is "mistaken for singing" and pulls lines tens of seconds early. Two fixes raised word starts within 0.3 s from 89.1% to 90.6% and cut words off by more than 5 s from 87 to 52 on 24 JamendoLyrics songs ([theoi/mv-studio PR #171](https://github.com/theoi/mv-studio/pull/171)):
  - A soft per-frame cost (2.0) on non-blank tokens outside voice-activity regions.
  - A small cost for pauses inside a line.

  It also reports that repeated outro lines were placed early.

**Backing vocals, ad-libs, repetition:**

- **Whisper drops non-lyrical vocalizations and backing vocals.** "Whisper systematically deletes non-lexical vocables and backing vocals, regardless of source separation quality" ([Syed et al. 2025 §III-A4, Conclusion](https://arxiv.org/html/2506.15514v1)). This matches BarTune's failure classes: the model's posteriors are weak on exactly that content.
- **Transcription guidelines put background vocals in parentheses** ([Jam-ALT §2](https://arxiv.org/pdf/2311.13987)), so parentheses in LRC are a usable signal.
- **Durand et al. note that their decoder cannot handle time-overlapping lyrics** ("duets, Ad-Lib"). Overlap is left as future work ([§4](https://arxiv.org/pdf/2306.07744)).
- **Repetition:**
  - Stoller notes that some systems analyze musical structure because songs repeat ([§1](https://arxiv.org/pdf/1902.06797)).
  - ctc-segmentation warns that repeats "disarrange" alignment ([README](https://github.com/lumaku/ctc-segmentation/blob/e9215bfdd4de6c05023596c8a861089f7afbdbd6/README.md)).
  - Gentle has a dedicated pass for repeated words ("I really really really…") ([forced_aligner.py L50–90](https://github.com/lowerquality/gentle/blob/087a3b738bad9ebafd0570561486252cb624ba3a/gentle/forced_aligner.py#L50-L90)).
- **Not covered here:** LyricWhiz is Whisper + GPT-4 *transcription*, not alignment ([arXiv 2306.17103](https://arxiv.org/abs/2306.17103)). MIREX tables beyond those reproduced in Stoller/Gupta were not consulted.

### 2.3 Confidence scoring and rejection for CTC alignments (Q3)

| Score | Definition | Used by | Notes for BarTune |
|---|---|---|---|
| Mean path log-prob per frame | `(1/T) Σ log p(path_t)` | ctc-forced-aligner, torchaudio `merge_tokens`, WhisperX word score | BarTune already computes it per word (`confidence = exp(mean log-prob)`). It is confounded by loud accompaniment, which lowers every token's probability. |
| **Forced − greedy, length-normalized** | `(1/T)[log P(Y_aligned\|X) − log P(Y_greedy\|X)]`. 0 is perfect; threshold −0.2 | MMS §3.1.5 Eq. 1 ([paper](https://arxiv.org/pdf/2305.13516)) | The greedy term is `Σ_t max_c log p_t(c)` over the same frames, which is O(T·V) on in-memory log-probs. It normalizes away "the whole mix is noisy". It measures how much *worse* the lyric path is than whatever the model thinks is there. The best single candidate; the threshold must be re-tuned for music. |
| Min windowed mean | min over windows of 30 frames of the mean path log-prob | ctc-segmentation ([L395–406](https://github.com/lumaku/ctc-segmentation/blob/e9215bfdd4de6c05023596c8a861089f7afbdbd6/ctc_segmentation/ctc_segmentation.py#L395-L406)) | Catches a line where *part* is placed on non-singing audio. 30 frames is about 0.6 s at 50 fps. |
| Duration / squeeze checks | phone-duration z-score; runs of very short intervals | MFA ([analysis](https://montreal-forced-aligner.readthedocs.io/en/latest/user_guide/implementations/alignment_analysis.html)) | Map to "tokens per frame" density, and to a line's aligned duration vs its LRC duration. |
| Second-model check | CER > 10% from a held-out ASR model | MMS §3.1.6 | Too heavy on device. |

**Better than a fixed global offset filter:**

1. **Score-based accept/reject per line**, using the forced − greedy score plus a squeeze check. This rejects lines the model doesn't hear, whatever their offset, and accepts genuinely shifted lines that are well heard.
2. **Local reference instead of a global median.** Compare a line's offset with the offsets interpolated from its accepted *neighbours* (previous and next anchor). This matches the measured pattern: neighbours within 0.1–1.0 s, failures in runs. The ±1.0 s global test is especially fragile at song start (the first 4 lines are unfiltered) and with tempo drift between the LRC and the actual recording.
3. **Affine global model** (offset + rate), following DALI's `o`/`fr` correction ([§3.2](https://arxiv.org/abs/1906.10606)). Fit it robustly to anchor onsets vs LRC times and test residuals, not raw offsets. The robust estimator choice (e.g. Theil–Sen or RANSAC) is an engineering choice and was not taken from a source.

### 2.4 Gap filling between anchors (Q4)

- **Recursive anchor alignment (Moreno et al., ICSLP 1998; HP patent US 6,076,059).** Recognize the audio with a segment-specific LM and match the result to the text with DP. Any run of ≥ 4 matching words (falling back to 3, then 2) becomes an anchor. Then recurse on each unaligned text/audio pair until no anchors are found or segments are short. The patent describes it as "a top-down iterative alignment process, and not a sequential left-to-right alignment" ([patent](https://patents.google.com/patent/US6076059)). The ICSLP PDF itself was not retrieved.
- **SAILAlign** (Katsamanis et al. 2011): an iterative ASR + text-alignment scheme in the same family ([SAIL page](https://sail.usc.edu/old/software/SailAlign/)). The paper was not read, so it is not detailed here.
- **Gentle multipass:** a concrete open implementation of anchor-bounded re-alignment. The window is the previous anchor's end to the next anchor's start, with 0.75–60 s duration guards ([multipass.py L38–60](https://github.com/lowerquality/gentle/blob/087a3b738bad9ebafd0570561486252cb624ba3a/gentle/multipass.py#L38-L60)).
- **Demirel et al. 2021:** "islands of confidence". Anchors are runs of N_anchor = 5 consecutive matching words between the transcription and the lyrics. The audio is split at anchors, and a final forced alignment runs per segment ([§3.4–3.6](https://arxiv.org/pdf/2102.09202)).
- **Line-bounded decoding** (Durand et al. 2023):
  - First, estimate each line's centre from the start time of its middle token, which is "robust to outliers".
  - Then estimate its duration from the token count (0.2 s per char).
  - Then re-decode with a mask that favours that interval, with a 2.5 s linear tolerance ([§2.4](https://arxiv.org/pdf/2306.07744)).

  This is a soft version of BarTune's hard ±3 s window.
- **Interpolation for leftovers:** WhisperX fills untimed words by `interpolate_nans` (nearest by default) ([L406–412](https://github.com/m-bain/whisperX/blob/8d8e43bf3698dd1df4b011c0f1a8dd1d468ae365/whisperx/alignment.py#L406-L412)). For BarTune, the analogue is to **warp LRC times piecewise-linearly between the bracketing accepted anchors**. No karaoke-specific primary source was found for this; it follows from the anchor literature above. It beats "keep raw LRC time" whenever neighbours show a consistent shift.
- **DTW:** DALI rejected DTW for annotation correction (local warps break structure) ([§3.2 fn. 2](https://arxiv.org/abs/1906.10606)). An anchor-constrained piecewise-linear map is the structure-preserving alternative.

### 2.5 Overlapping / non-monotonic content (Q5)

- **Apple TTML (lyrics delivery):**
  - Background vocals are a `<span ttm:role="x-bg">` *inside* the lead `<p>`. It goes first if it starts before the main vocal, otherwise last.
  - Multiple singers use `ttm:agent`. "Timed elements for different agents can overlap", but a single agent's intervals must not ([Apple asset guide, Lyrics Example Annotations](https://help.apple.com/itc/videoaudioassetguide/en.lproj/itc8c2e23e9a.html)).
  - `x-` roles are custom extensions under TTML ([W3C role registry](https://www.w3.org/wiki/TTML/RoleRegistry)).
- **Apple Music style guide (text):**
  - "All background vocals should be on a separate line following the main vocal line."
  - "If a line is repeated, it must be written out."
  - "harmonious non-word vocal sounds" should be transcribed, but improvised scatting must not ([style guide](https://help.apple.com/itc/musicstyleguide/en.lproj/itc3ae5d4dea.html)).
  - Consequence: in line-level LRC derived from such text, a parenthetical line usually comes *after* a lead line it overlaps in time. A monotonic aligner must either compress the lead line or push the backing line late. Either can trip the offset filter and, through `alignedUntilFrame`, the following lines.
- **Enhanced LRC (word tags `<mm:ss.xx>`):** no formal spec was found, so its handling of overlap is unverified. Plain LRC cannot express overlap except through equal or decreasing timestamps.
- **How aligners treat overlap:**
  - None of the surveyed forced aligners models concurrent text streams. All are single-path Viterbi or DTW.
  - Durand et al. explicitly leave overlap (duets, ad-libs) to future work ([§4](https://arxiv.org/pdf/2306.07744)).
  - Separation does not help directly: HTDemucs outputs four stems (vocals, drums, bass, other) ([htdemucs-coreml](https://github.com/dexxdean/htdemucs-coreml)). Lead and backing vocals share the vocals stem.
  - Practical options, from the reasoning above (not sourced): (a) exclude parenthetical/backing lines from the monotonic chain, then align each one in a separate pass inside its host line's window with no ordering constraint; (b) give them the host line's timing, which is the TTML x-bg model.

### 2.6 On-device vocal separation on Apple silicon (Q6)

| Port | Format | Size | Speed (as published) | Caveats |
|---|---|---|---|---|
| dexxdean/htdemucs-coreml | Core ML `.mlpackage`, 44.1 kHz stereo, 10 s segments | ~400 MB FP32, ~200 MB FP16 | none published | "not stable on the Apple Neural Engine". `.all`/`.cpuAndNeuralEngine` may produce "silent garbage". Use `.cpuAndGPU`. macOS 14+ ([repo](https://github.com/dexxdean/htdemucs-coreml)) |
| StemSplitio htdemucs-ft-vocals-onnx | ONNX, 7.8 s segments | 316 MB | RTF 0.20 on M4 Pro **CPU** (onnxruntime), about 22 s per 3-min song ([model card](https://huggingface.co/StemSplitio/htdemucs-ft-vocals-onnx)) | CoreML EP listed as an option. No CoreML timings. |
| lextoumbourou/mlx-demucs | MLX (not Core ML) | not stated | "~38x realtime on Apple Silicon"; chip unspecified ([repo](https://github.com/lextoumbourou/mlx-demucs)) | MLX adds a dependency, outside the Core ML path |

- **No verified Core ML real-time factor or memory figure was found for HTDemucs, Open-Unmix or Spleeter.** Measure locally before committing.
- **Separation would sit beside the existing 274 MB MMS download** and compete with the aligner on the same machine. HTDemucs runs on the GPU, while BarTune pins the aligner to `.cpuAndNeuralEngine`.

## 3. Ranked recommendations for BarTune

Failure classes:

- **A:** parenthetical backing vocals concurrent with the lead.
- **B:** ad-libs/outros ("Ooh, yeah").
- **C:** repeated hooks.
- **D:** bridges / quieter final choruses (weak posteriors).
- **E:** cascade, where a late line pushes `alignedUntilFrame` and later lines are dropped.

| # | Change | Fixes | Expected impact | Cost | Evidence |
|---|---|---|---|---|---|
| 1 | **Advance `alignedUntilFrame` only from accepted lines.** Today it is set before `dropUnreliableLines`. A dropped line should leave the bound at the last *accepted* word (or at most at the dropped line's LRC start). | E (and the A/B lines that trigger it) | Possibly large on runs, if the cascade is real; that is unconfirmed. It turns run failures into isolated failures. | S | Code reading of `align(_:keeping:)`. Anchor methods isolate errors by design ([US 6,076,059](https://patents.google.com/patent/US6076059)). WhisperX has no cross-segment bound ([L269–331](https://github.com/m-bain/whisperX/blob/8d8e43bf3698dd1df4b011c0f1a8dd1d468ae365/whisperx/alignment.py#L269-L331)). |
| 2 | **Per-line score `S = (1/T)(Σ path log-prob − Σ_t max_c log p_t(c))`** over the line's frames, plus a squeeze check (frames per token, line duration vs LRC). Accept or reject on S; keep the offset test only as a backstop. | D, B, E | Fewer false drops of well-heard but shifted lines; fewer accepted mis-placements. A threshold must be tuned for music; MMS used −0.2 for speech. | S | [MMS §3.1.5](https://arxiv.org/pdf/2305.13516); [ctc-segmentation](https://github.com/lumaku/ctc-segmentation/blob/e9215bfdd4de6c05023596c8a861089f7afbdbd6/ctc_segmentation/ctc_segmentation.py#L395-L406); [MFA analysis](https://montreal-forced-aligner.readthedocs.io/en/latest/user_guide/implementations/alignment_analysis.html) |
| 3 | **Neighbour-relative offset test.** Compare a line's offset with the value interpolated from its accepted neighbours (or a robust affine fit), not with the global median. | D, E, tempo drift | Matches the measured pattern (neighbours within 0.1–1.0 s). | S | DALI offset + rate model ([§3.2](https://arxiv.org/abs/1906.10606)); Durand's robust line centre ([§2.4](https://arxiv.org/pdf/2306.07744)) |
| 4 | **Anchor-bounded re-alignment of failed runs.** Once accepted lines bracket a run, re-run Viterbi for just that run on frames between the anchors (the log-probs are already in memory). Add a penalized garbage token at the run edges and between lines. Allow this on later plays too, instead of "never retried". | A, B, D, E | Recovers lines that were only lost through wrong bounds. Gentle reports this as its standard second pass. | M | [Gentle multipass](https://github.com/lowerquality/gentle/blob/087a3b738bad9ebafd0570561486252cb624ba3a/gentle/multipass.py#L12-L60); [Demirel §3.4–3.6](https://arxiv.org/pdf/2102.09202); [US 6,076,059](https://patents.google.com/patent/US6076059) |
| 5 | **Garbage/wildcard token with a cost** between lines (and optionally within long lines). Emission = `max_{c≠blank} log p_t(c) + λ` (WhisperX wildcard + STC penalty), not 0. | B (unlisted ad-libs), A (backing vocals that are not text), C | Lets the path park non-lyric singing instead of stretching or pulling lines. λ needs tuning; too cheap and it eats real lines. | S | [WhisperX L313–322](https://github.com/m-bain/whisperX/blob/8d8e43bf3698dd1df4b011c0f1a8dd1d468ae365/whisperx/alignment.py#L313-L322); [STC §3.4.1](https://arxiv.org/pdf/2201.12208); [MMS §3.1.3](https://arxiv.org/pdf/2305.13516) |
| 6 | **Separate pass for parenthetical lines.** Remove `(…)`-only lines (and `(…)` segments) from the monotonic chain. Align them afterwards inside the host line's window ± tolerance with no ordering constraint, and never let them move `alignedUntilFrame`. If S is poor, inherit the host line's timing. | A | Removes the main source of non-monotonic text from the chain. | S–M | [Apple TTML x-bg](https://help.apple.com/itc/videoaudioassetguide/en.lproj/itc8c2e23e9a.html); [style guide](https://help.apple.com/itc/musicstyleguide/en.lproj/itc3ae5d4dea.html); [Jam-ALT parentheses rule](https://arxiv.org/pdf/2311.13987) |
| 7 | **Piecewise-linear fallback** for lines that still fail: warp their LRC times by interpolating the bracketing anchors' offsets, instead of keeping raw LRC times. | All residual | Raises "usable" coverage even where acoustic alignment fails. Accuracy is bounded by the neighbour offsets (0.1–1.0 s observed). | S | [WhisperX interpolate_nans](https://github.com/m-bain/whisperX/blob/8d8e43bf3698dd1df4b011c0f1a8dd1d468ae365/whisperx/alignment.py#L406-L412); [DALI affine correction](https://arxiv.org/abs/1906.10606) |
| 8 | **Soft line window.** Replace the hard −∞ outside ±3 s with a linear penalty ramp (Durand: 2.5 s tolerance), centred on the anchor-warped LRC time rather than the raw LRC time. | D, E | Fewer "no path" failures. Lines drift less to window edges. | S | [Durand §2.4, §3.2](https://arxiv.org/pdf/2306.07744) |
| 9 | **Vocal-activity token cost** from the existing voice-band envelope: a soft per-frame cost on non-blank tokens where the envelope is low. | D, B (instrumental stretches), C | Practitioner report: +1.5 pt within 0.3 s and 87 → 52 gross errors on 24 Jamendo songs with wav2vec2. Not peer-reviewed. | S–M | [mv-studio PR #171](https://github.com/theoi/mv-studio/pull/171); [Syed 2025: vocal activity drives the gain](https://arxiv.org/html/2506.15514v1) |
| 10 | **Vocal source separation (HTDemucs Core ML) before MMS.** | D (quiet choruses), possibly B | Uncertain: published gains need a retrained acoustic model, and other studies show losses. It does not split lead from backing vocals, so it doesn't fix A. | L (200–400 MB model, GPU only, no published Core ML RTF, extra memory on an 8 GB-class Mac) | [Stoller §5](https://arxiv.org/pdf/1902.06797); [Gupta Table 3](https://arxiv.org/pdf/1909.10200); [Demirel Table 1](https://arxiv.org/pdf/2102.09202); [htdemucs-coreml](https://github.com/dexxdean/htdemucs-coreml) |

Items 1–3 and 7 reuse the existing model, log-probs and Viterbi unchanged. Items 4–6 and 8 add only states or emission columns to the existing Swift Viterbi.

## 4. Open questions and what to measure first

1. **Log a failure reason per line**, persisted with the song's alignment record:
   - `noPath` (Viterbi returned nil)
   - `squeezed` (window after the `alignedUntilFrame` clamp shorter than N frames per token)
   - `offsetOutlier` (with offset, median, and neighbour offsets)
   - `notAttempted` (started before run audio)
   - `accepted`

   Also log the clamp itself: `lowFrame − windowStart` in seconds. This directly confirms or refutes the cascade (E) before any algorithm change.
2. **Log per-line scores:** mean path log-prob, forced − greedy S, min 30-frame window mean, frames per token. Plot accepted vs dropped to see whether S separates them better than the offset test.
3. **Tag each line** as parenthetical, non-lexical (ooh/yeah/oh), duplicate text of an earlier line, or LRC-overlapping (starts before the previous line's LRC end). This gives the coverage per class, which tells whether #6 or #5 matters more.
4. **Ground truth:** user-timed Custom lyrics (timing editor) give word or line onsets. Report PCO@0.3 s and AAE on those songs as well as coverage. Coverage alone can rise while accuracy falls, for example with interpolation (#7) or a cheap garbage token (#5).
5. **Ablate one change at a time** on the same recorded audio, by replaying stored log-probs offline so audio capture is out of the loop:
   - #1 alone.
   - #1 + #2.
   - + #4/#5.
   - + #6.
6. **Unverified, needs measurement:**
   - whether MMS posteriors on separated vocals beat the mix for the "quieter final chorus" class (decides #10);
   - a good λ for the garbage token on music;
   - the music-appropriate threshold for S.

## 5. Sources

**Papers**
- Pratap et al., "Scaling Speech Technology to 1,000+ Languages" (MMS), §3.1.3–3.1.6, pp. 6–8. https://arxiv.org/pdf/2305.13516
- Pratap et al., "Star Temporal Classification", §3.4.1. https://arxiv.org/pdf/2201.12208
- Stoller, Durand, Ewert, "End-to-end Lyrics Alignment for Polyphonic Music Using an Audio-to-Character Recognition Model", ICASSP 2019. https://arxiv.org/pdf/1902.06797
- Gupta, Yılmaz, Li, "Automatic Lyrics Alignment and Transcription in Polyphonic Music: Does Background Music Help?", ICASSP 2020. https://arxiv.org/pdf/1909.10200
- Demirel, Ahlbäck, Dixon, "Low Resource Audio-to-Lyrics Alignment from Polyphonic Music Recordings", ICASSP 2021. https://arxiv.org/pdf/2102.09202
- Durand, Stoller, Ewert, "Contrastive Learning-Based Audio to Lyrics Alignment for Multiple Languages", ICASSP 2023. https://arxiv.org/pdf/2306.07744
- Meseguer-Brocal, Cohen-Hadria, Peeters, "DALI", ISMIR 2018. https://arxiv.org/abs/1906.10606
- Cífka et al., "Jam-ALT: A Formatting-Aware Lyrics Transcription Benchmark", 2023. https://arxiv.org/pdf/2311.13987
- Syed, Meresman Higgs, Cífka, Sandler, "Exploiting Music Source Separation for Automatic Lyrics Transcription with Whisper", 2025. https://arxiv.org/html/2506.15514v1
- Zhuo et al., "LyricWhiz", ISMIR 2023. https://arxiv.org/abs/2306.17103
- Moreno, Joerg, Van Thong, Glickman, ICSLP 1998 (via patent US 6,076,059). https://patents.google.com/patent/US6076059
- Katsamanis et al., "SailAlign" (2011). https://sail.usc.edu/old/software/SailAlign/ (not read in full)

**Code (pinned)**
- torchaudio @ efaadd2: `pipelines/_wav2vec2/utils.py` L37–42, `functional/_alignment.py` L96–124. https://github.com/pytorch/audio/tree/efaadd2ab0a31d871c9bb6b05262e302d07d4fe8
- ctc-forced-aligner @ 7c66b95: `alignment_utils.py` L180–183, `text_utils.py` L180–246. https://github.com/MahmoudAshraf97/ctc-forced-aligner/tree/7c66b95a8d69f5a34d02813bb6ed76c73ce8d887
- WhisperX @ 8d8e43b (`main` at time of reading): `whisperx/alignment.py` L269–438. https://github.com/m-bain/whisperX/blob/8d8e43bf3698dd1df4b011c0f1a8dd1d468ae365/whisperx/alignment.py
- Gentle @ 087a3b7: `diff_align.py`, `multipass.py`, `forced_aligner.py`. https://github.com/lowerquality/gentle/tree/087a3b738bad9ebafd0570561486252cb624ba3a
- ctc-segmentation @ e9215bf: `ctc_segmentation.py` L395–406, README. https://github.com/lumaku/ctc-segmentation/tree/e9215bfdd4de6c05023596c8a861089f7afbdbd6
- theoi/mv-studio PR #171 (practitioner, not peer-reviewed). https://github.com/theoi/mv-studio/pull/171

**Docs**
- torchaudio CTC forced alignment API tutorial. https://docs.pytorch.org/audio/main/tutorials/ctc_forced_alignment_api_tutorial.html
- torchaudio multilingual forced alignment tutorial. https://docs.pytorch.org/audio/main/tutorials/forced_alignment_for_multilingual_data_tutorial.html
- NeMo Forced Aligner. https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/tools/nemo_forced_aligner.html
- Montreal Forced Aligner: global config; alignment analysis. https://montreal-forced-aligner.readthedocs.io/en/latest/user_guide/configuration/global.html · https://montreal-forced-aligner.readthedocs.io/en/latest/user_guide/implementations/alignment_analysis.html
- aeneas README and HOWITWORKS. https://github.com/readbeyond/aeneas
- JamendoLyrics. https://github.com/f90/jamendolyrics
- Apple: Lyrics Example Annotations (TTML). https://help.apple.com/itc/videoaudioassetguide/en.lproj/itc8c2e23e9a.html
- Apple Music Style Guide (lyrics). https://help.apple.com/itc/musicstyleguide/en.lproj/itc3ae5d4dea.html
- W3C TTML Role Registry. https://www.w3.org/wiki/TTML/RoleRegistry
- htdemucs-coreml. https://github.com/dexxdean/htdemucs-coreml
- StemSplitio htdemucs-ft-vocals-onnx. https://huggingface.co/StemSplitio/htdemucs-ft-vocals-onnx
- mlx-demucs. https://github.com/lextoumbourou/mlx-demucs
