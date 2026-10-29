<?php

	//menu item: Status -> Cluster. The parent uuid is the well-known
	//"Status" menu item of the default menu (the same convention every
	//upstream app_menu.php uses). The installer registers the item with a
	//direct idempotent SQL insert; this file keeps it a good citizen for
	//menu restores and app defaults runs.
	$y = 0;
	$apps[$x]['menu'][$y]['title']['en-us'] = "Cluster";
	$apps[$x]['menu'][$y]['title']['en-gb'] = "Cluster";
	$apps[$x]['menu'][$y]['title']['ru-ru'] = "Кластер";
	$apps[$x]['menu'][$y]['uuid'] = "3f02bc6a-8e9d-472b-82e6-fd61f7fce3ee";
	$apps[$x]['menu'][$y]['parent_uuid'] = "0438b504-8613-7887-c420-c837ffb20cb1";
	$apps[$x]['menu'][$y]['category'] = "internal";
	$apps[$x]['menu'][$y]['icon'] = "";
	$apps[$x]['menu'][$y]['path'] = "/app/cluster/cluster.php";
	$apps[$x]['menu'][$y]['order'] = "";
	$apps[$x]['menu'][$y]['groups'][] = "superadmin";
	$y++;

?>
