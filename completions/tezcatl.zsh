#compdef tezcatl

_tezcatl() {
    _arguments \
        '1:url:_urls' \
        '--eval=[Evaluate custom JavaScript]:javascript:' \
        '--wait=[Wait ms after page load]:milliseconds:' \
        '--timeout=[Navigation timeout in ms]:milliseconds:' \
        '--json[Wrap output in JSON]' \
        '--help[Show help message]' \
        '--version[Show version]'
}

_tezcatl "$@"
