#!/usr/bin/env python3
# labels: spike, needs-review, sensitive (reads the API key; never prints it)
"""Smoke test for the Muse Spark commander's tool calling before running it on the phone.

Mirrors the app's request (Sightline/Sightline/API/MuseAgent.swift, SightlineCore/Agent.swift):
Responses API + function tools + previous_response_id. Tools are faked locally:
  - case "unparsed": user says "I'm thirsty" (effort minimal, no image)
  - case "ambiguous": two cups, user wants the one on the left (effort medium, with a spike image)
Prints each tool call and logs every call to logs/api_calls.csv. Cost: a few cents.

Usage (from sightline/):
  .venv/bin/python spike/agent_spike.py                      # server keeps history (previous_response_id)
  .venv/bin/python spike/agent_spike.py --manual-history     # we resend the history ourselves
  add --state-in-prompt to put get_state's result in the first message (saves one turn)
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from model_api_spike import BASE_URL, IMAGES_DIR, SPARK_INPUT_PER_M, SPARK_OUTPUT_PER_M, downscale, load_api_key, log_call, to_data_url  # noqa: E402
from openai import OpenAI  # noqa: E402

MODEL = "muse-spark-1.3"

def tool(name, description, props=None, required=None):
    return {"type": "function", "name": name, "description": description,
            "parameters": {"type": "object", "properties": props or {}, "required": required or []}}

# Keep in sync with AgentTools.definitions / instructions in Agent.swift.
TOOLS = [
    tool("get_state", "Live state: what the user said, the target name, SAM candidates placed relative to the user's chest (right/up/forward in cm), SAM calls left, tracking."),
    tool("find_object", "Segment an object by a short noun phrase on the current camera frame (costs one SAM call). Returns the candidates found.",
         {"noun": {"type": "string", "description": "1-3 word noun phrase, e.g. 'water bottle'"}}, ["noun"]),
    tool("select_target", "Lock one candidate as the target and start hand guidance. Ends your turn.", {"candidate_id": {"type": "string"}}, ["candidate_id"]),
    tool("say", "Speak one short sentence to the user (blind; plain words, no visual references like colours unless they asked).", {"text": {"type": "string"}}, ["text"]),
    tool("ask_user", "Ask the user a short question and wait for the spoken answer, returned as the result.", {"question": {"type": "string"}}, ["question"]),
    tool("stop", "End the search."),
]
INSTRUCTIONS = (
    "You are Sightline, a voice guide that helps a blind person find and grab objects at home. "
    "You act only through tools. The phone is worn on the chest; positions are in cm relative to it: "
    "right_cm > 0 is to the user's right, up_cm > 0 is higher, forward_cm is distance ahead. "
    "Rules: keep spoken sentences under 15 words; say \"not sure\" instead of guessing; never give medical advice; "
    "never describe the scene at length. Pick a target only if it clearly matches what the user wants; "
    "if two candidates are equally plausible, ask_user which one using left/right/near/far, not colours. "
    "Finish by calling select_target, or stop after telling the user why."
)

def state(user_said, target, candidates):
    return json.dumps({"phase": "locating", "user_said": user_said, "target_name": target,
                       "candidates": candidates, "sam_calls_left": 4, "tracking": "normal"})

def run(client, name, prompt, image_url, effort, fake, manual=False, initial_state=None):
    mode = "manual history" if manual else "previous_response_id"
    print(f"\n=== {name} (effort {effort}, {mode}{', state in prompt' if initial_state else ''}) ===")
    text = INSTRUCTIONS + "\n\n" + prompt
    if initial_state:
        text += "\n\nCurrent state (same as get_state): " + initial_state
    content = [{"type": "input_text", "text": text}]
    if image_url:
        content.append({"type": "input_image", "image_url": image_url})
    inp = [{"type": "message", "role": "user", "content": content}]
    prev = None
    history = list(inp)
    total_ms = 0.0
    for turn in range(6):
        kwargs = dict(model=MODEL, input=inp, tools=TOOLS, parallel_tool_calls=False,
                      reasoning={"effort": effort}, max_output_tokens=1024 if effort == "minimal" else 4096)
        if manual:
            kwargs["input"] = history
        elif prev:
            kwargs["previous_response_id"] = prev
        t0 = time.perf_counter()
        r = client.responses.create(**kwargs)
        ms = (time.perf_counter() - t0) * 1000
        total_ms += ms
        u = r.usage
        cost = u.input_tokens / 1e6 * SPARK_INPUT_PER_M + u.output_tokens / 1e6 * SPARK_OUTPUT_PER_M
        log_call(f"agent_spike_{name}", f"{MODEL}/{effort}", "agent", ms, u.input_tokens, u.output_tokens, cost)
        print(f"turn {turn}: {ms:.0f} ms, {u.input_tokens} in / {u.output_tokens} out tokens, ${cost:.4f}")
        prev = r.id
        calls = [i for i in r.output if i.type == "function_call"]
        if not calls:
            print(f"  text: {r.output_text!r}")
            print(f"total {total_ms/1000:.1f} s")
            return
        outs = []
        for c in calls:
            print(f"  call {c.name}({c.arguments})")
            result = fake(c.name, json.loads(c.arguments or "{}"))
            if result is None:
                print("  -> ends the turn")
                print(f"total {total_ms/1000:.1f} s")
                return
            print(f"  -> {result}")
            outs.append({"type": "function_call_output", "call_id": c.call_id, "output": result})
        inp = outs
        history += [{"type": "function_call", "call_id": c.call_id, "name": c.name, "arguments": c.arguments} for c in calls]
        history += outs
    print("turn limit")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manual-history", action="store_true")
    ap.add_argument("--state-in-prompt", action="store_true")
    args = ap.parse_args()
    client = OpenAI(base_url=BASE_URL, api_key=load_api_key())

    def unparsed(name, args):
        if name == "get_state":
            return state("I'm thirsty, is there anything to drink", None, [])
        if name == "find_object":
            return state("I'm thirsty, is there anything to drink", args["noun"],
                         [{"id": "0", "confidence": 0.91, "right_cm": 12, "up_cm": -35, "forward_cm": 45, "width_fraction": 0.1, "height_fraction": 0.2}])
        if name in ("say", "ask_user"):
            return "ok" if name == "say" else "yes"
        return None  # select_target / stop end the turn
    run(client, "unparsed", 'The user said: "I\'m thirsty, is there anything to drink". Work out which object they want, find it and select it. '
        "If it is not a request to find an object, say so briefly and stop.", None, "minimal", unparsed,
        args.manual_history, state("I'm thirsty, is there anything to drink", None, []) if args.state_in_prompt else None)

    two_cups = [{"id": "0", "confidence": 0.82, "right_cm": -20, "up_cm": -30, "forward_cm": 40, "width_fraction": 0.12, "height_fraction": 0.18},
                {"id": "1", "confidence": 0.79, "right_cm": 18, "up_cm": -30, "forward_cm": 55, "width_fraction": 0.1, "height_fraction": 0.15}]

    def ambiguous(name, args):
        if name in ("get_state", "find_object"):
            return state("find the cup", "cup", two_cups)
        if name == "ask_user":
            return "the one on my left"
        if name == "say":
            return "ok"
        return None
    image = sorted(p for p in IMAGES_DIR.iterdir() if p.suffix.lower() in {".heic", ".jpg", ".jpeg", ".png"})[0]
    run(client, "ambiguous", 'The user said: "find the cup". SAM found several cup candidates '
        "(call get_state; the photo is what the chest camera sees). Select the one they mean, or ask them.",
        to_data_url(downscale(image)), "medium", ambiguous,
        args.manual_history, state("find the cup", "cup", two_cups) if args.state_in_prompt else None)

if __name__ == "__main__":
    main()
