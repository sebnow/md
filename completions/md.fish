set -l commands body frontmatter fm headings links tags codeblocks stats section

complete -c md -f
complete -c md -n "not __fish_seen_subcommand_from $commands" -a "$commands"
complete -c md -n "not __fish_seen_subcommand_from $commands" -l help -d "Show help message"

# Global options for most commands
for cmd in body headings tags codeblocks stats section
    complete -c md -n "__fish_seen_subcommand_from $cmd" -l json -d "Output in JSON format"
    complete -c md -n "__fish_seen_subcommand_from $cmd" -F -r
end

# frontmatter / fm
for cmd in frontmatter fm
    complete -c md -n "__fish_seen_subcommand_from $cmd" -l json -d "Output in JSON format"
    complete -c md -n "__fish_seen_subcommand_from $cmd" -s i -d "Edit file in-place"
    complete -c md -n "__fish_seen_subcommand_from $cmd" -l set -d "Set a field (key=value)" -r
    complete -c md -n "__fish_seen_subcommand_from $cmd" -l del -d "Delete a field" -r
    complete -c md -n "__fish_seen_subcommand_from $cmd" -F -r
end

# links
complete -c md -n "__fish_seen_subcommand_from links" -l json -d "Output in JSON format"
complete -c md -n "__fish_seen_subcommand_from links" -l incoming -d "List incoming links"
complete -c md -n "__fish_seen_subcommand_from links" -l dir -d "Directory to scan" -r -a "(__fish_complete_directories)"
complete -c md -n "__fish_seen_subcommand_from links" -F -r
