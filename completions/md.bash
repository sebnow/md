_md() {
    local cur prev words cword
    _init_completion || return

    local commands="body frontmatter headings links tags codeblocks stats section"
    local global_opts="--json --help"

    if ((cword == 1)); then
        COMPREPLY=($(compgen -W "$commands" -- "$cur"))
        return
    fi

    local cmd="${words[1]}"

    case "$cmd" in
        frontmatter)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "--json --set --del -i" -- "$cur"))
            elif [[ "$prev" == "--set" ]]; then
                # Expect key=value, no completion
                return
            elif [[ "$prev" == "--del" ]]; then
                # Expect key, no completion
                return
            else
                _filedir 'md'
            fi
            ;;
        links)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "--json --incoming --dir" -- "$cur"))
            elif [[ "$prev" == "--dir" ]]; then
                _filedir -d
            else
                _filedir 'md'
            fi
            ;;
        body|headings|tags|codeblocks|stats|section)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
            else
                _filedir 'md'
            fi
            ;;
    esac
}

complete -F _md md
