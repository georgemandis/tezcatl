#compdef tezcatl

_tezcatl() {
    _arguments \
        '1:url:_urls' \
        '--eval=[Evaluate custom JavaScript]:javascript:' \
        '--eval-file=[Evaluate JavaScript from a file]:file:_files' \
        '--screenshot=[Take a PNG screenshot]:file:_files' \
        '--width=[Viewport width in pixels]:pixels:' \
        '--height=[Viewport height in pixels]:pixels:' \
        '--archive=[Save page as a .webarchive]:file:_files' \
        '--wait=[Wait ms after page load]:milliseconds:' \
        '--timeout=[Navigation timeout in ms]:milliseconds:' \
        '--json[Wrap output in JSON]' \
        '--help[Show help message]' \
        '--version[Show version]'
}

_tezcatl "$@"
