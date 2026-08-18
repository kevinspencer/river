#!/usr/bin/env perl

# river, the endless river

use Getopt::Long;
use FindBin;
use File::Path qw(make_path);
use JSON::PP;
use LWP::UserAgent;
use HTTP::Request::Common qw(POST);
use HTTP::Date qw(str2time);
use MIME::Base64 qw(encode_base64);
use URI::Escape qw(uri_escape);
use POSIX qw(strftime);
use HTML::Entities qw(decode_entities);
use Encode qw(decode);
use Template;
use XML::Feed;
use strict;
use warnings;

$| = 1;

my $config_file = "$FindBin::Bin/river.conf.json";
GetOptions('config=s' => \$config_file)
    or die("Usage: $0 [--config /path/to/river.conf.json]\n");

my $cfg = load_config($config_file);

my $HTTP_TIMEOUT = $cfg->{http_timeout}   // 20;
my $SUMMARY_LEN  = $cfg->{summary_length} // 280;
my $MAX_ITEMS    = $cfg->{max_items}      // 100;
my $PER_SOURCE   = $cfg->{per_source_limit};
my $SOURCE_FLOOR = $cfg->{source_floor}   // 3;   # newest-N per source guaranteed a spot

my %FETCHERS = (
    feed      => \&fetch_feed,
    lastfm    => \&fetch_lastfm,
    spotify   => \&fetch_spotify,
    goodreads => \&fetch_goodreads,
    simkl     => \&fetch_simkl,
);

my %BUILTIN_ICON_DOMAIN = (
    'flickr'     => 'flickr.com',
    'last.fm'    => 'last.fm',
    'lastfm'     => 'last.fm',
    'pinboard'   => 'pinboard.in',
    'letterboxd' => 'letterboxd.com',
    'spotify'    => 'spotify.com',
    'github'     => 'github.com',
    'goodreads'  => 'goodreads.com',
    'simkl'      => 'simkl.com',
);

