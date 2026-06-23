# Fish completions for tezcatl

complete -c tezcatl -l eval -d "Evaluate custom JavaScript" -r
complete -c tezcatl -l eval-file -d "Evaluate JavaScript from a file" -r
complete -c tezcatl -l screenshot -d "Take a PNG screenshot" -r
complete -c tezcatl -l width -d "Viewport width in pixels" -r
complete -c tezcatl -l height -d "Viewport height in pixels" -r
complete -c tezcatl -l archive -d "Save page as a .webarchive" -r
complete -c tezcatl -l pdf -d "Save page as a PDF" -r
complete -c tezcatl -l wait -d "Wait ms after page load" -r
complete -c tezcatl -l timeout -d "Navigation timeout in ms" -r
complete -c tezcatl -l json -d "Wrap output in JSON"
complete -c tezcatl -l help -d "Show help message"
complete -c tezcatl -l version -d "Show version"
