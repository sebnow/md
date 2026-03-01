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
            if ((cword == 2)); then
                COMPREPLY=($(compgen -W "set delete --json" -- "$cur"))
                _filedir 'md'
                return
            fi
            case "${words[2]}" in
                set|delete)
                    if [[ "$cur" == -* ]]; then
                        COMPREPLY=($(compgen -W "-i" -- "$cur"))
                    else
                        _filedir 'md'
                    fi
                    ;;
                *)
                    COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
                    _filedir 'md'
                    ;;
            esac
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
        body|headings|tags|codeblocks|stats)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
            else
                _filedir 'md'
            fi
            ;;
        section)
            if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
            else
                _filedir 'md'
            fi
            ;;
    esac
}

complete -F _md md
