# tezcatl

Headless web rendering from the command line, powered by native macOS WebKit.

Load any URL, wait for JavaScript to render, get back the fully rendered DOM HTML. Extract data with custom JS evaluation. No headless Chrome, no Puppeteer, no downloads, no network proxies — just the system WebKit engine.

Written in Zig. Uses Apple's WKWebView via Objective-C runtime bindings.

## Install

```bash
zig build -Doptimize=ReleaseFast
cp zig-out/bin/tezcatl /usr/local/bin/
```

## Usage

### Render a page

```bash
$ tezcatl https://example.com
<html lang="en"><head><title>Example Domain</title>...

$ tezcatl https://spa-site.com --wait=2000
# waits 2s after load for JS frameworks to render
```

### Evaluate JavaScript

```bash
$ tezcatl https://example.com --eval="document.title"
Example Domain

$ tezcatl https://example.com --eval="document.querySelectorAll('a').length"
1

$ tezcatl https://example.com --eval="document.title" --json
{"result":"Example Domain"}
```

### JSON output

```bash
$ tezcatl https://example.com --json | jq '.html' | head -c 100
"<html lang=\"en\"><head><title>Example Domain</title>...
```

## Composability

tezcatl reads URLs as arguments and writes to stdout, so it pipes naturally with other tools:

```bash
# Get the rendered DOM and detect its language
tezcatl https://example.com | lingua detect

# Extract all links from a JS-rendered page
tezcatl https://spa-site.com --wait=2000 --eval="JSON.stringify([...document.querySelectorAll('a')].map(a => a.href))"

# Scrape a page title for use in a script
TITLE=$(tezcatl https://example.com --eval="document.title")

# Get rendered HTML and extract phone numbers
tezcatl https://business-site.com --wait=1000 | lingua entities --type=phone
```

## Options

```
tezcatl <url> [options]

  --eval=JS            Evaluate custom JavaScript instead of returning DOM
  --wait=MS            Wait N ms after page load for JS to settle (default: 0)
  --timeout=MS         Navigation timeout in ms (default: 30000)
  --json               Wrap output in JSON
  --help, -h           Show this help message
  --version, -v        Show version
```

## Requirements

- macOS 10.15+ (Catalina or later)
- Zig 0.16+

## How It Works

tezcatl creates an offscreen WKWebView, loads the URL, waits for the navigation delegate to fire `didFinishNavigation:`, optionally waits for additional JS settling time, then evaluates `document.documentElement.outerHTML` (or custom JS via `--eval`) through `evaluateJavaScript:completionHandler:`.

The Dock icon is suppressed via `NSApplicationActivationPolicyAccessory`. All WebKit rendering happens in-process using the system engine — the same one Safari uses.

Key bridging patterns:
- **Navigation delegate:** Runtime class creation (`objc_allocateClassPair`) with `WKNavigationDelegate` callbacks
- **JS completion handler:** ObjC block ABI (`_NSConcreteStackBlock`) for async evaluation callbacks
- **Run loop:** `CFRunLoopRunInMode` to pump the event loop while waiting for async operations

## Related Projects

- [lingua](https://github.com/georgemandis/lingua) — NLP CLI (NaturalLanguage framework)
- [loupe](https://github.com/georgemandis/loupe) — Computer vision CLI (Vision framework)
- [whereami](https://github.com/georgemandis/whereami) — Location CLI (CoreLocation)
- [nearme](https://github.com/georgemandis/nearme) — Local search CLI (MapKit)

## Credits

Created by [George Mandis](https://george.mand.is) during [Recurse Center](https://www.recurse.com/).
