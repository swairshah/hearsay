#!/usr/bin/env python3
"""Offline "accurate pass" over a saved meeting, compared with the live transcript.

Experiment only: nothing here runs inside the app. For one meeting it:

1. re-transcribes each saved track in one go with word timings (Parakeet via
   FluidAudio's CLI), optionally boosting a custom vocabulary,
2. runs whole-recording speaker detection on the call track (pyannote + VBx
   clustering, FluidAudio "offline" mode) instead of the live streaming model,
3. gives every word a speaker and starts a new line wherever the speaker changes,
4. asks local LLMs to name the speakers from the conversation,

then writes `accurate.json` (same shape as `hearsay meetings show --format json`,
so score.py can grade it), `comparison.html` (live and accurate side by side)
and `report.json` (timings, counts, names).

    scripts/meeting-eval/accurate_pass.py latest --out /tmp/pass \\
        --fluidaudio /path/to/fluidaudiocli [--vocab terms.txt] \\
        [--llm mlx:lmstudio-community/gemma-4-E4B-it-MLX-6bit] \\
        [--llm gguf:~/Library/Application\\ Support/Hearsay/CleanupModels/Qwen3.5-0.8B-Q4_K_M.gguf]

For a synthetic fixture (to score against ground truth) pass --mic/--system WAVs
and --live with the replayed meeting's JSON instead of a meeting id.
"""

import argparse
import html
import json
import os
import re
import shutil
import subprocess
import sys
import time

HEARSAY_CLI = os.path.expanduser("~/work/projects/hearsay/build/Build/Products/Debug/hearsay")
PALETTE = ["#4f7cff", "#e8590c", "#2b8a3e", "#ae3ec9", "#c92a2a", "#1098ad", "#a07a00", "#5c7cfa"]


# ---------------------------------------------------------------- helpers

