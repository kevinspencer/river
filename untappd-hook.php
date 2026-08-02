<?php
// untappd-hook.php — bridge Untappd check-ins into river.

$SECRET = getenv('UNTAPPD_HOOK_SECRET') ?: 'CHANGE_ME_TO_A_LONG_RANDOM_STRING';
$STORE  = getenv('UNTAPPD_HOOK_STORE')  ?: '/usr/home/muppet/untappd/checkins.json';
$MAX    = 100;                                        // keep newest N check-ins
$TITLE  = "Kevin's Untappd check-ins";
$LINK   = 'https://untappd.com/user/kevinspencer';    // feed channel link

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

if ($method === 'POST') {
    handle_post($SECRET, $STORE, $MAX);
} elseif ($method === 'GET' || $method === 'HEAD') {
    handle_get($STORE, $TITLE, $LINK);
} else {
    http_response_code(405);
    header('Content-Type: text/plain');
    echo "Method not allowed\n";
}
exit;

function handle_post($SECRET, $STORE, $MAX) {
    if (!isset($_GET['key']) || !hash_equals($SECRET, (string)$_GET['key'])) {
        http_response_code(403);
        header('Content-Type: text/plain');
        echo "Forbidden\n";
        return;
    }

    $in = json_decode(file_get_contents('php://input'), true);
    if (!is_array($in)) $in = [];

    $beer = pick($in, ['beer', 'Beer', 'beer_name']);
    if ($beer === null || $beer === '') {
        http_response_code(400);
        header('Content-Type: text/plain');
        echo "Missing beer\n";
        return;
    }

    $rating = pick($in, ['rating', 'Rating', 'checkin_rating']);
    $ts     = pick($in, ['ts', 'timestamp', 'epoch']);

    $record = [
        'ts'      => ($ts !== null && ctype_digit((string)$ts)) ? (int)$ts : time(),
        'beer'    => $beer,
        'brewery' => pick($in, ['brewery', 'Brewery', 'brewery_name']) ?? '',
        'rating'  => ($rating !== null && is_numeric($rating)) ? (float)$rating : null,
        'comment' => pick($in, ['comment', 'Comment', 'checkin_comment']) ?? '',
        'url'     => pick($in, ['url', 'URL', 'checkin_url']) ?? '',
    ];

    append_record($STORE, $MAX, $record);

    http_response_code(200);
    header('Content-Type: text/plain');
    echo "OK\n";
}

function handle_get($STORE, $TITLE, $LINK) {
    header('Content-Type: application/rss+xml; charset=utf-8');
    echo rss(read_store($STORE), $TITLE, $LINK);
}

function append_record($STORE, $MAX, $record) {
    $dir = dirname($STORE);
    if ($dir !== '' && !is_dir($dir)) @mkdir($dir, 0755, true);

    $fh = fopen($STORE, 'c+');   // read/write, create if missing, don't truncate
    if ($fh === false) {
        http_response_code(500);
        header('Content-Type: text/plain');
        echo "store error\n";
        return;
    }
    flock($fh, LOCK_EX);

    $items = json_decode(stream_get_contents($fh) ?: '[]', true);
    if (!is_array($items)) $items = [];

    // Dedupe: IFTTT can double-fire; skip if this check-in URL is already stored.
    if ($record['url'] !== '') {
        foreach ($items as $it) {
            if (($it['url'] ?? '') === $record['url']) {
                flock($fh, LOCK_UN);
                fclose($fh);
                return;
            }
        }
    }

    array_unshift($items, $record);
    if (count($items) > $MAX) $items = array_slice($items, 0, $MAX);

    rewind($fh);
    ftruncate($fh, 0);
    fwrite($fh, json_encode($items,
        JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
    fflush($fh);
    flock($fh, LOCK_UN);
    fclose($fh);
}

function read_store($STORE) {
    if (!file_exists($STORE)) return [];
    $fh = fopen($STORE, 'r');
    if ($fh === false) return [];
    flock($fh, LOCK_SH);
    $raw = stream_get_contents($fh);
    flock($fh, LOCK_UN);
    fclose($fh);
    $items = json_decode($raw ?: '[]', true);
    return is_array($items) ? $items : [];
}

function rss($items, $TITLE, $LINK) {
    $out  = '<?xml version="1.0" encoding="UTF-8"?>' . "\n";
    $out .= '<rss version="2.0"><channel>' . "\n";
    $out .= '<title>' . xml($TITLE) . "</title>\n";
    $out .= '<link>' . xml($LINK) . "</link>\n";
    $out .= '<description>' . xml($TITLE) . "</description>\n";
    $out .= '<lastBuildDate>' . date('r') . "</lastBuildDate>\n";

    foreach ($items as $c) {
        $title = $c['beer'] ?? '';
        if (!empty($c['brewery'])) $title .= ' — ' . $c['brewery'];
        if (isset($c['rating']) && $c['rating'] !== null) {
            $title .= sprintf(' (%s★)', $c['rating']);
        }

        $link = !empty($c['url']) ? $c['url'] : $LINK;
        $guid = !empty($c['url']) ? $c['url'] : ($LINK . '#' . ($c['ts'] ?? 0));

        $out .= "<item>\n";
        $out .= '<title>' . xml($title) . "</title>\n";
        $out .= '<link>' . xml($link) . "</link>\n";
        $out .= '<guid isPermaLink="false">' . xml($guid) . "</guid>\n";
        $out .= '<pubDate>' . date('r', $c['ts'] ?? time()) . "</pubDate>\n";
        $out .= '<description>' . xml($c['comment'] ?? '') . "</description>\n";
        $out .= "</item>\n";
    }

    $out .= "</channel></rss>\n";
    return $out;
}

function pick($h, $keys) {
    foreach ($keys as $k) {
        if (isset($h[$k]) && $h[$k] !== '') return $h[$k];
    }
    return null;
}

function xml($s) {
    if ($s === null) return '';
    return htmlspecialchars((string)$s, ENT_QUOTES | ENT_XML1, 'UTF-8');
}
