#!/bin/bash

#set -x # debug
set -o pipefail

verze=2.0-rc6

export LVM_SUPPRESS_FD_WARNINGS=1
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log() {
    logger "$0" "$*"
    printf '%b\n' "$*"
}
error() { log "ERROR: $*" >&2; }
fatal() { error "$@"; exit 1; }

chyba() {
    log "CHYBA:" $(date +%Y%m%d-%T) " nastala chyba v" "$@"
    vysledek=1
}

info() {
    log "INFO:" $(date +%Y%m%d-%T) "$@"
}

cfgname=$(basename "${0}" ".${0##*.}")                                # jmeno scriptu bez koncovky
cfgpath=/etc/$cfgname

paticka="создан с ${cfgname^^} версии $verze"
paticka="vytvořeno programem ${cfgname^^} verze $verze"

datumutc=$(date --utc +%Y%m%d-%H%M%S)
datum=$(date +%Y%m%d)

cfgfile="$cfgpath/$cfgname.cfg"
[ -r $cfgfile ] && . $cfgfile || fatal "chybí konfigurační soubor " $cfgfile

cfglist="$cfgpath/$cfgname.seznam"
[ -r $cfglist ] && . $cfglist || fatal "chybí seznam virtuálů " $cfglist

mainprog="$(dirname $0)/$cfgname.main.sh"
[ -r $mainprog ] && . $mainprog || fatal "chybí hlavní část programu " $mainprog

if [ $# -lt 1 ]; then fatal "chybý parametr " $'\n'"$(paramhelp)" ; fi
mainkod=${1,,}
paramcheck $mainkod || fatal "chybný parametr " $1 $'\n'"$(paramhelp)"

#exit

vysledek=0
errl=0

jmenologu=$cestalogu/$cfgname.$mainkod.$datumutc.log
mkdir -p $cestalogu
touch $jmenologu
find $cestalogu/$cfgname.$mainkod.* -mtime +$starilogu -exec rm {} \; # promazani starych logu
exec 3> >(trap '' int; tee -a "$jmenologu")                           # presmerovani do souboru a na consolu

tmpfile=$(mktemp $tmppath/$cfgname.XXXXXX)

cleanup() {
    case "$mainkod" in
        bs) lvremove -f $bs_cesta/*.$bs_koncovka 2>/dev/null
        ;;
        nas) lvremove -f $nas_cesta/*.$nas_koncovka 2>/dev/null
        ;;
    esac
    true
}

cleanupfull() {
    cleanup
    rm "$tmpfile"
    true
}

exitint() {
    exec 3>&-
#    trap '' pipe
#    exec 1>-
#    exec 2>-
    text="$(<"$tmpfile")"
    cleanupfull
    log "ctrl-c:" $(date +%y%m%d-%t) "$virtual/$co \n$text"
    exit 130
}

trap exitint int

poslimail() {
    local suffix
    local filesize
    suffix=
    filesize=$(stat --printf="%s" $jmenologu)
    if [ $filesize -gt $mailmaxsize ]; then
#        rar a -ep $jmenologu.rar $jmenologu
        bzip2 --best --keep $jmenologu
        suffix=".bz2"
# testovaci        cp $jmenologu $jmenologu$suffix
        filesize=$(stat --printf="%s" $jmenologu$suffix)
    fi
    if [ $filesize -gt $mailmaxsize ]; then
        chyba "i zpakovaný log je příliš velký: $(numfmt --to=iec-i --suffix=B --format="%.0f" $filesize)"
        text="zpakovaný log $jmenologu je příliš velký: $(numfmt --to=iec-i --suffix=B --format="%.0f" $filesize)\n\n"$text
        printf '%b\n' "$text" | mutt -e "set use_envelope_from = yes" -e "my_hdr from:$mailfrom" -s "$subject" -- $mailto
    else
        printf '%b\n' "$text" | mutt -e "set use_envelope_from = yes" -e "my_hdr from:$mailfrom" -s "$subject" -a $jmenologu$suffix -- $mailto
    fi
    if [ "$suffix" != "" ]; then rm $jmenologu$suffix; fi
}

main 2>&1 >&3
errl=$?
exec 3>&-
if [ $errl -eq 130 ]; then exit 130; fi # ctrl-c
if [ $errl -eq 0 ]; then
    subject="${cfgname^^}-$datum: OK - zálohování je v pořádku - $main_subject"
    text=$(egrep "^INFO" $jmenologu)
else
    subject="${cfgname^^}-$datum: ERR - zálohování skončilo chybou - $main_subject"
    text=$(egrep "^INFO|^ERROR|^CHYBA" $jmenologu)
fi
text=$text$'\n'$'\n'$paticka

poslimail

#printf '%b\n' "$text" | mailx -r "$mailfrom" -a "from: $mailfrom" -s "=?utf-8?b?$(base64 --wrap=0 <<< "$subject")?=" -a $jmenologu -- $mailto

exit 0
