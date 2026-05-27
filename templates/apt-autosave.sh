#!/bin/bash
# apt-autosave — transparent apt / apt-get wrapper.
#
# Bind-mounted into the container by run.sh and installed to /usr/local/bin by
# entrypoint.sh (which precedes /usr/bin in PATH, so this shadows the real
# binaries). On a successful `install` it records the explicitly-requested
# packages into the mounted config.local.env (host file), so ad-hoc installs
# persist — they're reinstalled automatically on the next start.
#
# Because it's a bind-mount, edits here take effect on the next `./run.sh` with
# NO image rebuild. Disable recording at runtime with APT_AUTOSAVE=false.
real="/usr/bin/$(basename "$0")"
"$real" "$@"; rc=$?
[ $rc -eq 0 ] || exit $rc
[ "${APT_AUTOSAVE:-true}" = "true" ] || exit 0
[ -w /opt/config.local.env ] || exit 0
sub=""; pkgs=(); skip=0
for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in
        -o|-t|-c|-a) skip=1; continue ;;
        -*) continue ;;
    esac
    if [ -z "$sub" ]; then sub="$a"; continue; fi
    pkgs+=("$a")
done
[ "$sub" = "install" ] && [ ${#pkgs[@]} -gt 0 ] || exit 0
var="APT_PACKAGES_$(printf '%s' "${DS_PROFILE:-a}" | tr '[:lower:]' '[:upper:]')"
cur=$(bash -c "source /opt/config.local.env 2>/dev/null; printf '%s' \"\${$var}\"")
new=()
for p in "${pkgs[@]}"; do
    case " $cur " in *" $p "*) ;; *) new+=("$p") ;; esac
done
[ ${#new[@]} -gt 0 ] || exit 0
printf '%s="${%s:-} %s"\n' "$var" "$var" "${new[*]}" >> /opt/config.local.env
echo "[apt-autosave] recorded to config.local.env ($var): ${new[*]}"