my @all;
my %icon_for;   # service_class => data: URI (or undef if none)
for my $src (@{ $cfg->{sources} || [] }) {
    next if exists $src->{enabled} && ! $src->{enabled};

    my $type = $src->{type} // '';
    my $fetch = $FETCHERS{$type};
    if (! $fetch) {
        warn("[$src->{name}] unknown source type '$type'; skipping\n");
        next;
    }

    my $items;
    my $ok = eval { $items = $fetch->($src); 1 };
    if ($ok) {
        $items = [ grep { defined } @$items ];
        $items = cap_newest($items, $src->{limit} // $PER_SOURCE);
        write_cache($src, $items);
        printf("[%s] %d item(s)\n", $src->{name}, scalar(@$items));
    }
    else {
        (my $err = $@ || 'unknown error') =~ s/\s+/ /g;
        warn("[$src->{name}] fetch failed: $err\n");
        $items = read_cache($src) || [];
        warn(sprintf("[%s] using %d cached item(s)\n", $src->{name}, scalar(@$items)))
            if @$items;
    }
    push(@all, @$items);

    my $class = service_class($src->{name});
    $icon_for{$class} = get_icon($src) if ! exists $icon_for{$class};
}

# Merge newest-first. Before applying the global cap, reserve a "floor" of the
# newest N items from EVERY source, so a quiet source (e.g. Last.fm, whose loves
# are timestamped months ago) can't be squeezed entirely out of the top MAX_ITEMS
# by chattier ones. Reserved items still sort into the stream by time; the leftover
# slots are then filled by overall recency.
@all = sort { $b->{ts} <=> $a->{ts} } @all;

if ($SOURCE_FLOOR > 0 && @all > $MAX_ITEMS) {
    my (%seen, @reserved, @rest);
    for my $it (@all) {                                 # already newest-first
        my $c = $it->{service_class} // '';
        if (++$seen{$c} <= $SOURCE_FLOOR) { push(@reserved, $it) }
        else                              { push(@rest,     $it) }
    }
    my $room = $MAX_ITEMS - @reserved;
    @rest = $room > 0 ? @rest[0 .. $room - 1] : () if @rest > $room;
    @all  = sort { $b->{ts} <=> $a->{ts} } (@reserved, @rest);
}

@all = @all[0 .. $MAX_ITEMS - 1] if @all > $MAX_ITEMS;   # safety cap

my $now = time();
for my $it (@all) {
    $it->{when}     = relative_time($it->{ts}, $now);
    $it->{datetime} = strftime('%Y-%m-%dT%H:%M:%S%z', localtime($it->{ts}));
    $it->{fulldate} = strftime('%a %d %b %Y, %H:%M', localtime($it->{ts}));
}

my @service_icons = map { { class => $_, data => $icon_for{$_} } }
                    grep { defined $icon_for{$_} } sort keys %icon_for;

render(\@all, \@service_icons);
printf("Wrote %d item(s) to %s\n", scalar(@all), $cfg->{output_file});
exit(0);

sub load_config {
    my ($path) = @_;
    open(my $fh, '<', $path)
        or die("Cannot open config '$path': $! (copy river.conf.json.example)\n");
    local $/;
    my $raw = <$fh>;
    close($fh);
    my $data = eval { JSON::PP->new()->utf8()->relaxed()->decode($raw) };
    die("Invalid JSON in '$path': $@") if $@;
    die("Config has no 'sources' array\n") if ref $data->{sources} ne 'ARRAY';
    return $data;
}

sub ua {
    my $agent = LWP::UserAgent->new(
        timeout => $HTTP_TIMEOUT,
        agent   => 'river.pl/1.0 (+https://kevinspencer.org)',
    );
    return $agent;
}

sub normalize_item {
    my ($src, $f) = @_;
    return undef if ! defined $f->{ts} || $f->{ts} !~ /^\d+$/;

    (my $class = lc($src->{name})) =~ s/[^a-z0-9]+/-/g;
    $class =~ s/^-+|-+$//g;

    my $title = $f->{title} // '';
    decode_entities($title);
    $title = clean_text($title);

    my $summary = strip_html($f->{summary} // '');
    $summary =~ s/^\Q$f->{strip_prefix}\E\s+//
        if defined $f->{strip_prefix} && length $f->{strip_prefix};

    if (defined $src->{strip_summary} && length $src->{strip_summary}) {
        $summary =~ s/$src->{strip_summary}//g;
        $summary = clean_text($summary);
    }

    $summary = truncate_text($summary, $SUMMARY_LEN);

    if ($title eq '') {
        if ($summary ne '') {
            $title   = truncate_text($summary, 120);
            $summary = '';
        }
        else {
            $title = '(untitled)';
        }
    }

    # a fixed per-source caption replaces the feed's own description,
    $summary = $src->{caption} if defined $src->{caption} && length $src->{caption};

    # a fixed per-source label prepended to whatever description survived.
    if (defined $src->{summary_prefix} && length $src->{summary_prefix}) {
        my $prefix = $src->{summary_prefix};
        (my $bare = $prefix) =~ s/\s*:\s*$//;
        $summary = length $summary ? "$prefix $summary" : $bare;
    }

    return {
        service       => $src->{label} // $src->{name},
        service_class => $class,
        title         => $title,
        url           => $f->{url} // '',
        ts            => $f->{ts} + 0,
        summary       => $summary,
        image         => $f->{image},
        # optional Font Awesome class rendered as an <i> before the caption
        caption_icon  => $src->{caption_icon},
    };
}


# Generic RSS/Atom, covers Flickr, Pinboard, Letterboxd, GitHub, blogs, etc.
sub fetch_feed {
    my ($src) = @_;
    my $res = ua()->get($src->{url});
    die("HTTP " . $res->status_line() . "\n") if ! $res->is_success();

    my $xml  = $res->decoded_content();
    my $feed = XML::Feed->parse(\$xml)
        or die('parse error: ' . XML::Feed->errstr() . "\n");

    my @items;
    for my $e ($feed->entries()) {
        my $date = $e->issued() || $e->modified();

        my $body = '';
        if ($e->summary() && length($e->summary()->body() // '')) {
            $body = $e->summary()->body();
        }
        elsif ($e->content() && length($e->content()->body() // '')) {
            $body = $e->content()->body();
        }

        my $title  = to_chars($e->title()) // '';   # some entries have no title
        my $author = to_chars(eval { $e->author() });
        $body      = to_chars($body);

        # don't leak username in the post title
        $title =~ s/^\Q$author\E\s+// if defined $author && length $author;

        # optional per-source title filters, matched against the cleaned-up title
        # (GitHub's feed in particular is chatty: pushes, branch creations, PR
        # "contributed to" noise and stars all arrive on the one feed).
        next if defined $src->{include_title} && $title !~ /$src->{include_title}/;
        next if defined $src->{exclude_title} && $title =~ /$src->{exclude_title}/;

        my $image;
        $image = $1 if $src->{thumbnail} && $body =~ /<img\b[^>]*\bsrc="([^"]+)"/i;

        push(@items, normalize_item($src, {
            title        => $title,
            url          => $e->link(),
            ts           => $date ? $date->epoch() : undef,
            summary      => $body,
            image        => $image,
            strip_prefix => $author,
        }));
    }
    return \@items;
}

# Goodreads per-shelf RSS (their API is dead; RSS lives on). One source per shelf +
# event: "started" (currently-reading shelf) and "finished" (read shelf).
sub fetch_goodreads {
    my ($src) = @_;
    my $res = ua()->get($src->{url});
    die("HTTP " . $res->status_line() . "\n") if ! $res->is_success();
    my $xml = $res->decoded_content();

    my $event  = $src->{event} // 'update';
    my %marker = (
        started  => "\x{1F4D6} Started reading",   # book
        finished => "\x{2705} Finished reading",    # check mark
        update   => 'Goodreads',
    );

    my @fresh;
    while ($xml =~ m{<item>(.*?)</item>}gs) {
        my $item = $1;
        my $tag = sub {
            my ($t) = @_;
            return undef if $item !~ m{<\Q$t\E>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*</\Q$t\E>}s;
            my $v = $1;
            decode_entities($v);
            $v =~ s/^\s+|\s+$//g;
            return $v;
        };

        my $book = $tag->('title');
        next if ! defined $book || $book eq '';
        my $author = $tag->('author_name');
        my $rating = $tag->('user_rating') // 0;

        my $title = $book;
        $title .= " - $author" if defined $author && length $author;

        # Only "finished" carries a rating (you rate a book after reading it).
        my $summary = $marker{$event} // 'Goodreads';
        if ($event eq 'finished' && $rating =~ /^[1-5]$/) {
            $summary .= '  ' . ("\x{2605}" x $rating) . ("\x{2606}" x (5 - $rating));
        }

        # Finished date: prefer the user's "read at", else the shelf-add date.
        my $when = ($event eq 'finished' && $tag->('user_read_at'))
                 ? $tag->('user_read_at')
                 : $tag->('pubDate');

        push(@fresh, normalize_item($src, {
            title   => $title,
            url     => $tag->('link'),
            ts      => $when ? str2time($when) : undef,
            summary => $summary,
        }));
    }

    # Accumulate: merge with the cache, dedupe by title (stable per book within a
    # shelf/event source), newest first, bounded by the source limit.
    my (@merged, %seen);
    for my $it (grep { defined } @fresh, @{ read_cache($src) || [] }) {
        next if $seen{ $it->{title} // '' }++;
        push(@merged, $it);
    }
    @merged = sort { $b->{ts} <=> $a->{ts} } @merged;
    my $limit = $src->{limit} // $PER_SOURCE // 50;
    @merged = @merged[0 .. $limit - 1] if @merged > $limit;
    return \@merged;
}

# Last.fm via the JSON API (its per-user RSS feeds were retired). Rather than every
# scrobble, we log two things: each loved ("faved") track, and recent scrobbles as
# an accumulating history each run's fresh scrobbles are merged with the prior
# cache and deduped by play-time, so plays that age out of the fetch window persist
# rather than vanishing (turns a single churning entry into a real timeline).
sub fetch_lastfm {
    my ($src) = @_;
    my @fresh;

    # Loved tracks one item per love, timestamped when loved.
    my $loved = lastfm_call($src, 'user.getlovedtracks', $src->{loved_limit} // 25);
    for my $t (@{ $loved->{lovedtracks}{track} || [] }) {
        my $artist = ref $t->{artist} eq 'HASH'
                   ? ($t->{artist}{name} // $t->{artist}{'#text'})
                   : $t->{artist};
        push(@fresh, normalize_item($src, {
            title   => "$artist - $t->{name}",
            url     => $t->{url},
            ts      => $t->{date}{uts},
            summary => "\x{2764} Loved on Last.fm",
        }));
    }

    # Recent scrobbles the last N plays (skip a now-playing track: no date).
    my $recent = lastfm_call($src, 'user.getrecenttracks', $src->{scrobble_limit} // 8);
    for my $t (@{ $recent->{recenttracks}{track} || [] }) {
        next if ref $t->{'@attr'} eq 'HASH' && $t->{'@attr'}{nowplaying};
        my $artist = ref $t->{artist} eq 'HASH' ? $t->{artist}{'#text'} : $t->{artist};
        push(@fresh, normalize_item($src, {
            title   => "$artist - $t->{name}",
            url     => $t->{url},
            ts      => $t->{date}{uts},
            summary => "\x{266A} Scrobbled on Last.fm",
        }));
    }

    # Merge fresh items with the previously cached history, newest first, deduped
    # by event marker + play-time + title (so scrobbles that aged out of the fetch
    # window persist, and overlapping windows don't double up).
    my (@merged, %seen);
    for my $it (grep { defined } @fresh, @{ read_cache($src) || [] }) {
        my $key = ($it->{summary} // '') . '|' . $it->{ts} . '|' . ($it->{title} // '');
        next if $seen{$key}++;
        push(@merged, $it);
    }
    @merged = sort { $b->{ts} <=> $a->{ts} } @merged;

    # Bound the retained set, but reserve the loves first so a burst of scrobbles
    # can never evict them; fill the remaining slots with the newest scrobbles.
    my $limit  = $src->{limit} // $PER_SOURCE // 50;
    my @loves  = grep { ($_->{summary} // '') =~ /\x{2764}/ } @merged;
    my @plays  = grep { ($_->{summary} // '') !~ /\x{2764}/ } @merged;

    # Optional time bucketing: keep at most one scrobble per N-hour window, keyed
    # on the absolute epoch bucket (floor(ts / window)). Because buckets are fixed
    # points on the clock not relative to run time the spacing is identical no
    # matter how often the script runs. @plays is already newest-first, so the most
    # recent play in each window wins.
    if (my $hours = $src->{scrobble_bucket_hours}) {
        my $window = $hours * 3600;
        my (%bucket_seen, @thinned);
        for my $p (@plays) {
            next if $bucket_seen{ int($p->{ts} / $window) }++;
            push(@thinned, $p);
        }
        @plays = @thinned;
    }

    # Cap loves to loved_limit (NOT the full limit) so accumulated loves can never
    # starve scrobbles: capping to $limit let loves grow to fill every slot, leaving
    # room=0 and dropping ALL scrobbles (incl. today's). This also bounds the return
    # to <= loved_limit loves, so the cache can't runaway-accumulate loves either.
    my $loves_show = $src->{loved_limit} // 25;
    @loves = @loves[0 .. $loves_show - 1] if @loves > $loves_show;
    my $room = $limit - @loves;
    @plays = $room > 0 ? @plays[0 .. $room - 1] : () if @plays > $room;

    my @final = sort { $b->{ts} <=> $a->{ts} } (@loves, @plays);
    return \@final;
}

sub lastfm_call {
    my ($src, $method, $limit) = @_;
    my $url = 'https://ws.audioscrobbler.com/2.0/'
            . '?method='  . $method
            . '&user='    . uri_escape($src->{user})
            . '&api_key=' . uri_escape($src->{api_key})
            . '&format=json&limit=' . $limit;
    my $res = ua()->get($url);
    die("HTTP " . $res->status_line() . "\n") if ! $res->is_success();
    my $data = decode_json($res->decoded_content());
    die("API error $data->{error}: $data->{message}\n") if $data->{error};
    return $data;
}

sub fetch_spotify {
    my ($src) = @_;
    my $limit = $src->{limit} // 25;
    my $token = spotify_access_token($src);

    my $res = ua()->get(
        "https://api.spotify.com/v1/me/tracks?limit=$limit",
        Authorization => "Bearer $token",
    );
    die("HTTP " . $res->status_line() . "\n") if ! $res->is_success();

    my $data = decode_json($res->decoded_content());
    my @items;
    for my $it (@{ $data->{items} || [] }) {
        my $t = $it->{track} or next;
        my $artist = join(', ', map { $_->{name} } @{ $t->{artists} || [] });
        (my $added = $it->{added_at}) =~ s/\.\d+//;   # ISO8601 -> epoch
        push(@items, normalize_item($src, {
            title   => "$artist - " . clean_track_title($t->{name}),
            url     => $t->{external_urls}{spotify},
            ts      => str2time($added),
            summary => "\x{2764} Added to Liked Songs",
        }));
    }
    return \@items;
}

# Simkl watched-TV via the API. `/sync/all-items/shows`
sub fetch_simkl {
    my ($src) = @_;
    my $res = ua()->get('https://api.simkl.com/sync/all-items/shows?extended=full',
        'simkl-api-key' => $src->{client_id}    // '',
        'Authorization' => 'Bearer ' . ($src->{access_token} // ''),
    );
    die("HTTP " . $res->status_line() . "\n") if ! $res->is_success();

    my $data = decode_json($res->decoded_content());
    my @fresh;
    for my $s (@{ $data->{shows} || [] }) {
        my $show  = $s->{show} or next;
        my $title = $show->{title};
        next if ! defined $title || $title eq '';

        my $id   = $show->{ids}{simkl};
        my $slug = $show->{ids}{slug};
        my $link = $id
            ? "https://simkl.com/tv/$id" . ($slug ? "/$slug" : '')
            : 'https://simkl.com/';

        # (1) added-to-watchlist event
        if (my $added = $s->{added_to_watchlist_at}) {
            (my $t = $added) =~ s/\.\d+//;
            push(@fresh, normalize_item($src, {
                title   => $title,
                url     => $link,
                ts      => str2time($t),
                summary => "\x{2795} Added to Simkl watchlist",   # heavy plus
            }));
        }

        # (2) watched event the latest episode, only when there are watches
        if ($s->{last_watched_at} && defined $s->{last_watched} && $s->{last_watched} ne '') {
            (my $t = $s->{last_watched_at}) =~ s/\.\d+//;
            push(@fresh, normalize_item($src, {
                title   => "$title - $s->{last_watched}",   # "Silo - S02E05"
                url     => $link,
                ts      => str2time($t),
                summary => "\x{1F4FA} Watched on Simkl",           # tv
            }));
        }
    }

    # Accumulate: the Simkl API returns only current state (each show's LATEST
    # watched episode), so a newly-watched episode would otherwise evict the prior
    # one. Merge with the cache and dedupe by summary+title
    my (@merged, %seen);
    for my $it (grep { defined } @fresh, @{ read_cache($src) || [] }) {
        my $key = ($it->{summary} // '') . '|' . ($it->{title} // '');
        next if $seen{$key}++;
        push(@merged, $it);
    }
    @merged = sort { $b->{ts} <=> $a->{ts} } @merged;

    my $limit = $src->{limit} // $PER_SOURCE // 50;
    @merged = @merged[0 .. $limit - 1] if @merged > $limit;
    return \@merged;
}

sub spotify_access_token {
    my ($src) = @_;
    my $creds = encode_base64("$src->{client_id}:$src->{client_secret}", '');
    my $res = ua()->request(POST(
        'https://accounts.spotify.com/api/token',
        Authorization => "Basic $creds",
        Content       => {
            grant_type    => 'refresh_token',
            refresh_token => $src->{refresh_token},
        },
    ));
    die("token HTTP " . $res->status_line() . "\n") if ! $res->is_success();
    my $data = decode_json($res->decoded_content());
    return $data->{access_token} || die("no access_token in Spotify response\n");
}

sub cache_path {
    my ($src) = @_;
    my $dir = $cfg->{cache_dir} or return undef;
    $dir = "$FindBin::Bin/$dir" if $dir !~ m{^/};
    (my $name = lc($src->{name})) =~ s/[^a-z0-9]+/-/g;
    $name =~ s/^-+|-+$//g;
    # Sources can share a name (e.g. two Goodreads shelves both labelled
    # "Goodreads"); the event keeps their item caches from colliding.
    $name .= '-' . lc($src->{event}) if $src->{event};
    return ($dir, "$dir/$name.json");
}

sub write_cache {
    my ($src, $items) = @_;
    my ($dir, $file) = cache_path($src);
    return if ! $file;
    make_path($dir) if ! -d $dir;
    open(my $fh, '>', $file) or do { warn("cache write '$file': $!\n"); return };
    print $fh JSON::PP->new()->utf8()->encode($items);
    close($fh);
}

sub read_cache {
    my ($src) = @_;
    my ($dir, $file) = cache_path($src);
    return undef if ! $file || ! -e $file;
    open(my $fh, '<', $file) or return undef;
    local $/;
    my $raw = <$fh>;
    close($fh);
    my $items = eval { JSON::PP->new()->utf8()->decode($raw) };
    return ref $items eq 'ARRAY' ? $items : undef;
}

sub cap_newest {
    my ($items, $limit) = @_;
    return $items if ! $limit || @$items <= $limit;
    my @sorted = sort { $b->{ts} <=> $a->{ts} } @$items;
    return [ @sorted[0 .. $limit - 1] ];
}

sub to_chars {
    my ($s) = @_;
    return $s if ! defined $s || utf8::is_utf8($s);
    return decode('UTF-8', $s);
}

sub strip_html {
    my ($s) = @_;
    return '' if ! defined $s;
    $s =~ s/<[^>]+>//g;
    decode_entities($s);
    $s = clean_text($s);
    $s =~ s/^.*?\bposted (?:a photo|a video|photos):\s*//i;
    return $s;
}

sub clean_text {
    my ($s) = @_;
    return '' if ! defined $s;
    $s =~ s/\s+/ /g;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

# Spotify appends reissue cruft to track names ("Disintegration - 2010 Remaster").
sub clean_track_title {
    my ($title) = @_;
    return '' if ! defined $title;

    # Separator variants: dash, semicolon, slash or comma. Handles Remaster(ed),
    $title =~ s{\s*[-;/,]\s*(?:\d{4}\s+)?(?:(?:Digital\s+)?Remaster(?:ed)?|Digital\s+Master|Edit)(?:\s+\d{4})?(?:\s+Version)?\s*$}{}i;

    # Parenthesized variants, with or without a year: "(2022 Remaster)",
    $title =~ s{\s*\((?:\d{4}\s+)?(?:Digital\s+)?Remaster(?:ed)?(?:\s+\d{4})?(?:\s+Version)?\s*\)\s*$}{}i;

    # Bare version/edit/mix suffixes: "- Single Version", "- Original Mix",
    $title =~ s{\s*-\s*(?:Original\s+)?(?:\d+["']\s+)?(?:Single\s+)?(?:Version|Edit|Mix)\s*$}{}i;

    $title =~ s/\s+$//;
    return $title;
}

sub truncate_text {
    my ($s, $max) = @_;
    return $s if ! $max || length($s) <= $max;
    my $cut = substr($s, 0, $max);
    $cut =~ s/\s+\S*$//;
    return "$cut\x{2026}";
}

sub relative_time {
    my ($ts, $now) = @_;
    my $d = $now - $ts;
    return 'just now'    if $d < 60;
    return 'in the future' if $d < 0;
    for my $u ([31536000, 'year'], [2592000, 'month'], [604800, 'week'],
               [86400, 'day'], [3600, 'hour'], [60, 'minute']) {
        if ($d >= $u->[0]) {
            my $n = int($d / $u->[0]);
            return "$n $u->[1]" . ($n > 1 ? 's' : '') . ' ago';
        }
    }
    return 'just now';
}

sub render {
    my ($items, $service_icons) = @_;
    my $template = $cfg->{template} // 'templates/river.tt';
    $template = "$FindBin::Bin/$template" if $template !~ m{^/};

    my $tt = Template->new({
        ABSOLUTE => 1,
        ENCODING => 'utf8',
    }) or die(Template->error() . "\n");

    my $vars = {
        title         => $cfg->{title} // 'Activity Stream',
        items         => $items,
        service_icons => $service_icons || [],
        generated_at  => strftime('%a %d %b %Y, %H:%M %Z', localtime()),
        count         => scalar(@$items),
    };

    my $out;
    $tt->process($template, $vars, \$out, { binmode => ':utf8' })
        or die('Template error: ' . $tt->error() . "\n");

    open(my $fh, '>:encoding(UTF-8)', $cfg->{output_file})
        or die("Cannot write output '$cfg->{output_file}': $!\n");
    print $fh $out;
    close($fh);
}

sub service_class {
    my ($name) = @_;
    (my $c = lc($name // '')) =~ s/[^a-z0-9]+/-/g;
    $c =~ s/^-+|-+$//g;
    return $c;
}

sub icon_domain {
    my ($src) = @_;
    return $src->{icon_domain} if $src->{icon_domain};
    my $key = lc($src->{name} // '');
    return $BUILTIN_ICON_DOMAIN{$key} if $BUILTIN_ICON_DOMAIN{$key};
    if (($src->{url} // '') =~ m{^https?://([^/]+)}i) {
        (my $host = $1) =~ s/^www\.//i;
        return $host;
    }
    return undef;
}

sub get_icon {
    my ($src) = @_;
    my ($dir) = cache_path($src);
    my $class = service_class($src->{name});
    my $file  = $dir ? "$dir/icon-$class.txt" : undef;

    return read_icon_cache($file)
        if $file && -e $file && -M $file < 30;

    my $url = $src->{icon};
    if (! $url) {
        my $domain = icon_domain($src) or return read_icon_cache($file);
        $url = "https://icons.duckduckgo.com/ip3/$domain.ico";
    }

    my $res = ua()->get($url);
    return read_icon_cache($file) if ! $res->is_success();

    my $bytes = $res->content();
    return read_icon_cache($file) if ! length $bytes;

    (my $ctype = $res->header('Content-Type') || 'image/x-icon') =~ s/\s*;.*//;
    my $data = "data:$ctype;base64," . encode_base64($bytes, '');

    if ($file) {
        make_path($dir) if ! -d $dir;
        if (open(my $fh, '>', $file)) { print $fh $data; close($fh); }
    }
    return $data;
}

sub read_icon_cache {
    my ($file) = @_;
    return undef if ! $file || ! -e $file;
    open(my $fh, '<', $file) or return undef;
    local $/;
    my $data = <$fh>;
    close($fh);
    return $data || undef;
}
