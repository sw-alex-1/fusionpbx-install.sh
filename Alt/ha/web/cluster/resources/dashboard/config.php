<?php

// Dashboard widget registration (processed by core/dashboard/app_defaults.php,
// which globs */*/resources/dashboard/config.php). The layer-2 installer ALSO
// registers the widget with a direct idempotent SQL insert - this file keeps
// the app a good citizen for app-defaults runs on upgraded systems.
//
// widget_path 'cluster/cluster' resolves to app/cluster/resources/dashboard/
// cluster.php (the dashboard strips app/ and resources/dashboard from the
// stored path; see core/dashboard/index.php).

$x++;
$array['dashboard_widgets'][$x]['dashboard_uuid'] = '3e2cbaa4-2bec-41b2-a626-999a59b8b19c';
$array['dashboard_widgets'][$x]['dashboard_widget_uuid'] = '0ad5d5d8-79c7-452d-b3ac-e9c8f3454bd4';
$array['dashboard_widgets'][$x]['widget_name'] = 'Cluster Status';
$array['dashboard_widgets'][$x]['widget_path'] = 'cluster/cluster';
$array['dashboard_widgets'][$x]['widget_icon'] = '';
$array['dashboard_widgets'][$x]['widget_icon_color'] = '';
$array['dashboard_widgets'][$x]['widget_url'] = '';
$array['dashboard_widgets'][$x]['widget_target'] = '';
$array['dashboard_widgets'][$x]['widget_width'] = '';
$array['dashboard_widgets'][$x]['widget_height'] = '';
$array['dashboard_widgets'][$x]['widget_content'] = '';
$array['dashboard_widgets'][$x]['widget_content_text_align'] = '';
$array['dashboard_widgets'][$x]['widget_content_details'] = '';
$array['dashboard_widgets'][$x]['widget_chart_type'] = 'text';
$array['dashboard_widgets'][$x]['widget_chart_type_options'] = ['text'];
$array['dashboard_widgets'][$x]['widget_label_enabled'] = 'true';
$array['dashboard_widgets'][$x]['widget_label_text_color'] = '';
$array['dashboard_widgets'][$x]['widget_label_text_color_hover'] = '';
$array['dashboard_widgets'][$x]['widget_label_background_color'] = '';
$array['dashboard_widgets'][$x]['widget_label_background_color_hover'] = '';
$array['dashboard_widgets'][$x]['widget_number_text_color'] = '';
$array['dashboard_widgets'][$x]['widget_number_text_color_hover'] = '';
$array['dashboard_widgets'][$x]['widget_number_background_color'] = '';
$array['dashboard_widgets'][$x]['widget_background_color'] = '';
$array['dashboard_widgets'][$x]['widget_background_color_hover'] = '';
$array['dashboard_widgets'][$x]['widget_detail_background_color'] = '';
$array['dashboard_widgets'][$x]['widget_column_span'] = '1';
$array['dashboard_widgets'][$x]['widget_row_span'] = '2';
$array['dashboard_widgets'][$x]['widget_details_state'] = 'hidden';
$array['dashboard_widgets'][$x]['widget_order'] = '95';
$array['dashboard_widgets'][$x]['widget_enabled'] = 'true';
$array['dashboard_widgets'][$x]['widget_description'] = 'FusionPBX HA cluster status (fusionpbx-ha): health, replication, nodes.';
$y = 0;
$array['dashboard_widgets'][$x]['dashboard_widget_groups'][$y]['dashboard_uuid'] = '3e2cbaa4-2bec-41b2-a626-999a59b8b19c';
$array['dashboard_widgets'][$x]['dashboard_widget_groups'][$y]['dashboard_widget_group_uuid'] = '3319ef28-bd18-4c3f-adc6-ab526ac8898d';
$array['dashboard_widgets'][$x]['dashboard_widget_groups'][$y]['dashboard_widget_uuid'] = '0ad5d5d8-79c7-452d-b3ac-e9c8f3454bd4';
$array['dashboard_widgets'][$x]['dashboard_widget_groups'][$y]['group_name'] = 'superadmin';

?>
