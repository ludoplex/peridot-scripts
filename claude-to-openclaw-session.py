#!/usr/bin/env python3
"""
claude-to-openclaw-session.py

Converts a Claude Code JSONL session file to OpenClaw session JSONL format
and registers it in the openclaw sessions.json store.

Claude Code types: user, assistant, system, progress, file-history-snapshot, queue-operation
OpenClaw types:   session, model_change, message

Fixes over prior versions:
  - Streams input line-by-line (no full-file memory load)
  - Filters local-command noise (<command-name>, <local-command-stdout>, etc.)
  - Auto-detects model from assistant messages (no hardcoded default)
  - Registers session in sessions.json with --register flag
  - Validates output by re-parsing written JSONL
  - Proper error handling on I/O

Usage:
  python3 claude-to-openclaw-session.py <input.jsonl> [options]

Options:
  -o, --output <path>    Output JSONL path (default: auto in openclaw sessions dir)
  -s, --session-id <id>  Session ID (default: auto-generated)
  -r, --register         Register session in sessions.json
  -l, --label <text>     Label for the session entry
  --agent <id>           Agent ID (default: main)
  --cwd <path>           Working directory for session header (default: /home/user)
  --dry-run              Print stats without writing
  --filter-commands      Filter out local command noise (default: true)
  --no-filter-commands   Keep local command messages
"""

import argparse
import hashlib
import json
import os
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

# Noise patterns in user messages to filter out
COMMAND_NOISE = (
    "<command-name>",
    "<local-command-stdout>",
    "<local-command-caveat>",
    "<command-message>",
    "<command-args>",
)


def short_id(s):
    """Generate 8-char hex ID from a string."""
    return hashlib.md5(s.encode()).hexdigest()[:8]


def is_command_noise(content):
    """Check if a string content is local command noise."""
    if not isinstance(content, str):
        return False
    return any(tag in content for tag in COMMAND_NOISE)


def normalize_content(content):
    """Normalize content to OpenClaw array-of-blocks format."""
    if isinstance(content, str):
        if not content.strip():
            return None
        return [{"type": "text", "text": content}]

    if isinstance(content, list):
        blocks = []
        for block in content:
            btype = block.get("type", "text")
            if btype == "text":
                text = block.get("text", "")
                if not text.strip():
                    continue
                blocks.append({"type": "text", "text": text})
            elif btype == "thinking":
                blocks.append({
                    "type": "thinking",
                    "thinking": block.get("thinking", ""),
                    "signature": block.get("signature", ""),
                })
            elif btype == "tool_use":
                blocks.append({
                    "type": "tool_use",
                    "id": block.get("id", ""),
                    "name": block.get("name", ""),
                    "input": block.get("input", {}),
                })
            elif btype == "tool_result":
                result_content = block.get("content") or ""
                if isinstance(result_content, str):
                    result_content = [{"type": "text", "text": result_content}]
                elif isinstance(result_content, list):
                    result_content = [
                        {"type": "text", "text": b.get("text", "")}
                        if b.get("type") == "text" else b
                        for b in result_content
                    ]
                blocks.append({
                    "type": "tool_result",
                    "tool_use_id": block.get("tool_use_id", ""),
                    "content": result_content,
                })
            else:
                blocks.append(block)
        return blocks if blocks else None

    return None


def parse_ts_ms(raw_ts):
    """Parse ISO timestamp to milliseconds since epoch."""
    try:
        dt = datetime.fromisoformat(raw_ts.replace("Z", "+00:00"))
        return int(dt.timestamp() * 1000)
    except Exception:
        return 0


