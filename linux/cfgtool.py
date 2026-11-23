#!/usr/bin/env python3
"""Config helper for the Linux scripts (no third-party modules).
  cfgtool.py render <template> <dest>            fill {{VARS}} from the environment, write 0600
  cfgtool.py cloudflare add|remove <cfg> <tpl>   manage the cf-* block (needs CF_ACCOUNT_ID for add)
"""
import os, re, sys

def render(tpl, dest):
    out = re.sub(r"\{\{([A-Z_]+)\}\}", lambda m: os.environ[m.group(1)], open(tpl).read())
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(out)
    os.chmod(dest, 0o600)

def cloudflare(mode, cfg, tpl):
    s = open(cfg).read()
    s = re.sub(r"\n[ \t]*# >>> cloudflare[^\n]*\n[\s\S]*?# <<< cloudflare <<<[^\n]*", "", s)
    s = re.sub(r"\n[ \t]*# >>> cloudflare-settings[^\n]*\n[\s\S]*?# <<< cloudflare-settings <<<[^\n]*", "", s)
    s = re.sub(r"\n*# >>> cloudflare-router[^\n]*\n[\s\S]*?# <<< cloudflare-router <<<[^\n]*\n?", "\n", s)
    if mode == "add":
        models = open(tpl).read().replace("{{CF_ACCOUNT_ID}}", os.environ["CF_ACCOUNT_ID"]).rstrip("\n")
        models = models.replace("Key from the Keychain via start.sh.", "Key from the secrets folder.")
        settings = ("  # >>> cloudflare-settings (managed by lumo cloudflare) >>>\n"
                    "  # Translate /v1/messages to chat/completions; Workers AI rejects the Responses API.\n"
                    "  use_chat_completions_url_for_anthropic_messages: true\n"
                    "  # <<< cloudflare-settings <<<")
        if "\nlitellm_settings:" not in s:
            sys.exit("config has no litellm_settings: section")
        s = s.replace("\nlitellm_settings:", "\n" + models + "\n\nlitellm_settings:\n" + settings, 1)
        if "\nrouter_settings:" in s:
            sys.exit("config already has router_settings:; merge the cloudflare fallbacks by hand")
        s = s.rstrip("\n") + ("\n\n# >>> cloudflare-router (managed by lumo cloudflare) >>>\n"
            "router_settings:\n  num_retries: 1\n  timeout: 120\n  fallbacks:\n"
            "    - cf-llama4: [cf-gptoss, cf-mistral, lumo]\n    - cf-gptoss: [cf-mistral, cf-gemma4, lumo]\n"
            "    - cf-mistral: [cf-gptoss, cf-gemma4, lumo]\n    - cf-gemma4: [cf-gptoss, cf-mistral, lumo]\n"
            "    - cf-smart: [cf-mistral, lumo]\n    - cf-fast: [cf-mistral, lumo]\n"
            "# <<< cloudflare-router <<<\n")
        s = re.sub(r"\n{3,}", "\n\n", s)
    fd = os.open(cfg, os.O_WRONLY | os.O_TRUNC)
    with os.fdopen(fd, "w") as f:
        f.write(s)

if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["render"] and len(a) == 3:
        render(a[1], a[2])
    elif a[:1] == ["cloudflare"] and len(a) == 4 and a[1] in ("add", "remove"):
        cloudflare(a[1], a[2], a[3])
    else:
        sys.exit(__doc__)
