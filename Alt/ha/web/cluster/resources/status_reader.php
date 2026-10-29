<?php

// fusionpbx-ha web status: the shared snapshot reader.
//
// One file, two renderers: the Status -> Cluster page and the dashboard
// widget both include this and render the SAME data - neither runs a
// single probe. The snapshot is materialized by the status cron
// ('fusionpbx-ha.sh --status --json' > /var/lib/fusionpbx-ha/status.json,
// atomic tmp+mv; DESIGN.md section 19). When the collector dies the file
// ages out and both renderers turn red - a dead collector must be VISIBLE.
//
// Server-side only: the file lives outside the web root and is read with
// file_get_contents; nothing here is reachable over HTTP by itself.

if (!defined('HA_CLUSTER_STATUS_FILE')) {
	define('HA_CLUSTER_STATUS_FILE', '/var/lib/fusionpbx-ha/status.json');
}

/**
 * Read and validate the cluster status snapshot.
 *
 * @param int $stale_after seconds after which the snapshot is stale
 * @return array{data:array|null,error:string,age:int|null,stale:bool,file:string}
 *         error: '' | 'missing' | 'unreadable' | 'invalid'
 */
function cluster_status_read($stale_after = 600) {

	$result = [
		'data' => null,
		'error' => '',
		'age' => null,
		'stale' => false,
		'file' => HA_CLUSTER_STATUS_FILE,
	];

	if (!file_exists(HA_CLUSTER_STATUS_FILE)) {
		$result['error'] = 'missing';
		return $result;
	}

	$raw = @file_get_contents(HA_CLUSTER_STATUS_FILE);
	if ($raw === false || $raw === '') {
		$result['error'] = 'unreadable';
		return $result;
	}

	$data = json_decode($raw, true);
	if (!is_array($data) || empty($data['schema']) || empty($data['node'])) {
		$result['error'] = 'invalid';
		return $result;
	}

	// freshness: the timestamp INSIDE the document is authoritative (it
	// survives copies); filemtime is the fallback for older snapshots
	$age = null;
	if (!empty($data['generated_at_epoch']) && is_numeric($data['generated_at_epoch'])) {
		$age = time() - (int)$data['generated_at_epoch'];
	}
	if ($age === null) {
		$mtime = @filemtime(HA_CLUSTER_STATUS_FILE);
		if ($mtime !== false) {
			$age = time() - $mtime;
		}
	}

	$result['data'] = $data;
	$result['age'] = (is_int($age) && $age >= 0) ? $age : null;
	$result['stale'] = $result['age'] === null || $result['age'] > (int)$stale_after;
	return $result;
}

/**
 * Human-readable byte count for the replication lag.
 */
function cluster_status_format_bytes($bytes) {
	$bytes = (int)$bytes;
	if ($bytes >= 1073741824) { return number_format($bytes / 1073741824, 1) . ' GiB'; }
	if ($bytes >= 1048576) { return number_format($bytes / 1048576, 1) . ' MiB'; }
	if ($bytes >= 1024) { return number_format($bytes / 1024, 1) . ' KiB'; }
	return $bytes . ' B';
}

/**
 * Human-readable snapshot age ("38 s", "4 min 12 s").
 */
function cluster_status_format_age($seconds) {
	$seconds = (int)$seconds;
	if ($seconds < 0) { $seconds = 0; }
	if ($seconds < 60) { return $seconds . ' s'; }
	$min = (int)($seconds / 60);
	$sec = $seconds % 60;
	if ($min < 60) { return $min . ' min ' . str_pad((string)$sec, 2, '0', STR_PAD_LEFT) . ' s'; }
	return (int)($min / 60) . ' h ' . str_pad((string)($min % 60), 2, '0', STR_PAD_LEFT) . ' min';
}

/**
 * Color for a node/health state (the theme palettes of the system widgets).
 */
function cluster_status_state_color($state) {
	switch ($state) {
		case 'primary':
		case 'standby':
		case 'up':
		case 'reachable':
		case 'ok':		return '#03c04a';
		case 'agent-down':
		case 'degraded':	return '#ff9933';
		case 'down':
		case 'unreachable':
		case 'fail':		return '#ea4c46';
		default:		return '#999999';
	}
}

?>
