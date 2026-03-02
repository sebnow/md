_md() {
    local cur prev
    _init_completion || return

    if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--json --dir -i --help" -- "$cur"))
        return
    fi

    if [[ "$prev" == "--dir" ]]; then
        _filedir -d
        return
    fi

    _filedir 'md'
}

complete -F _md md