def run(cmd, **kwargs):
    started = time.time()
    result = subprocess.run(cmd, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        sys.stderr.write(result.stdout[-2000:] + result.stderr[-4000:])
        raise SystemExit(f"command failed: {' '.join(cmd[:3])} …")
    return result.stdout, time.time() - started


def to_wav(source, target):
    run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", source, target])


def duration_of(wav):
    out, _ = run(["afinfo", wav])
    return float(re.search(r"estimated duration: ([\d.]+)", out).group(1))


def cached(path, compute, reuse):
    """Run `compute` (returning (value, seconds)) unless --reuse and a saved result exists."""
    meta = path + ".timing"
    if reuse and os.path.exists(path) and os.path.exists(meta):
        return compute(load_only=True), float(open(meta).read())
    value, seconds = compute(load_only=False)
    open(meta, "w").write(str(seconds))
    return value, seconds


def stamp(seconds):
    seconds = int(seconds)
    return f"{seconds // 60:02d}:{seconds % 60:02d}"


# ---------------------------------------------------------------- inputs

def load_live(args):
    """Live meeting JSON plus the WAV paths of its tracks."""
    if args.live:
        live = json.load(open(args.live))
        return live, args.mic, args.system
    path_out, _ = run([HEARSAY_CLI, "meetings", "path", args.meeting])
    folder = path_out.strip().splitlines()[-1]
    live = json.load(open(os.path.join(folder, "meeting.json")))
    tracks = {}
    for name in ("microphone", "system"):
        source = os.path.join(folder, f"{name}.m4a")
        if not os.path.exists(source):
            source = os.path.join(folder, f"{name}.caf")
        if os.path.exists(source):
            tracks[name] = os.path.join(args.out, f"{name}.wav")
            to_wav(source, tracks[name])
    return live, tracks.get("microphone"), tracks.get("system")


# ---------------------------------------------------------------- models

def utterance_words(tool, wav, ranges, out_json, vocab=None, reuse=False, live_text=None):
    """Re-transcribe each live utterance on its own (as the live pipeline does)
    to get per-word timings; with a vocabulary, also CTC-boosted text.

    Not one pass over the whole file: on a 15-minute meeting that silently
    dropped an 8-second stretch that the per-utterance live pass got right."""
    ranges_file = out_json + ".ranges"
    json.dump(ranges, open(ranges_file, "w"))

    def compute(load_only):
        if load_only:
            return None
        return run([tool, wav, ranges_file, out_json] + (["--vocab", vocab] if vocab else []))
    cached(out_json, compute, reuse)
    result = json.load(open(out_json))
    utterances = []
    for utterance in result["utterances"]:
        words = [{"word": w["word"], "start": w["start"], "end": w["end"], "conf": w["conf"]} for w in utterance["words"]]
        live = (live_text or {}).get(round(utterance["start"], 2))
        if live:
            # Keep the live wording; only the timings come from the re-run. The
            # saved tracks are AAC, so re-running changes ~8% of words for
            # reasons unrelated to what this pass is testing.
            words = retext(words, live, utterance["start"], utterance["end"])
        elif utterance.get("vocabText"):
            words = retext(words, utterance["vocabText"], utterance["start"], utterance["end"])
        utterances.append({"start": utterance["start"], "end": utterance["end"], "text": utterance["text"],
                           "words": words, "replacements": utterance.get("replacements", [])})
    return utterances, result["seconds"], result.get("vocabSeconds", 0)


def retext(words, text, start=0.0, end=0.0):
    """Carry word timings over to a rewritten text: vocabulary boosting changes
    a few words; untouched words keep their timings, replaced ones share the span."""
    import difflib
    new = text.split()
    old = [w["word"] for w in words]
    out = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(a=old, b=new, autojunk=False).get_opcodes():
        if op == "equal":
            out += words[i1:i2]
        elif j2 > j1:
            span = words[i1:i2] or ([out[-1]] if out else words[:1])
            begin, finish = (span[0]["start"], span[-1]["end"]) if span else (start, end)
            step = (finish - begin) / (j2 - j1)
            out += [{"word": new[j1 + k], "start": begin + k * step, "end": begin + (k + 1) * step, "conf": 1.0}
                    for k in range(j2 - j1)]
    return out


def diarize(fluidaudio, wav, out_json, reuse=False):
    def compute(load_only):
        return None if load_only else run([fluidaudio, "process", wav, "--mode", "offline", "--output", out_json])
    _, seconds = cached(out_json, compute, reuse)
    segments = json.load(open(out_json))["segments"]
    return [
        {"speaker": str(s["speakerId"]), "start": float(s["startTimeSeconds"]), "end": float(s["endTimeSeconds"])}
        for s in segments
    ], seconds


# ---------------------------------------------------------------- assembly

def speaker_for(word, turns, previous):
    best, best_overlap = None, 0.0
    for turn in turns:
        overlap = min(word["end"], turn["end"]) - max(word["start"], turn["start"])
        if overlap > best_overlap:
            best, best_overlap = turn["speaker"], overlap
    if best is not None:
        return best
    middle = (word["start"] + word["end"]) / 2
    nearest = min(turns, key=lambda t: min(abs(middle - t["start"]), abs(middle - t["end"])), default=None)
    if nearest and min(abs(middle - nearest["start"]), abs(middle - nearest["end"])) < 1.0:
        return nearest["speaker"]
    return previous


def smooth(labels):
    """A lone word between two words of the same other speaker is boundary jitter."""
    for index in range(1, len(labels) - 1):
        if labels[index - 1] == labels[index + 1] != labels[index]:
            labels[index] = labels[index - 1]
    return labels


def snap(words, labels):
    """Move each speaker change to the most natural nearby break: the longest
    pause within three words, preferring sentence ends. Diarization boundaries
    are a few hundred ms off, which otherwise hands a speaker's last word
    ("…as well.") to the next person."""
    for index in range(1, len(words)):
        if labels[index] == labels[index - 1]:
            continue
        best, best_score = index, -1.0
        for j in range(max(1, index - 3), min(len(words), index + 4)):
            gap = words[j]["start"] - words[j - 1]["end"]
            tail = words[j - 1]["word"][-1:]
            score = gap + (0.4 if tail in ".?!" else 0.15 if tail == "," else 0)
            if score > best_score:
                best, best_score = j, score
        before, after = labels[index - 1], labels[index]
        for k in range(min(best, index), max(best, index)):
            labels[k] = before if best > index else after
    return labels


def split_utterance(utterance, labels, channel):
    """One live utterance → one line per run of the same speaker. Runs shorter
    than two words are folded into their neighbour."""
    runs = []
    for word, label in zip(utterance["words"], labels):
        if runs and runs[-1]["speaker"] == label:
            runs[-1]["words"].append(word)
        else:
            runs.append({"speaker": label, "words": [word]})
    merged = []
    for run in runs:
        if merged and len(run["words"]) < 2:
            merged[-1]["words"] += run["words"]
        elif merged and len(merged[-1]["words"]) < 2:
            run["words"] = merged.pop()["words"] + run["words"]
            merged.append(run)
        else:
            merged.append(run)
    return [{"speaker": run["speaker"], "channel": channel, "start": run["words"][0]["start"],
             "end": run["words"][-1]["end"], "words": run["words"],
             "text": " ".join(w["word"] for w in run["words"])} for run in merged]


def assemble(live, mic_utterances, system_utterances, turns):
    # Call side: a speaker per word from whole-recording diarization, and a new
    # line wherever it changes inside an utterance.
    order = []
    for turn in sorted(turns, key=lambda t: t["start"]):
        if turn["speaker"] not in order:
            order.append(turn["speaker"])
    slot = {speaker: f"s{index + 1}" for index, speaker in enumerate(order)}

    lines = []
    for utterance in system_utterances:
        if not utterance["words"]:
            continue
        labels, previous = [], None
        for word in utterance["words"]:
            previous = speaker_for(word, turns, previous)
            labels.append(slot.get(previous, "them"))
        lines += split_utterance(utterance, snap(utterance["words"], smooth(labels)), "system")
    # Mic side: the live pass already dropped call audio echoed into the mic,
    # so only its kept utterances are re-transcribed.
    for utterance in mic_utterances:
        if utterance["words"]:
            lines += split_utterance(utterance, ["me"] * len(utterance["words"]), "microphone")

    lines.sort(key=lambda line: line["start"])
    speakers = [{"id": "me", "name": "You", "kind": "local"}] + [
        {"id": slot[s], "name": f"Speaker {index + 1}", "kind": "remote"} for index, s in enumerate(order)
    ]
    return lines, speakers


def to_document(live, lines, speakers):
    return {
        "id": live.get("id"), "title": live.get("title"), "startedAt": live.get("startedAt"),
        "speakers": speakers,
        "segments": [
            {"speakerID": line["speaker"], "channel": line["channel"], "start": round(line["start"], 2),
             "end": round(line["end"], 2), "text": line["text"], "originalText": line["text"]}
            for line in lines
        ],
    }


# ---------------------------------------------------------------- naming

INTRO = re.compile(r"\b(?:[Ii]'m|I am|[Mm]y name is|[Tt]his is)\s+([A-Z][a-z]+)\b")
ADDRESS = re.compile(r"\b([A-Z][a-z]+),?\s+(?:do you want to|you want to|want to|can you|could you|over to you|go ahead)")
NOT_NAMES = {"I", "It", "So", "And", "But", "The", "This", "That", "Okay", "Yeah", "Well", "Today", "Just", "Super",
             "Really", "You", "We", "They", "He", "She", "Do", "Can", "Could", "Now", "Here", "There", "What", "Not"}


def heuristic_names(lines, speakers):
    """Self-introductions ("I'm Zach") and hand-offs ("Zach, you want to …" → next speaker)."""
    votes = {}
    for index, line in enumerate(lines):
        if line["speaker"] == "me":
            continue
        for name in INTRO.findall(line["text"]):
            if name not in NOT_NAMES:
                votes.setdefault(line["speaker"], {}).setdefault(name, []).append(f"{stamp(line['start'])} “…{name}…” (introduction)")
    for index, line in enumerate(lines[:-1]):
        for name in ADDRESS.findall(line["text"]):
            following = next((l for l in lines[index + 1:] if l["speaker"] != line["speaker"]), None)
            if name not in NOT_NAMES and following and following["speaker"] != "me":
                votes.setdefault(following["speaker"], {}).setdefault(name, []).append(f"{stamp(line['start'])} addressed by {line['speaker']}")
    names = {}
    for speaker, candidates in votes.items():
        name, evidence = max(candidates.items(), key=lambda item: len(item[1]))
        names[speaker] = {"name": name, "evidence": "; ".join(evidence[:2])}
    return names


def naming_prompt(lines, speakers):
    label = {s["id"]: s["name"] for s in speakers}
    transcript, budget = [], 9000
    for line in lines:
        entry = f"[{stamp(line['start'])}] {label[line['speaker']]}: {line['text']}"
        budget -= len(entry)
        if budget < 0:
            break
        transcript.append(entry)
    remote = [s["name"] for s in speakers if s["kind"] == "remote"]
    return (
        "Below is the start of a meeting transcript. Speakers are anonymous labels.\n"
        "For each of these labels, work out the person's real first name if the conversation reveals it "
        "(self-introductions like \"I'm Zach\", being addressed by name right before they speak, "
        "being introduced by someone else). If it isn't clear, use null. Do not guess.\n"
        f"Labels: {', '.join(remote)}\n\n"
        "Answer with only a JSON object, no prose, like:\n"
        '{"Speaker 1": {"name": "Alice", "evidence": "says I\'m Alice at 01:02"}, "Speaker 2": {"name": null, "evidence": ""}}\n\n'
        "Transcript:\n" + "\n".join(transcript)
    )


def parse_names(text, speakers):
    # llama-cli echoes part of the prompt (including its example JSON), so take
    # the last object in the output that parses.
    data, decoder = None, json.JSONDecoder()
    for match in re.finditer(r"\{", text):
        try:
            candidate, _ = decoder.raw_decode(text[match.start():])
        except json.JSONDecodeError:
            continue
        if isinstance(candidate, dict) and any(key.startswith("Speaker") for key in candidate):
            data = candidate
    if data is None:
        return {}, text.strip()[-300:]
    by_name = {s["name"]: s["id"] for s in speakers}
    names = {}
    for key, value in data.items():
        if key in by_name and isinstance(value, dict) and value.get("name"):
            names[by_name[key]] = {"name": str(value["name"]), "evidence": str(value.get("evidence", ""))}
    return names, None


def llm_names(spec, prompt, speakers, workdir):
    kind, _, model = spec.partition(":")
    model = os.path.expanduser(model)
    prompt_file = os.path.join(workdir, "naming-prompt.txt")
    open(prompt_file, "w").write(prompt)
    if kind == "mlx":
        out, seconds = run(["mlx_lm.generate", "--model", model, "--max-tokens", "400", "--temp", "0",
                            "--prompt", "-"], input=prompt)
        text = out.split("==========")[1] if out.count("==========") >= 2 else out
    elif kind == "gguf":
        out, seconds = run(["llama-cli", "-m", model, "-f", prompt_file, "-n", "400", "--temp", "0", "-st",
                            "-rea", "off", "--no-display-prompt", "-c", "16384", "--log-disable"])
        text = out
    else:
        raise SystemExit(f"unknown --llm kind: {spec}")
    names, failure = parse_names(text, speakers)
    return {"model": os.path.basename(model.rstrip("/")), "seconds": round(seconds, 1), "names": names,
            "failure": failure}


# ---------------------------------------------------------------- report

def speaker_style(speakers):
    colors = {"me": "#6b7280", "them": "#868e96"}
    for index, speaker in enumerate(s for s in speakers if s["kind"] == "remote"):
        colors[speaker["id"]] = PALETTE[index % len(PALETTE)]
    return colors


def render_line(line, names, colors):
    color = colors.get(line["speaker"], "#868e96")
    return (f'<div class="line"><span class="who" style="--c:{color}">{html.escape(names.get(line["speaker"], line["speaker"]))}</span>'
            f'<span class="t">{stamp(line["start"])}</span><p>{html.escape(line["text"])}</p></div>')


def write_html(path, live, accurate_lines, speakers, report):
    live_speakers = {s["id"]: s["name"] for s in live["speakers"]}
    live_lines = [
        {"speaker": s["speakerID"], "start": s["start"], "text": s["text"]}
        for s in sorted(live["segments"], key=lambda s: s["start"]) if not s.get("suppressed")
    ]
    live_ids = [s["id"] for s in live["speakers"] if s["id"] not in ("me",)]
    live_colors = {"me": "#6b7280", "them": "#868e96"}
    for index, speaker_id in enumerate(i for i in live_ids if i != "them"):
        live_colors[speaker_id] = PALETTE[index % len(PALETTE)]
    accurate_colors = speaker_style(speakers)
    accurate_names = {s["id"]: s["name"] for s in speakers}

    rows = []
    cursor = 0
    for index, line in enumerate(live_lines):
        until = live_lines[index + 1]["start"] if index + 1 < len(live_lines) else float("inf")
        right = []
        while cursor < len(accurate_lines) and accurate_lines[cursor]["start"] < until:
            right.append(accurate_lines[cursor])
            cursor += 1
        split = len({l["speaker"] for l in right}) > 1
        rows.append(f'<tr class="{"split" if split else ""}"><td>{render_line(line, live_speakers, live_colors)}</td>'
                    f'<td>{"".join(render_line(l, accurate_names, accurate_colors) for l in right)}</td></tr>')

    def speaker_table():
        out = ["<table class='meta'><tr><th>Speaker</th><th>Heuristic</th>"]
        out += [f"<th>{html.escape(r['model'])} ({r['seconds']} s)</th>" for r in report["naming"]["llm"]]
        out.append("</tr>")
        for speaker in speakers:
            if speaker["kind"] != "remote":
                continue
            sid = speaker["id"]
            cells = [report["naming"]["heuristic"].get(sid)] + [r["names"].get(sid) for r in report["naming"]["llm"]]
            row = "".join(
                f"<td>{html.escape(c['name'])}<div class='ev'>{html.escape(c['evidence'])}</div></td>" if c else "<td class='none'>—</td>"
                for c in cells)
            out.append(f"<tr><td><span class='who' style='--c:{accurate_colors[sid]}'>{speaker['name']}</span></td>{row}</tr>")
        out.append("</table>")
        failures = [f"<p class='ev'>{html.escape(r['model'])}: could not parse a JSON answer: {html.escape(r['failure'] or '')}</p>"
                    for r in report["naming"]["llm"] if r.get("failure")]
        return "".join(out + failures)

    t = report["timings"]
    summary = f"""
<table class="meta">
<tr><th></th><th>Live (fast)</th><th>Accurate pass</th></tr>
<tr><td>Call speakers found</td><td>{report['live']['speakers']}</td><td>{report['accurate']['speakers']}</td></tr>
<tr><td>Lines</td><td>{report['live']['lines']}</td><td>{report['accurate']['lines']}</td></tr>
<tr><td>Live lines that now change speaker mid-way</td><td>—</td><td>{report['split_rows']}</td></tr>
<tr><td>Words</td><td>{report['live']['words']}</td><td>{report['accurate']['words']}</td></tr>
<tr><td>Extra time after Stop</td><td>—</td><td>{t['total']:.0f} s for {stamp(report['duration'])} of audio
 (transcribe {t['transcribe']:.0f} s, speakers {t['diarize']:.0f} s{', vocab ' + format(t['vocab'], '.0f') + ' s' if t.get('vocab') else ''})</td></tr>
</table>"""
    vocab = ""
    if report.get("vocab_changes"):
        vocab = "<h2>Custom vocabulary changes</h2><ul>" + "".join(
            f"<li><code>{html.escape(a)}</code> → <code>{html.escape(b)}</code></li>" for a, b in report["vocab_changes"][:60]) + "</ul>"

    page = f"""<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Accurate Pass Comparison</title><style>
:root{{--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--line:#e5e5ea;--split:#fff8e6}}
@media (prefers-color-scheme: dark){{:root:not([data-theme="light"]){{--bg:#1c1c1e;--fg:#f2f2f7;--muted:#98989f;--line:#38383a;--split:#3a3220}}}}
:root[data-theme="dark"]{{--bg:#1c1c1e;--fg:#f2f2f7;--muted:#98989f;--line:#38383a;--split:#3a3220}}
body{{background:var(--bg);color:var(--fg);font:14px/1.5 -apple-system,system-ui,sans-serif;margin:0 auto;max-width:1300px;padding:24px 16px}}
h1{{font-size:20px;margin:0 0 4px}} h2{{font-size:15px;margin:28px 0 8px}} .sub{{color:var(--muted);margin:0 0 16px}}
table{{border-collapse:collapse;width:100%}} td,th{{border-bottom:1px solid var(--line);padding:8px;vertical-align:top;text-align:left}}
.meta{{width:auto;min-width:60%}} .meta th{{font-weight:600}}
.cmp th{{position:sticky;top:0;background:var(--bg);z-index:1}} .cmp td{{width:50%}}
tr.split td:last-child{{background:var(--split)}}
.line+.line{{margin-top:10px}} .line p{{margin:2px 0 0}}
.who{{font-weight:600;color:var(--c)}} .who::before{{content:"";display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--c);margin-right:6px}}
.t{{color:var(--muted);font:12px ui-monospace,monospace;margin-left:8px}} .ev{{color:var(--muted);font-size:12px}} .none{{color:var(--muted)}}
@media (max-width:700px){{.cmp td{{display:block;width:auto}} .cmp thead{{display:none}} .cmp td:first-child{{opacity:.75}}}}
</style></head><body>
<h1>{html.escape(live.get('title') or 'Meeting')}</h1>
<p class="sub">Live transcript (left) and the offline accurate pass (right). Highlighted rows: the accurate pass gives that stretch to more than one speaker.</p>
{summary}
<h2>Who is who</h2>
{speaker_table()}
{vocab}
<h2>Side by side</h2>
<table class="cmp"><thead><tr><th>Live (fast)</th><th>Accurate pass</th></tr></thead><tbody>{''.join(rows)}</tbody></table>
</body></html>"""
    open(path, "w").write(page)
    return sum(1 for row in rows if row.startswith('<tr class="split"'))


# ---------------------------------------------------------------- main

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("meeting", nargs="?", default="latest")
    parser.add_argument("--out", required=True)
    parser.add_argument("--fluidaudio", required=True, help="path to FluidAudio's fluidaudiocli (speaker detection)")
    parser.add_argument("--utterwords", required=True, help="path to the utterwords tool (per-utterance word timings)")
    parser.add_argument("--vocab", help="custom vocabulary, one term per line or 'term: alias, alias'")
    parser.add_argument("--llm", action="append", default=[], help="mlx:<hf repo> or gguf:<file> (repeatable)")
    parser.add_argument("--live", help="live meeting JSON (with --mic/--system, for fixtures)")
    parser.add_argument("--mic")
    parser.add_argument("--system")
    parser.add_argument("--reuse", action="store_true", help="reuse model outputs already in --out")
    parser.add_argument("--rerun-text", action="store_true",
                        help="use the re-run's words (and vocabulary boosting) instead of the live wording")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    live, mic_wav, system_wav = load_live(args)
    timings = {}
    started = time.time()

    segments = sorted(live["segments"], key=lambda seg: seg["start"])
    system_ranges = [[seg["start"], seg["end"]] for seg in segments if seg["channel"] == "system"]
    mic_ranges = [[seg["start"], seg["end"]] for seg in segments
                  if seg["channel"] == "microphone" and not seg.get("suppressed")]

    keep = None if args.rerun_text else {round(seg["start"], 2): seg["text"] for seg in segments}
    system_utts, timings["transcribe"], timings["vocab"] = utterance_words(
        args.utterwords, system_wav, system_ranges, os.path.join(args.out, "system-words.json"), args.vocab, args.reuse, keep)
    mic_utts = []
    if mic_wav and mic_ranges:
        mic_utts, mic_seconds, mic_vocab = utterance_words(
            args.utterwords, mic_wav, mic_ranges, os.path.join(args.out, "mic-words.json"), args.vocab, args.reuse, keep)
        timings["transcribe"] += mic_seconds
        timings["vocab"] += mic_vocab
    vocab_changes = [(r["original"], r["replacement"]) for u in system_utts + mic_utts for r in u["replacements"]]
    # Sanity check: re-running the same model on the same utterance should reproduce the live text.
    live_text = {round(seg["start"], 2): seg.get("originalText", seg["text"]).strip() for seg in segments}
    rerun_same = sum(1 for u in system_utts + mic_utts if live_text.get(round(u["start"], 2)) == u["text"].strip())

    turns, timings["diarize"] = diarize(args.fluidaudio, system_wav, os.path.join(args.out, "system-diarization.json"), reuse=args.reuse)
    timings["total"] = sum(timings.values())

    lines, speakers = assemble(live, mic_utts, system_utts, turns)
    json.dump(to_document(live, lines, speakers), open(os.path.join(args.out, "accurate.json"), "w"), indent=2)

    prompt = naming_prompt(lines, speakers)
    naming = {"heuristic": heuristic_names(lines, speakers), "llm": []}
    for spec in args.llm:
        print(f"naming speakers with {spec} …", file=sys.stderr)
        naming["llm"].append(llm_names(spec, prompt, speakers, args.out))

    live_visible = [s for s in live["segments"] if not s.get("suppressed")]
    report = {
        "meeting": live.get("id"), "title": live.get("title"),
        "duration": duration_of(system_wav),
        "timings": {k: round(v, 1) for k, v in timings.items()},
        "live": {"lines": len(live_visible), "words": sum(len(s["text"].split()) for s in live_visible),
                 "speakers": len({s["speakerID"] for s in live_visible if s["channel"] == "system"})},
        "accurate": {"lines": len(lines), "words": sum(len(l["words"]) for l in lines),
                     "speakers": sum(1 for s in speakers if s["kind"] == "remote")},
        "naming": naming,
        "vocab_changes": vocab_changes,
        "rerun_matches_live": f"{rerun_same}/{len(system_utts) + len(mic_utts)}",
    }
    report["split_rows"] = 0
    report["split_rows"] = write_html(os.path.join(args.out, "comparison.html"), live, lines, speakers, report)
    # write_html needs split_rows for the summary, so render once more with it filled in.
    write_html(os.path.join(args.out, "comparison.html"), live, lines, speakers, report)
    json.dump(report, open(os.path.join(args.out, "report.json"), "w"), indent=2)
    print(json.dumps({k: report[k] for k in ("duration", "timings", "live", "accurate", "split_rows", "rerun_matches_live")}, indent=2))


if __name__ == "__main__":
    main()
