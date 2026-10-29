<?php
// fusionpbx-ha: the "Cluster Status" dashboard widget.
//
// Included by core/dashboard/index.php for the groups mapped to the widget
// (superadmin by default). It renders the SAME snapshot as the Status ->
// Cluster page and runs NO probes (DESIGN.md 19). Stale or missing data
// renders RED - a dead collector must be visible. Read-only by design.

//includes files
        require_once dirname(__DIR__, 4) . "/resources/require.php";

//check permissions
        require_once "resources/check_auth.php";
        if (!permission_exists('cluster_view')) {
                // a widget is an include inside the dashboard loop: a plain
                // 'exit' would kill the whole page - just render nothing
                return;
        }

//add multi-lingual support (explicit app path: the backtrace would
//auto-detect core/dashboard, not this app)
        $language = new text;
        $text = $language->get(null, 'app/cluster');

//read the snapshot
        require_once dirname(__DIR__, 2) . "/resources/status_reader.php";
        $stale_after = 600;
        if (!empty($settings) && method_exists($settings, 'get')) {
                $stale_after = (int)($settings->get('cluster', 'status_stale_seconds', 600) ?: 600);
        }
        $snap = cluster_status_read($stale_after);
        $d = $snap['data'];

//the dashboard passes the widget settings; the label follows the widget
//name exactly like the system widgets do
        $widget_key = str_replace(' ', '_', strtolower($widget_name ?? 'cluster status'));
        $widget_label = $text['label-' . $widget_key] ?? ($widget_name ?? 'Cluster');

        echo "<div class='hud_box'>\n";

        if (!is_array($d)) {
                //no/invalid snapshot: red, with the reason
                $_err_msg = $text['message-' . ($snap['error'] ?: 'stale')];
                $_err_msg = str_replace(['%file%', '%minutes%'], [$snap['file'], (string)(int)(($snap['age'] !== null ? $snap['age'] : 0) / 60 + 1)], $_err_msg);
                echo "  <span class='hud_title'>" . escape($widget_label) . "</span>\n";
                echo "  <div class='hud_stat' style='color: #ea4c46;'>" . $text['health-fail'] . "</div>\n";
                echo "  <div style='font-size: 11px; color: #666; padding: 0 10% 8px 10%;'>" . escape($_err_msg) . "</div>\n";
                echo "</div>\n";
                return;
        }

        $health = $d['health'] ?? 'fail';
        $hcolor = cluster_status_state_color($health);
        $hlabel = $text['health-' . $health] ?? $health;
        $node = $d['node'] ?? [];

        echo "  <div class='hud_content'" . (($widget_details_state ?? 'disabled') == "disabled" ? "" : " onclick=\"$('#hud_cluster_status_details').slideToggle('fast');\"") . ">\n";
        echo "          <span class='hud_title'><a onclick=\"document.location.href='" . PROJECT_PATH . "/app/cluster/cluster.php'\">" . escape($widget_label) . "</a></span>\n";
        echo "          <div class='hud_stat' style='color: " . $hcolor . ";'>" . escape($hlabel) . "</div>\n";

        //rows: this node's role, replication mode + lag, freshness
        $row_style = ['row_style0', 'row_style1'];
        $c = 0;
        $rows = [];
        $rows[] = [$text['label-node'], ($node['name'] ?? '?') . ' - ' . ($text['state-' . str_replace('-', '_', $node['role'] ?? '')] ?? ($node['role'] ?? '?'))];
        if (!empty($d['replication']) && is_array($d['replication'])) {
                $mode = (string)($d['replication']['mode'] ?? 'unknown');
                $rows[] = [$text['label-replication'], ($text['mode-' . $mode] ?? $mode) . ', ' . cluster_status_format_bytes($d['replication']['lag_bytes'] ?? 0)];
        }
        if ($snap['age'] !== null) {
                $rows[] = [$text['label-updated'], cluster_status_format_age($snap['age'])];
        }

        echo "          <table style='width: 100%; font-size: 11px; border-collapse: collapse;'>\n";
        foreach ($rows as $r) {
                echo "                  <tr><td style='padding: 2px 4px; color: #666;'>" . escape($r[0]) . "</td><td style='padding: 2px 4px; text-align: right;" . ($snap['stale'] && $r[0] === $text['label-updated'] ? " color: #ea4c46; font-weight: 600;" : "") . "'>" . escape($r[1]) . "</td></tr>\n";
        }
        echo "          </table>\n";

        //stale overlay: the whole widget must shout
        if ($snap['stale']) {
                echo "          <div style='background: #ea4c46; color: #fff; font-size: 11px; font-weight: 600; text-align: center; border-radius: 4px; padding: 3px 0; margin-top: 6px;'>" . escape(str_replace('%minutes%', (string)(int)(($snap['age'] !== null ? $snap['age'] : 0) / 60 + 1), $text['message-stale'])) . "</div>\n";
        }

        echo "  </div>\n";

        //details (the expander): health reasons + per-node states
        if (($widget_details_state ?? 'disabled') != 'disabled') {
                echo "  <div class='hud_details hud_box' id='hud_cluster_status_details'>\n";
                echo "          <table class='tr_hover' width='100%' cellpadding='0' cellspacing='0' border='0'>\n";
                echo "                  <tr><th class='hud_heading' width='55%'>" . $text['label-node'] . "</th><th class='hud_heading' style='text-align: right;'>" . $text['label-state'] . "</th></tr>\n";
                $c = 0;
                foreach (($d['nodes'] ?? []) as $n) {
                        $state = (string)($n['state'] ?? '');
                        echo "                  <tr class='tr_link_void'><td class='" . $row_style[$c] . " hud_text'>" . escape($n['name'] ?? '?') . "</td><td class='" . $row_style[$c] . " hud_text' style='text-align: right; color: " . cluster_status_state_color($state) . "; font-weight: 600;'>" . escape($text['state-' . str_replace('-', '_', $state)] ?? ($text['state-' . $state] ?? $state)) . "</td></tr>\n";
                        $c = 1 - $c;
                }
                foreach (($d['health_reasons'] ?? []) as $reason) {
                        echo "                  <tr class='tr_link_void'><td class='" . $row_style[$c] . " hud_text' colspan='2' style='color: #ea4c46;'>" . escape($reason) . "</td></tr>\n";
                        $c = 1 - $c;
                }
                echo "          </table>\n";
                echo "  </div>\n";
                echo "  <span class='hud_expander' onclick=\"$('#hud_cluster_status_details').slideToggle('fast');\"><span class='fas fa-ellipsis-h'></span></span>\n";
        }

        echo "</div>\n";

?>
