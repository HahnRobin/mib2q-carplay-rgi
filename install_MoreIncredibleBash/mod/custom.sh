#!/bin/sh
# M.I.B. -> Advanced Settings -> Run Custom Script.
# QNX 6.5 /bin/sh is ksh (pdksh) - this script stays inside its portable subset.
# Copy into /mod/ on the M.I.B. SD; resources live in /mod/carplay/.
#
# Install:
#   - our files: the hook .so, maneuver_render, its flag atlas, the carplay_*.sh
#     scripts and the jar. No stock file is replaced. Two layouts, both accepted:
#       * flat: the release assets dropped straight into carplay/ - each known
#         name goes to its fixed on-unit path (see flat_dest);
#       * tree: carplay/root/<on-unit path> copied onto "/".
#   - in-place runtime patches (per-unit / stock-dependent), done here:
#       * smartphone_integrator.json  - replace the "carplay" child by path
#       * dio_manager.json            - register the iAP2 route-guidance message IDs
# No CRC gymnastics, no lock dir. Atomic renames. Upgrade-safe: a stock backup of
# each edited config is kept once so uninstall restores the original.
# Copyright (c) 2026 LuKa (@LuKa_dev)
set -u
PATH=/proc/boot:/bin:/usr/bin:/usr/sbin:/sbin:/mnt/app/armle/bin:/mnt/app/armle/usr/bin
export PATH
unset LD_PRELOAD

case $0 in */*) D=${0%/*} ;; *) D=. ;; esac
D=$(cd "$D" && pwd) || exit 1

# GEM runs on MMX. Forward a manual RCC launch (the MMX-local check below is false
# once we are on MMX, so this never loops).
if [ ! -d /mnt/app/eso/hmi/lsd ] && [ -d /net/mmx/mnt/app/eso/hmi/lsd ]; then
    exec on -f mmx /bin/sh "$D/custom.sh" "$@"
fi

RES=$D/carplay                 # resources (carplay_child.json, flat release assets)
ROOT=$RES/root                 # optional "/" tree
ACTION=${1:-install}

HOOKS=/mnt/app/root/hooks
JARS=/mnt/app/eso/hmi/lsd/jars
# Flat release asset -> on-unit path. Anything else in carplay/ is ignored.
flat_dest() {
    case $1 in
        libcarplay_hook.so|maneuver_render|flag_atlas.rgba) echo "$HOOKS/$1" ;;
        carplay_startup.sh|carplay_processes.sh|carplay_cleanup.sh) echo "$HOOKS/$1" ;;
        carplay_hook.jar) echo "$JARS/$1" ;;
        *) return 1 ;;
    esac
}

CFG=/mnt/system/etc/eso/production/smartphone_integrator.json
DIO=/mnt/system/etc/eso/production/dio_manager.json

mode_for() {
    case $1 in
        *.so|*.so.*)       echo 755 ;;
        */maneuver_render) echo 755 ;;
        *.sh)              echo 755 ;;
        *)                 echo 644 ;;  # atlas, .jar
    esac
}
# count occurrences of $2 in $1 (ksh-safe, no external tools)
count_char() { n=0; rest=$1; while :; do case $rest in *"$2"*) rest=${rest#*"$2"}; n=$((n+1)) ;; *) break ;; esac; done; echo "$n"; }

backup_once() { [ -e "$2" ] || cp -p "$1" "$2" || { echo "FAILED backup $2"; return 1; }; }

# ---- smartphone_integrator.json: replace the "carplay" child by path ----------
patch_json() {
    FRAG=$RES/carplay_child.json
    [ -f "$CFG" ]  || { echo "  WARN no SI config at $CFG - skipping json"; return 0; }
    [ -f "$FRAG" ] || { echo "  WARN no carplay_child.json resource - skipping json"; return 0; }
    tmp=$CFG.carplay-new.$$
    : > "$tmp" || { echo "FAILED create $tmp"; return 1; }
    state=copy; hits=0; depth=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$state" = copy ]; then
            case $line in
                *'"carplay"'*:*)
                    set -f; set -- $line; set +f
                    compact=; for part in "$@"; do compact=$compact$part; done
                    [ "$compact" = '"carplay":{' ] || { echo "  WARN unsupported carplay layout"; rm -f "$tmp"; return 1; }
                    hits=$((hits+1)); state=skip; depth=0 ;;
                *) printf '%s\n' "$line" >> "$tmp"; continue ;;
            esac
        fi
        opens=$(count_char "$line" '{'); closes=$(count_char "$line" '}')
        depth=$((depth + opens - closes))
        if [ "$depth" -le 0 ]; then
            printf '        "carplay": ' >> "$tmp"
            cat "$FRAG" >> "$tmp"
            printf '%s\n' "${line##*\}}" >> "$tmp"       # keep the trailing comma
            state=copy
        fi
    done < "$CFG"
    [ "$hits" = 1 ] && [ "$state" = copy ] || { echo "  WARN expected one carplay child (hits=$hits)"; rm -f "$tmp"; return 1; }
    o=$(grep -c '"exec"' "$CFG"); n=$(grep -c '"exec"' "$tmp")
    [ "$o" = "$n" ] || { echo "  WARN SI child count changed ($o->$n)"; rm -f "$tmp"; return 1; }
    grep -q 'carplay_startup.sh' "$CFG" || backup_once "$CFG" "$CFG.carplay-stock" || { rm -f "$tmp"; return 1; }
    chmod 644 "$tmp"; mv -f "$tmp" "$CFG" && echo "  SI json patched"
}

