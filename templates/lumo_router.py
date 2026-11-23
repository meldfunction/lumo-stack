"""
LiteLLM pre-call hook: Lumo as a router layer that never spends Proton's weekly quota on
the wrong work.

Callers keep asking for lumo / lumo-max / lumo-lite. This hook decides where the request goes:

  stays on Lumo   short Q&A: no tools, a few messages, a modest prompt, budget left
  goes to cf-*    agent / tool work, long prompts, or Lumo's budget or quota used up
  refused         a request marked private when Lumo can't take it (never sent to a cloud model)

Proton counts *messages*, not tokens, and doesn't publish the cap. Our estimate is
~100 messages/week (see LUMO_WEEKLY_EST); automated traffic may use LUMO_ROUTER_BUDGET of
them per rolling 7 days, leaving the rest for the person's own use of Lumo's apps, which
share the same quota and are invisible to us. When Proton answers "weekly quota" (code
2028), Lumo is marked exhausted and probed again every LUMO_PROBE_HOURS.

Private: send header `x-lumo-private: 1` (or metadata {"lumo_private": true}); such requests
are never rerouted to a cloud model.

State (for dashboards / `lumo status`): ~/.cache/lumo-router.json, or $LUMO_ROUTER_STATE.
Log: lumo-router.log next to it (macOS: ~/Library/Logs), model names and reasons only, never content.
Part of Lumo Stack: templates/lumo_router.py. Off switch: remove it from `callbacks` in the LiteLLM config.
"""
import json
import os
import time

from fastapi import HTTPException
from litellm.integrations.custom_logger import CustomLogger

# Paths: env overrides (the Compose image sets them to its /data volume), else per-user defaults.
STATE = os.environ.get("LUMO_ROUTER_STATE") or os.path.expanduser("~/.cache/lumo-router.json")
_logs = os.path.expanduser("~/Library/Logs")
LOG = os.environ.get("LUMO_ROUTER_LOG") or os.path.join(_logs if os.path.isdir(_logs) else os.path.dirname(STATE), "lumo-router.log")
WEEK = 7 * 24 * 3600

WEEKLY_EST = int(os.environ.get("LUMO_WEEKLY_EST", "100"))     # Proton's cap, estimated (unpublished)
BUDGET = int(os.environ.get("LUMO_ROUTER_BUDGET", "60"))       # what automated traffic may use per 7 days
QA_MAX_TOKENS = int(os.environ.get("LUMO_QA_MAX_TOKENS", "8000"))
QA_MAX_MESSAGES = int(os.environ.get("LUMO_QA_MAX_MESSAGES", "12"))
PROBE_HOURS = float(os.environ.get("LUMO_PROBE_HOURS", "6"))
FALLBACK = {"lumo": "cf-gptoss", "lumo-max": "cf-gptoss", "lumo-lite": "cf-mistral"}


def _load():
    try:
        with open(STATE) as f:
            s = json.load(f)
    except (OSError, ValueError):
        s = {}
    now = time.time()
    s["sent"] = [t for t in s.get("sent", []) if now - t < WEEK]
    s.setdefault("rerouted", {})
    return s


def _save(s):
    s.update(weekly_est=WEEKLY_EST, budget=BUDGET, used_7d=len(s["sent"]), updated=time.time(),
             unit="messages", note="Proton counts messages, not tokens; the cap is unpublished, ~100/week is our estimate")
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f)
    os.replace(tmp, STATE)


def _log(msg):
    try:
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except OSError:
        pass


def _text_len(x):
    if isinstance(x, str):
        return len(x)
    if isinstance(x, list):
        return sum(_text_len(i) for i in x)
    if isinstance(x, dict):
        return sum(_text_len(v) for k, v in x.items() if k not in ("type", "id", "cache_control"))
    return 0


def _is_private(data):
    hdrs = ((data.get("proxy_server_request") or {}).get("headers") or {})
    if str(hdrs.get("x-lumo-private", "")).strip() == "1":
        return True
    meta = data.get("metadata") or {}
    return bool(meta.get("lumo_private"))


def _fallback_exists(model):
    try:
        from litellm.proxy.proxy_server import llm_router
        return model in (llm_router.model_names if llm_router else [])
    except Exception:
        return False


class LumoRouter(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data: dict, call_type):
        model = str(data.get("model", ""))
        if model not in FALLBACK:
            return data
        s = _load()
        now = time.time()
        private = _is_private(data)
        msgs = data.get("messages") or []
        est_tokens = (_text_len(msgs) + _text_len(data.get("system")) + _text_len(data.get("tools"))) // 4

        reason = None
        if s.get("exhausted_until", 0) > now:
            reason = "quota (Proton said weekly quota reached)"
        elif len(s["sent"]) >= BUDGET:
            reason = f"budget ({len(s['sent'])}/{BUDGET} Lumo messages used this week)"
        elif data.get("tools") and not private:
            reason = "agent/tool request"
        elif not private and (est_tokens > QA_MAX_TOKENS or len(msgs) > QA_MAX_MESSAGES):
            reason = f"long request (~{est_tokens} tokens, {len(msgs)} messages)"

        if reason is None:
            s["sent"].append(now)
            s["last_lumo"] = now
            _save(s)
            _log(f"lumo     {model} private={int(private)} ~{est_tokens}tok used={len(s['sent'])}/{BUDGET}")
            return data

        if private:
            _save(s)
            _log(f"refused  {model} private=1 reason={reason}")
            raise HTTPException(status_code=429, detail=f"Lumo can't take this private request: {reason}. "
                                "Private requests are never sent to a cloud model; try again later.")
        target = FALLBACK[model]
        if not _fallback_exists(target):
            if reason.startswith(("quota", "budget")):
                _save(s)
                _log(f"refused  {model} reason={reason} (no {target} configured)")
                raise HTTPException(status_code=429, detail=f"Lumo unavailable: {reason}; no Cloudflare fallback configured.")
            s["sent"].append(now)
            _save(s)
            _log(f"lumo     {model} (wanted {target} for {reason}, not configured) used={len(s['sent'])}/{BUDGET}")
            return data
        data["model"] = target
        key = reason.split(" ")[0]
        s["rerouted"][key] = s["rerouted"].get(key, 0) + 1
        _save(s)
        _log(f"reroute  {model} -> {target} reason={reason}")
        return data

    async def async_post_call_failure_hook(self, request_data, original_exception, user_api_key_dict, traceback_str=None):
        err = str(original_exception)
        if "weekly quota" in err.lower() or "2028" in err:
            s = _load()
            now = time.time()
            if not s.get("quota_hit_at") or s.get("quota_back_at", 0) > s["quota_hit_at"]:
                s["quota_hit_at"] = now          # a new exhaustion (not a repeat probe)
                _log(f"quota    Proton says weekly quota reached; Lumo paused, probing every {PROBE_HOURS}h")
            s["exhausted_until"] = now + PROBE_HOURS * 3600
            _save(s)

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        # A Lumo answer after an exhaustion = the quota came back; record when (learns the reset time).
        if not str((kwargs or {}).get("model", "")).startswith(("lumo", "openai/lumo")):
            return
        s = _load()
        if s.get("quota_hit_at") and s.get("quota_back_at", 0) < s["quota_hit_at"]:
            s["quota_back_at"] = time.time()
            s["exhausted_until"] = 0
            _log(f"quota    Lumo answered again; quota was out for {(s['quota_back_at'] - s['quota_hit_at']) / 3600:.1f}h")
            _save(s)


router = LumoRouter()
