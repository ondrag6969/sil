# verze 2.1
##
##
## Nápověda
##
## možné parametry:

paramlist="bs samba zfs nas"

paramcheck() {
    [[ " $paramlist " =~ .*\ $1\ .* ]]
}

paramhelp() {
    grep "^##" "$mainprog" | sed -e "s/^##//" # -e "s/\$PROG/$PROG/g"
    echo $paramlist
    echo
    echo $paticka
}

main() {
    local varname
    varname=$mainkod"_enabled"
    if [ "${!varname^^}" != "YES" ]; then
        fatal "procedura $mainkod není povolená"
    fi

    case "$mainkod" in
        bs) 
            main_subject="images na lokální server"
            main_bs 2>&1 >&3
        ;;
        samba)
            main_subject="samba soubory"
            main_samba 2>&1 >&3
        ;;
        zfs)
            main_subject="synchro zfs do cloudu"
            main_zfs 2>&1 >&3
        ;;
        nas)
            main_subject="kopie images na NAS"
            main_nas 2>&1 >&3
        ;;
    esac

    return $vysledek
}

main_nas() {
    local virtual
    local disky
    local co
    local velikost
    local zpakovane
    local image_ok
    mkdir -p $nas_cil/$datum
    for virtual in $seznam; do
        disky=$(lvs | awk '{print $1}' | egrep "^$virtual-?[0-9]?$" | egrep -v "$nas_exclude")
        for co in $disky; do
            velikost=$(lvs --units b | grep "^  $co " | grep -v snap | awk '{print $4}' | sed -n 's/B//g;p')
            velikost=$((velikost / 4))
            echo create snapshot $co $velikost
            $debug lvcreate -L "$velikost"B -n $co.$nas_koncovka -s $nas_cesta/$co
            errl=$?
            if [ $errl -eq 0 ]; then continue; fi
            chyba "lvcreate $virtual/$co"
            cleanup
            break
        done
        if [ $errl -eq 0 ]; then 
            for co in $disky; do
                info "start copy $virtual/$co"
                velikost=$(lvs --units b | grep -v "snap" | grep "^  $co " | awk '{print $4}' | sed -n 's/B//g;p')
                echo copy $co $velikost
                $debug ionice -c3 pv --buffer-size=1M <$nas_cesta/$co.$nas_koncovka | nice zstd $nas_compress -T0 --long | mbuffer -q -m 128M -R 20M | dd bs=1M of=$nas_cil/$datum/$co.img.zstd | tee "$tmpfile"
                errlp=( "${PIPESTATUS[@]}" )
#                $debug stdbuf --output=l ionice -c3 python $bs_blocksync -q $bs_cesta/$co.$bs_koncovka $bs_cil /tank/images/$virtual/$co.img | tee "$tmpfile"
                image_ok=0 # true
                if [ ${errlp[0]} -ne 0 ]; then
                    chyba "v příkazu PV $virtual/$co"
                    image_ok=1 # false
                fi
                if [ ${errlp[1]} -ne 0 ]; then
                    chyba "v příkazu ZSTD $virtual/$co"
                    image_ok=1 # false
                fi
                if [ ${errlp[2]} -ne 0 ]; then
                    chyba "v příkazu DD $virtual/$co"
                    image_ok=1 # false
                fi
                if [ $image_ok -eq 0 ]; then
                    zpakovane=$(stat --printf="%s" $nas_cil/$datum/$co.img.zstd)
                    info "image $virtual/$co $(numfmt --to=iec-i --suffix=B --format="%.0f" $velikost) zpakován na $(numfmt --to=iec-i --suffix=B --format="%.0f" $zpakovane)"
                fi
                lvs | grep $co | grep $nas_koncovka
                echo remove snap $co
                $debug lvremove -f $nas_cesta/$co.$nas_koncovka || chyba "lvremove $virtual/$co"
                info "end copy $virtual/$co"
            done
            info "---"
        fi
    done

    return $vysledek
}

main_zfs() {
    local disk
    for disk in $zfs_seznam; do
        info "start synchro zfs pro $disk"
        nice syncoid --compress=zstd-fast --no-stream --recursive $zfs_zdroj/$disk $zfs_cil/$disk
        errl=$?
        if [ $errl -eq 0 ]; then
            info "end synchro zfs pro $disk"
        else
            chyba "synchro zfs pro $disk"
        fi
    info
    done
}

main_samba() {
    info "start kopie samby na zfs"
    stdbuf --output=L rsync $samba_dryrun -avhH --out-format="$samba_logformat" --partial --delete --exclude "$samba_exclude" -e ssh $samba_zdroj $samba_cesta  | tee "$tmpfile"
    errl=$?
    info "$(tail -n 2 $tmpfile | head -n 1)"
    info "$(tail -n 1 $tmpfile)"
    if [ $errl -eq 0 ]; then
        info "konec kopie samby na zfs"
    else
        chyba "kopie samby na zfs"
    fi
    info "---"
    info "start kopie samby na NAS"
    RSYNC_PASSWORD=$samba_naspass \
    stdbuf --output=L rsync $samba_dryrun -rltD -vhH --delete --out-format="$samba_logformat" $samba_cesta rsync://$samba_nas | tee "$tmpfile"
    errl=$?
    info "$(tail -n 2 $tmpfile | head -n 1)"
    info "$(tail -n 1 $tmpfile)"
    if [ $errl -eq 0 ]; then
        info "konec kopie samby na NAS"
    else
        chyba "kopie samby na NAS"
    fi

    return $vysledek
}

main_bs() {
    local virtual
    local disky
    local co
    local velikost
    for virtual in $seznam; do
        disky=$(lvs | awk '{print $1}' | egrep "^$virtual-?[0-9]?$" | egrep -v "$bs_exclude")
        for co in $disky; do
            velikost=$(lvs --units b | grep "^  $co " | grep -v snap | awk '{print $4}' | sed -n 's/B//g;p')
            velikost=$((velikost / 4))
            echo create snapshot $co $velikost
            $debug lvcreate -L "$velikost"B -n $co.$bs_koncovka -s $bs_cesta/$co
            errl=$?
            if [ $errl -eq 0 ]; then continue; fi
            chyba "lvcreate $virtual/$co"
            cleanup
            break
        done
        if [ $errl -eq 0 ]; then 
            for co in $disky; do
                info "start copy $virtual/$co"
                velikost=$(lvs --units b | grep -v "snap" | grep "^  $co " | awk '{print $4}' | sed -n 's/B//g;p')
                echo copy $co $velikost
                $debug ssh $bs_cil "truncate -s $velikost ~/images/"$co".img"
                $debug stdbuf --output=L ionice -c3 python $bs_blocksync -q $bs_cesta/$co.$bs_koncovka $bs_cil images/$co.img | tee "$tmpfile"
                errl=$?
                if [ $errl -eq 0 ]; then
                    info "blocksync $virtual/$co $(numfmt --to=iec-i --suffix=B --format="%.0f" $velikost) $(egrep "^same" "$tmpfile")"
                else
                    chyba "blocksync $virtual/$co $(<"$tmpfile")"
                fi
                lvs | grep $co | grep $bs_koncovka
                echo remove snap $co
                $debug lvremove -f $bs_cesta/$co.$bs_koncovka || chyba "lvremove $virtual/$co"
                info "end copy $virtual/$co"
            done
            info "---"
        fi
    done

    return $vysledek
}
