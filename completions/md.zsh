#compdef md

_md() {
    local -a commands=(
        'body:Output document body without frontmatter'
        'frontmatter:Output or edit frontmatter'
        'headings:List headings with depth and line numbers'
        'links:List outgoing or incoming links'
        'tags:Extract tags'
        'codeblocks:List code blocks'
        'stats:Show document statistics'
        'section:Extract content under a heading'
    )

    local -a global_opts=(
        '--json[Output in JSON format]'
        '--help[Show help message]'
    )

    _arguments -C \
        '1:command:->command' \
        '*::arg:->args'

    case "$state" in
        command)
            _describe -t commands 'md command' commands
            ;;
        args)
            case "${words[1]}" in
                body|headings|tags|codeblocks|stats)
                    _arguments \
                        $global_opts \
                        '*:file:_files -g "*.md"'
                    ;;
                frontmatter)
                    local -a subcmds=(
                        'set:Set frontmatter fields'
                        'delete:Delete frontmatter fields'
                    )
                    _arguments -C \
                        $global_opts \
                        '1:subcommand:->subcmd' \
                        '*:file:_files -g "*.md"'

                    case "$state" in
                        subcmd)
                            _describe -t subcmds 'frontmatter subcommand' subcmds
                            _files -g '*.md'
                            ;;
                    esac

                    case "${words[1]}" in
                        set|delete)
                            _arguments \
                                '-i[Edit file in-place]' \
                                '*:file:_files -g "*.md"'
                            ;;
                    esac
                    ;;
                links)
                    _arguments \
                        $global_opts \
                        '--incoming[List incoming links]' \
                        '--dir[Directory to scan]:directory:_directories' \
                        '*:file:_files -g "*.md"'
                    ;;
                section)
                    _arguments \
                        $global_opts \
                        '1:heading:' \
                        '*:file:_files -g "*.md"'
                    ;;
            esac
            ;;
    esac
}

_md "$@"
