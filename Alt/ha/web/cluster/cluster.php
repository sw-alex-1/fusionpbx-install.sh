<?php
/*
	fusionpbx-ha: Status -> Cluster page.

	Read-only projection of /var/lib/fusionpbx-ha/status.json (written by
	the status cron from 'fusionpbx-ha.sh --status --json'). This page runs
	NO probes of its own: a dashboard that hangs on a dead peer is exactly
	what the file-based design avoids. Repairs stay in the CLI
	(fusionpbx-ha.sh --doctor / --repair) - see RUNBOOK.md.
*/

//includes files
	require_once dirname(__DIR__, 2) . "/resources/require.php";
	require_once "resources/check_auth.php";

//check permissions
	if (!permission_exists('cluster_view')) {
		echo "access denied";
		exit;
	}

//add multi-lingual support
	$language = new text;
	$text = $language->get(null, 'app/cluster');

//read the status snapshot (the shared reader also computes freshness)
	require_once __DIR__ . "/resources/status_reader.php";
	$stale_after = 600;
	if (!empty($settings) && method_exists($settings, 'get')) {
		$stale_after = (int)($settings->get('cluster', 'status_stale_seconds', 600) ?: 600);
	}
	$snap = cluster_status_read($stale_after);
	$d = $snap['data'];

//page title
	$document['title'] = $text['title-cluster'];

//include the header
	require_once "resources/header.php";

//styles: keep it self-contained (no app-specific css file)
	echo "<style>\n";
	echo "	.cluster_banner { padding: 10px 14px; border-radius: 6px; color: #ffffff; font-size: 14px; font-weight: 600; margin-bottom: 12px; }\n";
	echo "	.cluster_table { width: 100%; border-collapse: collapse; margin-bottom: 16px; }\n";
	echo "	.cluster_table th { text-align: left; padding: 6px 8px; border-bottom: 2px solid #d4d4d4; white-space: nowrap; }\n";
	echo "	.cluster_table td { padding: 6px 8px; border-bottom: 1px solid #e8e8e8; }\n";
	echo "	.cluster_reasons { margin: 6px 0 0 0; padding: 0; list-style: disc inside; font-weight: 400; }\n";
	echo "</style>\n";

	echo "<div class='action_bar' id='action_bar'>\n";
	echo "	<div class='heading'><b>" . $text['title-cluster'] . "</b></div>\n";
	echo "	<div class='actions'>\n";
	echo "	</div>\n";
	echo "	<div style='clear: both;'></div>\n";
	echo "</div>\n";
	echo $text['description-cluster'] . "\n";
	echo "<br /><br />\n";

// ---------------------------------------------------------------- snapshot errors
	if ($snap['error'] !== '' || $snap['stale']) {
		$msg = '';
		if ($snap['error'] === 'missing') { $msg = str_replace('%file%', $snap['file'], $text['message-missing']); }
		elseif ($snap['error'] === 'unreadable') { $msg = str_replace('%file%', $snap['file'], $text['message-unreadable']); }
		elseif ($snap['error'] === 'invalid') { $msg = str_replace('%file%', $snap['file'], $text['message-invalid']); }
		else { $msg = str_replace('%minutes%', (string)(int)(($snap['age'] !== null ? $snap['age'] : 0) / 60 + 1), $text['message-stale']); }
		echo "<div class='cluster_banner' style='background: #ea4c46;'>" . escape($msg) . "</div>\n";
	}

