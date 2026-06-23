_tezcatl() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"

    opts="--eval= --eval-file= --screenshot --width= --height= --archive --pdf --wait= --timeout= --json --help --version"

    if [[ "${cur}" == -* ]]; then
        COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
        return 0
    fi

    return 0
}

complete -o default -F _tezcatl tezcatl
