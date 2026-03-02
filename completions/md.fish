complete -c md -f
complete -c md -l json -d "Output in JSON format"
complete -c md -l dir -d "Directory for incoming/exists/resolve" -r -a "(__fish_complete_directories)"
complete -c md -s i -d "Edit file in-place"
complete -c md -l help -d "Show help message"
complete -c md -F
