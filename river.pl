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

my %FETCHERS = (
    feed    => \&fetch_feed,
    lastfm  => \&fetch_lastfm,
    spotify => \&fetch_spotify,
);

my %BUILTIN_ICON_DOMAIN = (
    'flickr'     => 'flickr.com',
    'last.fm'    => 'last.fm',
    'lastfm'     => 'last.fm',
    'pinboard'   => 'pinboard.in',
    'letterboxd' => 'letterboxd.com',
    'spotify'    => 'spotify.com',
    'github'     => 'github.com',
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

# Merge: newest first, then truncate to the global cap.
@all = sort { $b->{ts} <=> $a->{ts} } @all;
@all = @all[0 .. $MAX_ITEMS - 1] if @all > $MAX_ITEMS;

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

    my $summary = truncate_text(strip_html($f->{summary} // ''), $SUMMARY_LEN);

    # Some feeds (WordPress asides/status posts) have no title — fall back to the
    # body text so the item still reads, or a placeholder if it's truly empty.
    if ($title eq '') {
        if ($summary ne '') {
            $title   = truncate_text($summary, 120);
            $summary = '';
        }
        else {
            $title = '(untitled)';
        }
    }

    return {
        service       => $src->{label} // $src->{name},
        service_class => $class,
        title         => $title,
        url           => $f->{url} // '',
        ts            => $f->{ts} + 0,
        summary       => $summary,
        image         => $f->{image},
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

        my $image;
        $image = $1 if $src->{thumbnail} && $body =~ /<img\b[^>]*\bsrc="([^"]+)"/i;

        push(@items, normalize_item($src, {
            title   => $title,
            url     => $e->link(),
            ts      => $date ? $date->epoch() : undef,
            summary => $body,
            image   => $image,
        }));
    }
    return \@items;
}

# Last.fm recent tracks via the JSON API (its per-user RSS feeds were retired).
sub fetch_lastfm {
    my ($src) = @_;
    my $limit = $src->{limit} // 25;
    my $url   = 'https://ws.audioscrobbler.com/2.0/'
              . '?method=user.getrecenttracks'
              . '&user='    . uri_escape($src->{user})
              . '&api_key=' . uri_escape($src->{api_key})
              . '&format=json&limit=' . $limit;

    my $res = ua()->get($url);
    die("HTTP " . $res->status_line() . "\n") if ! $res->is_success();

    my $data = decode_json($res->decoded_content());
    die("API error $data->{error}: $data->{message}\n") if $data->{error};

    my @items;
    for my $t (@{ $data->{recenttracks}{track} || [] }) {
        # The currently-playing track has no date; skip it (nothing to sort by).
        next if ref $t->{'@attr'} eq 'HASH' && $t->{'@attr'}{nowplaying};
        my $artist = ref $t->{artist} eq 'HASH' ? $t->{artist}{'#text'} : $t->{artist};
        push(@items, normalize_item($src, {
            title => "$artist \x{2013} $t->{name}",
            url   => $t->{url},
            ts    => $t->{date}{uts},
        }));
    }
    return \@items;
}

# Spotify recently-played via OAuth (refresh-token grant, same flow as
# lastfm-spotify-compare). Requires the user-read-recently-played scope.
sub fetch_spotify {
    my ($src) = @_;
    my $limit = $src->{limit} // 25;
    my $token = spotify_access_token($src);

    my $res = ua()->get(
        "https://api.spotify.com/v1/me/player/recently-played?limit=$limit",
        Authorization => "Bearer $token",
    );
    die("HTTP " . $res->status_line() . "\n") if ! $res->is_success();

    my $data = decode_json($res->decoded_content());
    my @items;
    for my $play (@{ $data->{items} || [] }) {
        my $t = $play->{track} or next;
        my $artist = join(', ', map { $_->{name} } @{ $t->{artists} || [] });
        (my $played = $play->{played_at}) =~ s/\.\d+//;   # drop fractional seconds
        push(@items, normalize_item($src, {
            title => "$artist \x{2013} $t->{name}",
            url   => $t->{external_urls}{spotify},
            ts    => str2time($played),
        }));
    }
    return \@items;
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
