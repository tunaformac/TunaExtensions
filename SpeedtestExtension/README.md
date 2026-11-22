# Speedtest for Tuna

Run an internet speed test from Tuna. Based on the Raycast Speedtest extension, but it uses Apple's
built-in `/usr/bin/networkQuality` instead of downloading Ookla's CLI, so there is nothing to
install and no third-party license.

## Use

Run **Run Speed Test**. The test runs on Tuna's Shelf for about 20–60 seconds (networkQuality is
capped at 60 seconds and killed after 90), then shows:

- a summary (download, upload, responsiveness, idle latency)
- **Download** and **Upload** capacity
- **Responsiveness** in round trips per minute (RPM) while the connection is busy
- **Idle Latency** in milliseconds

Every result is text, so Tuna's copy and paste actions work; **Copy Summary** copies the full line.

Requires Tuna 0.113 or later (the version this was tested with). A failed, timed-out, or cancelled
test is reported as a failure on the Shelf and never shows partial results.

## Differences from Ookla

networkQuality measures against Apple's CDN rather than a chosen Speedtest.net server and reports
responsiveness instead of jitter and packet loss. There is no server or ISP selection.

## Privacy

The test sends and receives data to Apple's measurement servers, exactly as running
`networkQuality` in Terminal does. Results are not stored.

## Development

```bash
./scripts/tuna-extension build --scheme SpeedtestExtension
./scripts/tuna-extension install --scheme SpeedtestExtension --restart
make test-extensions
```
