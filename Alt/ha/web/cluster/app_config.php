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
		//the widget call it stale and turn red. Default: 600 = two missed
		//cron runs (the collector runs every 5 minutes) plus the runtime.
		$y = 0;
		$apps[$x]['default_settings'][$y]['default_setting_uuid'] = "b26c0773-0ecd-45d7-b5a6-eaeba86be86a";
		$apps[$x]['default_settings'][$y]['default_setting_category'] = "cluster";
		$apps[$x]['default_settings'][$y]['default_setting_subcategory'] = "status_stale_seconds";
		$apps[$x]['default_settings'][$y]['default_setting_name'] = "numeric";
		$apps[$x]['default_settings'][$y]['default_setting_value'] = "600";
		$apps[$x]['default_settings'][$y]['default_setting_enabled'] = "true";
		$apps[$x]['default_settings'][$y]['default_setting_description'] = "Seconds after which the cluster status snapshot is considered stale (the widget and the Status -> Cluster page turn red). Default 600 = 2 missed collector runs.";
		$y++;

?>
