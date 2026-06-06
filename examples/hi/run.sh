#!/bin/bash

pushd examples/hi
npx http-server &
export HTTP_SERVER=$!
echo "web server is $!"
../..//zig-out/bin/tezcatl http://localhost:8080/hi.html --screenshot --eval-file=hi.js --settle=1000  --full > ../temp/hi.png
kill -9 $HTTP_SERVER
