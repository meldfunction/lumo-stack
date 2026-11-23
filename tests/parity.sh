#!/bin/zsh
# Parity test: the Linux (Python/zsh) and Windows (PowerShell) scripts must edit configs the same way,
# and all PowerShell must parse. Runs anywhere with Docker (PowerShell runs in a container).
#   tests/parity.sh
emulate -L zsh
cd ${0:A:h:h}
T=$(mktemp -d); trap "rm -rf $T" EXIT
IMG=${PWSH_IMAGE:-mcr.microsoft.com/powershell:lts-alpine-3.20}
ps() { docker run --rm --platform linux/amd64 -v $PWD:/s:ro -v $T:/t -e APPDATA=/t/ps -e LOCALAPPDATA=/t/psdata -e LUMO_CONF=/t/ps \
         $IMG pwsh -NoProfile -Command "$1" 2>&1 | grep -v 'WARNING: The requested image'; }
fail=0; pass() { print "  ok   $1"; }; bad() { print "  FAIL $1"; fail=1; }
CF=0123456789abcdef0123456789abcdef
mkdir -p $T/py $T/ps
TAMER_KEY=lt-x LITELLM_KEY=sk-y python3 linux/cfgtool.py render compose/litellm-config.yaml $T/orig.yaml
cp $T/orig.yaml $T/py/litellm-config.yaml; cp $T/orig.yaml $T/ps/litellm-config.yaml

print "PowerShell parses:"
ps 'foreach ($f in Get-ChildItem /s/windows/*.ps1) { $t=$null;$e=$null; [System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$t,[ref]$e) | Out-Null; if ($e) { "  FAIL $($f.Name): $($e[0].Extent.StartLineNumber): $($e[0].Message)" } else { "  ok   $($f.Name)" } }' \
  | tee $T/parse; grep -q FAIL $T/parse && fail=1

print "Template rendering:"
[[ $(ps '. /s/windows/lib.ps1; (Expand-Template /s/compose/litellm-config.yaml @{TAMER_KEY="lt-x"; LITELLM_KEY="sk-y"}) -eq (Get-Content -Raw /t/orig.yaml)') == True ]] \
  && pass "PowerShell == Python" || bad "PowerShell and Python render differently"

print "Cloudflare on/off:"
CF_ACCOUNT_ID=$CF python3 linux/cfgtool.py cloudflare add $T/py/litellm-config.yaml templates/litellm-cloudflare.yaml
out=$(ps ". /s/windows/lib.ps1; \$S.CF_ACCOUNT_ID='$CF'; Edit-CloudflareBlock add; \"\$(Test-LumoOnly) \$(Test-RoutesAllowed)\"; \$S.CF_ACCOUNT_ID='f'*32; Test-RoutesAllowed")
diff -q $T/py/litellm-config.yaml $T/ps/litellm-config.yaml >/dev/null && pass "add: same file" || bad "add: files differ"
[[ $out == $'False True\nFalse' ]] && pass "routes: Cloudflare allowed only for your account; jail refuses" || bad "route checks: $out"
python3 linux/cfgtool.py cloudflare remove $T/py/litellm-config.yaml x
ps '. /s/windows/lib.ps1; Edit-CloudflareBlock remove' >/dev/null
diff -q $T/py/litellm-config.yaml $T/ps/litellm-config.yaml >/dev/null && pass "remove: same file" || bad "remove: files differ"
diff -q <(grep -v '^$' $T/orig.yaml) <(grep -v '^$' $T/ps/litellm-config.yaml) >/dev/null && pass "remove restores the original" || bad "remove left changes"

print "Linux scripts parse:"
for f in linux/lumo linux/install linux/lib.zsh tests/parity.sh; do zsh -n $f && pass $f || bad $f; done
python3 -m py_compile linux/cfgtool.py && pass linux/cfgtool.py || bad linux/cfgtool.py

(( fail )) && { print "PARITY: FAILED"; exit 1; } || print "PARITY: all ok"
