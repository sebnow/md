#compdef md

_md() {
    _arguments \
        '1:program:' \
        '--json[Output in JSON format]' \
        '--dir[Directory for incoming/exists/resolve]:directory:_directories' \
        '-i[Edit file in-place]' \
        '--help[Show help message]' \
        '*:file:_files -g "*.md"'
}

_md "$@"