# ---- dio_manager.json: register the route-guidance message IDs ----------------
# The Cinemo iAP2 SDK passes only listed messages. The hook's Identify patch makes
# iOS offer route guidance but does not touch these lists. The file carries "##"
# comment lines, so it is edited as text: IDs are appended before the list's "]".
add_ids() {   # $1 = line holding one list, rest = IDs; prints the new line
    l=$1; shift
    for id in "$@"; do
        case $l in *"\"$id\""*) continue ;; esac
        head=${l%%]*}; tail=${l#*]}
        case $head in *'[') l=$head'"'$id'"]'$tail ;; *) l=$head', "'$id'"]'$tail ;; esac
    done
    printf '%s\n' "$l"
}
patch_dio() {
    [ -f "$DIO" ] || { echo "  WARN no $DIO - route guidance will not arrive"; return 0; }
    tmp=$DIO.carplay-new.$$; : > "$tmp" || { echo "FAILED create $tmp"; return 1; }
    sent=0; recv=0; changed=0
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
            *'##'*) new=$line ;;
            *'"MessagesSentByAccessory":['*']'*)
                sent=$((sent+1)); new=$(add_ids "$line" 0x5200 0x5203) ;;
            *'"MessagesReceivedFromDevice":['*']'*)
                recv=$((recv+1)); new=$(add_ids "$line" 0x5201 0x5202 0x5204) ;;
            *) new=$line ;;
        esac
        [ "$new" = "$line" ] || { line=$new; changed=1; }
        printf '%s\n' "$line" >> "$tmp"
    done < "$DIO"
    if [ "$sent" != 1 ] || [ "$recv" != 1 ]; then
        echo "  WARN dio_manager.json: lists sent=$sent recv=$recv (expected 1/1); left as-is"; rm -f "$tmp"; return 1
    fi
    n=0; for id in 0x5200 0x5201 0x5202 0x5203 0x5204; do grep -q "\"$id\"" "$tmp" && n=$((n+1)); done
    [ "$n" = 5 ] || { echo "  WARN dio_manager.json: only $n/5 IDs after edit; left as-is"; rm -f "$tmp"; return 1; }
    if [ "$changed" = 0 ]; then echo "  dio_manager.json IDs already registered"; rm -f "$tmp"; return 0; fi
    backup_once "$DIO" "$DIO.carplay-stock" || { rm -f "$tmp"; return 1; }
    chmod 644 "$tmp"; mv -f "$tmp" "$DIO" && echo "  dio_manager.json route-guidance IDs registered"
}

echo "custom.sh: CarPlay $ACTION"
echo "Remounting app and system read-write..."
mount -uw /mnt/app    2>/dev/null || true
mount -uw /mnt/system 2>/dev/null || true

# Payload as "source|destination" lines (/tmp is /dev/shmem: no directories there).
LIST=/tmp/carplay_files.$$
: > "$LIST" || { echo "FAILED create $LIST"; exit 1; }
for f in "$RES"/*; do
    [ -f "$f" ] || continue
    dest=$(flat_dest "${f##*/}") && printf '%s|%s\n' "$f" "$dest" >> "$LIST"
done
if [ -d "$ROOT" ]; then
    ( cd "$ROOT" && find . -type f ) 2>/dev/null | while IFS= read -r f; do
        case $f in */._*|*/.DS_Store) continue ;; esac   # macOS junk from a Mac-written card
        printf '%s|%s\n' "$ROOT/${f#./}" "/${f#./}"
    done >> "$LIST"
fi
[ -s "$LIST" ] || { echo "no payload in $RES (release files or root/ tree)"; rm -f "$LIST"; exit 1; }

case $ACTION in
install)
    while IFS='|' read -r f dest; do
        dir=${dest%/*}
        mkdir -p "$dir" || { echo "FAILED mkdir $dir"; rm -f "$LIST"; exit 1; }
        tmp=$dest.carplay-new.$$
        cp -p "$f" "$tmp" || { echo "FAILED copy $tmp"; rm -f "$tmp" "$LIST"; exit 1; }
        chmod $(mode_for "$dest") "$tmp" || { echo "FAILED chmod $tmp"; rm -f "$tmp" "$LIST"; exit 1; }
        mv -f "$tmp" "$dest" || { echo "FAILED activate $dest"; rm -f "$tmp" "$LIST"; exit 1; }
        echo "  $dest"
    done < "$LIST"
    rm -f "$LIST"
    patch_json
    patch_dio
    sync
    echo "DONE (install). Reboot the HU to load."
    ;;
uninstall)
    while IFS='|' read -r f dest; do
        rm -f "$dest"
    done < "$LIST"
    rm -f "$LIST"
    # restore in-place patched configs
    [ -e "$CFG.carplay-stock" ] && mv -f "$CFG.carplay-stock" "$CFG"
    [ -e "$DIO.carplay-stock" ] && mv -f "$DIO.carplay-stock" "$DIO"
    sync
    echo "DONE (uninstall). Reboot the HU."
    ;;
*)
    rm -f "$LIST"
    echo "usage: custom.sh [install|uninstall]"; exit 2
    ;;
esac