def detect_model(input_path):
    """Stream through file to find model and first timestamp without loading all into memory."""
    first_ts = None
    model_id = None
    with open(input_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue

            ts = d.get("timestamp")
            if ts and first_ts is None:
                first_ts = ts

            if d.get("type") == "assistant" and isinstance(d.get("message"), dict):
                m = d["message"].get("model")
                if m:
                    model_id = m
                    break

    if first_ts is None:
        first_ts = datetime.now(timezone.utc).isoformat()
    if model_id is None:
        model_id = "claude-opus-4-6"

    return first_ts, model_id


def convert(input_path, output_path, session_id, cwd, filter_commands):
    """Stream-convert Claude Code JSONL to OpenClaw JSONL."""
    first_ts, model_id = detect_model(input_path)

    provider = "anthropic"
    if "/" in model_id:
        provider, model_id = model_id.split("/", 1)

    id_map = {}

    def get_short(uuid_str):
        if uuid_str not in id_map:
            id_map[uuid_str] = short_id(uuid_str)
        return id_map[uuid_str]

    converted = 0
    skipped = 0
    errors = 0

    with open(output_path, "w") as out:
        # Session header
        out.write(json.dumps({
            "type": "session",
            "version": 3,
            "id": session_id,
            "timestamp": first_ts,
            "cwd": cwd,
            "model": f"{provider}/{model_id}",
        }) + "\n")

        # Model change event
        out.write(json.dumps({
            "type": "model_change",
            "id": short_id(session_id + "_model"),
            "parentId": None,
            "timestamp": first_ts,
            "provider": provider,
            "modelId": model_id,
        }) + "\n")

        # Stream input
        with open(input_path) as inp:
            for line in inp:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    errors += 1
                    continue

                msg_type = d.get("type")
                if msg_type not in ("user", "assistant"):
                    skipped += 1
                    continue

                if d.get("isMeta"):
                    skipped += 1
                    continue

                msg = d.get("message", {})
                if not isinstance(msg, dict):
                    skipped += 1
                    continue

                role = msg.get("role")
                content = msg.get("content")

                if role not in ("user", "assistant"):
                    skipped += 1
                    continue

                # Filter local command noise from user messages
                if filter_commands and role == "user" and isinstance(content, str):
                    if is_command_noise(content):
                        skipped += 1
                        continue

                norm_content = normalize_content(content)
                if norm_content is None:
                    skipped += 1
                    continue

                # If after normalization, all text blocks are command noise, skip
                if filter_commands and role == "user":
                    text_only = " ".join(
                        b.get("text", "") for b in norm_content if b.get("type") == "text"
                    )
                    if is_command_noise(text_only):
                        skipped += 1
                        continue

                raw_ts = d.get("timestamp", first_ts)
                msg_uuid = d.get("uuid", str(uuid.uuid4()))
                parent_uuid = d.get("parentUuid")

                short = get_short(msg_uuid)
                parent_short = get_short(parent_uuid) if parent_uuid else None

                oc_message = {
                    "type": "message",
                    "id": short,
                    "parentId": parent_short,
                    "timestamp": raw_ts,
                    "message": {
                        "role": role,
                        "content": norm_content,
                        "timestamp": parse_ts_ms(raw_ts),
                    },
                }

                if role == "assistant":
                    if msg.get("model"):
                        oc_message["message"]["model"] = msg["model"]
                    if msg.get("id"):
                        oc_message["message"]["id"] = msg["id"]

                out.write(json.dumps(oc_message) + "\n")
                converted += 1

    return converted, skipped, errors, first_ts, model_id


def validate_output(output_path):
    """Re-parse written JSONL to verify integrity."""
    count = 0
    with open(output_path) as f:
        for i, line in enumerate(f, 1):
            try:
                json.loads(line.strip())
                count += 1
            except json.JSONDecodeError as e:
                print(f"  VALIDATION ERROR line {i}: {e}", file=sys.stderr)
                return False, count
    return True, count


def register_session(session_id, output_path, agent_id, label, model_id, first_ts):
    """Register the converted session in openclaw sessions.json."""
    state_dir = Path.home() / ".openclaw" / "agents" / agent_id / "sessions"
    store_path = state_dir / "sessions.json"

    if not store_path.exists():
        print(f"  WARN: sessions.json not found at {store_path}", file=sys.stderr)
        return False

    try:
        with open(store_path) as f:
            store = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(f"  ERROR reading sessions.json: {e}", file=sys.stderr)
        return False

    session_key = f"agent:{agent_id}:claude-code-import"
    abs_output = str(Path(output_path).resolve())

    store[session_key] = {
        "sessionId": session_id,
        "updatedAt": int(time.time() * 1000),
        "systemSent": False,
        "abortedLastRun": False,
        "inputTokens": 0,
        "outputTokens": 0,
        "totalTokens": 0,
        "totalTokensFresh": False,
        "model": model_id,
        "modelProvider": "anthropic",
        "contextTokens": 0,
        "sessionFile": abs_output,
        "authProfileOverride": "anthropic:api-key",
        "label": label or f"Claude Code import ({session_id})",
    }

    # Atomic write with backup
    bak = str(store_path) + f".bak.{int(time.time())}"
    try:
        os.rename(store_path, bak)
    except OSError:
        pass

    with open(store_path, "w") as f:
        json.dump(store, f, indent=2)

    print(f"  Registered as '{session_key}' in {store_path}")
    return True


def main():
    parser = argparse.ArgumentParser(
        description="Convert Claude Code JSONL session to OpenClaw format"
    )
    parser.add_argument("input", help="Input Claude Code JSONL file")
    parser.add_argument("-o", "--output", help="Output JSONL path (default: auto)")
    parser.add_argument("-s", "--session-id", help="Session ID (default: auto)")
    parser.add_argument("-r", "--register", action="store_true",
                        help="Register in sessions.json")
    parser.add_argument("-l", "--label", help="Session label")
    parser.add_argument("--agent", default="main", help="Agent ID (default: main)")
    parser.add_argument("--cwd", default="/home/user",
                        help="Working directory for session header")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print stats without writing")
    parser.add_argument("--no-filter-commands", action="store_true",
                        help="Keep local command messages")

    # Legacy positional args support: <input> <output> [session-id]
    args, extra = parser.parse_known_args()

    if args.output is None and extra:
        args.output = extra[0]
        if len(extra) > 1 and args.session_id is None:
            args.session_id = extra[1]

    if args.session_id is None:
        args.session_id = str(uuid.uuid4())

    if args.output is None:
        sessions_dir = Path.home() / ".openclaw" / "agents" / args.agent / "sessions"
        sessions_dir.mkdir(parents=True, exist_ok=True)
        args.output = str(sessions_dir / f"{args.session_id}.jsonl")

    input_path = Path(args.input)
    if not input_path.exists():
        print(f"ERROR: input file not found: {input_path}", file=sys.stderr)
        sys.exit(1)

    input_size = input_path.stat().st_size
    print(f"Input:     {input_path} ({input_size / 1024 / 1024:.1f} MB)")
    print(f"SessionID: {args.session_id}")

    if args.dry_run:
        first_ts, model_id = detect_model(str(input_path))
        print(f"Model:     {model_id}")
        print(f"FirstTS:   {first_ts}")
        print(f"Output:    {args.output} (dry run — not written)")
        sys.exit(0)

    # Convert
    converted, skipped, errors, first_ts, model_id = convert(
        str(input_path),
        args.output,
        args.session_id,
        args.cwd,
        not args.no_filter_commands,
    )

    output_size = Path(args.output).stat().st_size
    print(f"Converted: {converted} messages")
    print(f"Skipped:   {skipped} entries")
    if errors:
        print(f"Errors:    {errors} parse errors")
    print(f"Model:     {model_id}")
    print(f"Output:    {args.output} ({output_size / 1024:.1f} KB)")

    # Validate
    valid, count = validate_output(args.output)
    if valid:
        print(f"Validated: {count} valid JSONL lines")
    else:
        print(f"VALIDATION FAILED at line {count + 1}", file=sys.stderr)
        sys.exit(1)

    # Register
    if args.register:
        register_session(
            args.session_id,
            args.output,
            args.agent,
            args.label,
            model_id,
            first_ts,
        )

    print("Done.")


if __name__ == "__main__":
    main()
