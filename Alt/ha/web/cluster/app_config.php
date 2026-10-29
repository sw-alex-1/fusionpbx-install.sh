<?php

        //application details
                $apps[$x]['name'] = "Cluster";
                $apps[$x]['uuid'] = "bf008613-a77c-4651-a728-3d2f2e155c8b";
                $apps[$x]['category'] = "system";
                $apps[$x]['subcategory'] = "";
                $apps[$x]['version'] = "1.0";
                $apps[$x]['license'] = "Mozilla Public License 1.1";
                $apps[$x]['url'] = "https://github.com/fusionpbx/fusionpbx";
                $apps[$x]['description']['en-us'] = "FusionPBX HA cluster status (read-only view; diagnostics and repair stay in the CLI).";
                $apps[$x]['description']['ru-ru'] = "Состояние HA-кластера FusionPBX (только просмотр; диагностика и ремонт — в консоли).";

        //permission details
                $y = 0;
                $apps[$x]['permissions'][$y]['name'] = "cluster_view";
                $apps[$x]['permissions'][$y]['groups'][] = "superadmin";
                $y++;

        //default settings
                //how old (seconds) the status snapshot may get before the page and
                //the widget call it stale and turn red. Default: 180 = three missed
                //collector runs (the collector runs every minute, 0.3.41). The
                //installer upserts the same row (same uuid), so the value lands
                //even without an app_defaults/upgrade.php run.
                $y = 0;
                $apps[$x]['default_settings'][$y]['default_setting_uuid'] = "b26c0773-0ecd-45d7-b5a6-eaeba86be86a";
                $apps[$x]['default_settings'][$y]['default_setting_category'] = "cluster";
                $apps[$x]['default_settings'][$y]['default_setting_subcategory'] = "status_stale_seconds";
                $apps[$x]['default_settings'][$y]['default_setting_name'] = "numeric";
                $apps[$x]['default_settings'][$y]['default_setting_value'] = "180";
                $apps[$x]['default_settings'][$y]['default_setting_enabled'] = "true";
                $apps[$x]['default_settings'][$y]['default_setting_description'] = "Seconds after which the cluster status snapshot is considered stale (the widget and the Status -> Cluster page turn red). Default 180 = 3 missed collector runs (the collector runs every minute).";
                $y++;

?>