// ---------------------------------------------------------------- the snapshot
	if (is_array($d)) {

		//health banner
		$health = $d['health'] ?? 'fail';
		$hcolor = cluster_status_state_color($health);
		$hlabel = $text['health-' . $health] ?? $health;
		echo "<div class='cluster_banner' style='background: " . $hcolor . ";'>" . escape($hlabel) . "\n";
		if (!empty($d['health_reasons']) && is_array($d['health_reasons'])) {
			echo "	<ul class='cluster_reasons'>\n";
			foreach ($d['health_reasons'] as $reason) {
				echo "		<li>" . escape($reason) . "</li>\n";
			}
			echo "	</ul>\n";
		}
		echo "</div>\n";

		//nodes table
		echo "<table class='cluster_table'>\n";
		echo "	<tr>\n";
		echo "		<th>" . $text['label-node'] . "</th>\n";
		echo "		<th>" . $text['label-ip'] . "</th>\n";
		echo "		<th>" . $text['label-kind'] . "</th>\n";
		echo "		<th>" . $text['label-state'] . "</th>\n";
		echo "	</tr>\n";
		$c = 0;
		$row_style = ['row_style0', 'row_style1'];
		foreach (($d['nodes'] ?? []) as $n) {
			$state = (string)($n['state'] ?? '');
			$state_key = 'state-' . str_replace('-', '_', $state);
			$state_label = $text[$state_key] ?? ($text['state-' . $state] ?? $state);
			$is_me = ((int)($n['id'] ?? 0) === (int)($d['node']['id'] ?? 0));
			echo "	<tr class='" . $row_style[$c] . "'>\n";
			echo "		<td>" . escape($n['name'] ?? '?') . ($is_me ? " <i>(" . $text['label-this-node'] . ")</i>" : "") . "</td>\n";
			echo "		<td>" . escape($n['ip'] ?? '') . "</td>\n";
			echo "		<td>" . ($n['kind'] === 'witness' ? $text['label-witness'] : $text['label-data']) . "</td>\n";
			echo "		<td style='color: " . cluster_status_state_color($state) . "; font-weight: 600;'>" . escape($state_label) . "</td>\n";
			echo "	</tr>\n";
			$c = 1 - $c;
		}
		echo "</table>\n";

		//replication + facts table (data nodes; the witness streams nothing)
		if (!empty($d['replication']) && is_array($d['replication'])) {
			$r = $d['replication'];
			$mode = (string)($r['mode'] ?? 'unknown');
			$mode_label = $text['mode-' . $mode] ?? $mode;
			$mode_color = ($mode === 'sync') ? '#03c04a' : (($mode === 'none' || $mode === 'unknown') ? '#ea4c46' : '#ff9933');
			echo "<table class='cluster_table'>\n";
			echo "	<tr><th colspan='2'>" . $text['label-replication'] . "</th></tr>\n";
			echo "	<tr class='row_style0'><td>" . $text['label-mode'] . "</td><td style='color: " . $mode_color . "; font-weight: 600;'>" . escape($mode_label) . "</td></tr>\n";
			if (!empty($r['peer'])) {
				echo "	<tr class='row_style1'><td>" . $text['label-peer'] . "</td><td>" . escape($r['peer']) . "</td></tr>\n";
			}
			echo "	<tr class='row_style0'><td>" . $text['label-lag'] . "</td><td>" . escape(cluster_status_format_bytes($r['lag_bytes'] ?? 0)) . "</td></tr>\n";
			echo "</table>\n";
		}

		//entry point + freshness
		echo "<table class='cluster_table'>\n";
		if (array_key_exists('entry_point', $d) && $d['entry_point'] !== null) {
			$ep_ok = !empty($d['entry_point']);
			echo "	<tr class='row_style0'><td>" . $text['label-entry-point'] . "</td><td style='color: " . ($ep_ok ? '#03c04a' : '#ea4c46') . "; font-weight: 600;'>" . ($ep_ok ? $text['option-yes'] : $text['option-no']) . "</td></tr>\n";
		}
		if ($snap['age'] !== null) {
			$age_color = $snap['stale'] ? '#ea4c46' : '#03c04a';
			echo "	<tr class='row_style1'><td>" . $text['label-updated'] . "</td><td style='color: " . $age_color . ";'>" . escape(cluster_status_format_age($snap['age'])) . " " . ($snap['stale'] ? '(' . $text['health-fail'] . ')' : '') . "</td></tr>\n";
		}
		echo "</table>\n";

		//services
		if (!empty($d['services']) && is_array($d['services'])) {
			echo "<table class='cluster_table'>\n";
			echo "	<tr><th colspan='2'>" . $text['label-services'] . "</th></tr>\n";
			$c = 0;
			foreach ($d['services'] as $s) {
				$active = !empty($s['active']);
				echo "	<tr class='" . $row_style[$c] . "'><td>" . escape($s['name'] ?? '?') . "</td><td style='color: " . ($active ? '#03c04a' : '#ea4c46') . "; font-weight: 600;'>" . ($active ? $text['option-yes'] : $text['option-no']) . "</td></tr>\n";
				$c = 1 - $c;
			}
			echo "</table>\n";
		}
	}

//the CLI-first policy
	echo "<br />\n";
	echo "<div style='color: #666; font-size: 12px;'>" . escape($text['hint-cli']) . "</div>\n";
	echo "<br /><br />\n";

//include the footer
	require_once "resources/footer.php";

?>
