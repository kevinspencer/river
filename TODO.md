# river — TODO

## Features / ideas
- [ ] New source: youtube
- [ ] **New source: overcast** — log when I've listened to a podcast.

## Done
- [x] New source: simkl (shipped Aug 13 2026 — watched TV, plus watchlist adds)

## Won't do or maybe do or I dunno
- **Untappd source** possible dead end (Aug 2026): no API, no means to pull via IFTTT, no RSS.  Scrape? But it's behind a cloudflare challenge.  Ugh.
- **Trackt source** API is $48 a year, and you can't get at your data without it.  $48 a year is a lot to track TV shows.
- **Letterboxd watchlist adds** not available (Aug 2026): the RSS feed is diary entries only, there's no watchlist feed endpoint (all 403), and the watchlist page is client-rendered.  Simkl could cover film watchlist adds instead, but that splits films across two services.
- **Minimum-gap scrobble spacing** decided against (Aug 2026).  scrobble_bucket_hours keeps one play per fixed clock window, so two plays either side of a boundary can show up minutes apart.  A min-gap rule would space them evenly but makes the output depend on the fetch window, losing run-frequency independence.  Not worth the trade.
